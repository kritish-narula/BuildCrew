"""PaymentProvider — escrow via Razorpay Route.

Flow (Route "on_hold" transfers give us escrow without holding money in our own account):
 1. create_escrow_order(): Razorpay Order for (quote + flat fee) with a transfer to the worker's
    Linked Account marked on_hold=1. Customer pays via Checkout (UPI/card/netbanking).
 2. Webhook `payment.captured` (signature-verified) → escrow HELD.
 3. release(): PATCH transfer on_hold=0 → Razorpay settles to the worker. Only callable after the
    mandatory rating exists (enforced by the domain layer, Phase 4).
 4. refund()/split(): reverse the transfer (fully or partially) + refund the customer.

SECURITY: amounts are ALWAYS computed on the server from the accepted bid (see fees.py); the
client never sends an amount. Webhooks and checkout callbacks are HMAC-verified before any
state change. Key secrets live only in server env vars — never in the mobile app.
"""
import hashlib
import hmac
import uuid
from abc import ABC, abstractmethod
from dataclasses import dataclass


@dataclass
class EscrowOrder:
    order_id: str
    transfer_id: str | None
    amount_paise: int
    checkout_key_id: str  # public key id for Checkout; never the secret


class PaymentProvider(ABC):
    live: bool = False  # True = real money: Checkout results must carry a verifiable signature

    @abstractmethod
    def create_escrow_order(self, *, receipt: str, amount_paise: int, worker_payout_paise: int,
                            worker_account_id: str) -> EscrowOrder: ...

    @abstractmethod
    def verify_checkout_signature(self, order_id: str, payment_id: str, signature: str) -> bool: ...

    @abstractmethod
    def verify_webhook(self, raw_body: bytes, signature: str) -> bool: ...

    @abstractmethod
    def release(self, transfer_id: str) -> str: ...

    @abstractmethod
    def refund(self, payment_id: str, amount_paise: int, transfer_id: str | None,
               reverse_paise: int) -> str: ...

    def checkout_key_id(self) -> str:
        return "rzp_test_mock"

    @abstractmethod
    def create_linked_account(self, *, name: str, phone: str, upi_id: str) -> str: ...


def _hmac_ok(secret: str, msg: bytes, signature: str) -> bool:
    expected = hmac.new(secret.encode(), msg, hashlib.sha256).hexdigest()
    return hmac.compare_digest(expected, signature or "")  # constant-time compare


class MockPaymentProvider(PaymentProvider):
    """Deterministic, in-memory. Signatures use a fixed dev secret so tests exercise the same
    verification path as production."""
    SECRET = "mock_webhook_secret"

    def __init__(self):
        self.ledger: list[dict] = []

    def create_escrow_order(self, *, receipt, amount_paise, worker_payout_paise, worker_account_id):
        order = EscrowOrder(f"order_mock_{uuid.uuid4().hex[:12]}", f"trf_mock_{uuid.uuid4().hex[:12]}",
                            amount_paise, "rzp_test_mock")
        self.ledger.append({"op": "order", "order": order.order_id, "amount": amount_paise,
                            "payout": worker_payout_paise, "to": worker_account_id})
        return order

    def sign(self, msg: bytes) -> str:  # test helper
        return hmac.new(self.SECRET.encode(), msg, hashlib.sha256).hexdigest()

    def verify_checkout_signature(self, order_id, payment_id, signature):
        return _hmac_ok(self.SECRET, f"{order_id}|{payment_id}".encode(), signature)

    def verify_webhook(self, raw_body, signature):
        return _hmac_ok(self.SECRET, raw_body, signature)

    def release(self, transfer_id):
        self.ledger.append({"op": "release", "transfer": transfer_id})
        return f"rel_mock_{uuid.uuid4().hex[:10]}"

    def refund(self, payment_id, amount_paise, transfer_id, reverse_paise):
        self.ledger.append({"op": "refund", "payment": payment_id, "amount": amount_paise,
                            "reverse": reverse_paise})
        return f"rfnd_mock_{uuid.uuid4().hex[:10]}"

    def create_linked_account(self, *, name, phone, upi_id):
        return f"acc_mock_{uuid.uuid4().hex[:10]}"


class RazorpayProvider(PaymentProvider):
    """Live adapter (PAYMENT_PROVIDER=auto|razorpay with RAZORPAY_KEY_ID / RAZORPAY_KEY_SECRET / RAZORPAY_WEBHOOK_SECRET).

    Default = PLAIN Orders: the customer's money lands in OUR Razorpay account and the escrow is a ledger state; on release
    the worker is paid through the PayoutProvider (RazorpayX -> UPI). That works for individual workers without business KYC.
    `route=True` (RAZORPAY_ROUTE_ENABLED) instead attaches an on_hold Route transfer to a linked account per worker.
    Test it end-to-end in Razorpay TEST mode (rzp_test_ keys) before going live. `client` is injectable for tests."""
    BASE = "https://api.razorpay.com/v1"
    live = True

    def __init__(self, key_id: str, key_secret: str, webhook_secret: str, *, route: bool = False, client=None):
        if not (key_id and key_secret):
            raise RuntimeError("Razorpay keys missing")
        self.key_id, self.key_secret, self.webhook_secret, self.route = key_id, key_secret, webhook_secret, route
        if client is None:
            import httpx
            client = httpx.Client(base_url=self.BASE, auth=(key_id, key_secret), timeout=20)
        self.http = client

    def checkout_key_id(self) -> str:
        return self.key_id

    def _post(self, path, json, idem: str | None = None):
        headers = {"X-Razorpay-Idempotency-Key": idem} if idem else {}
        r = self.http.post(path, json=json, headers=headers)
        r.raise_for_status()
        return r.json()

    def create_escrow_order(self, *, receipt, amount_paise, worker_payout_paise, worker_account_id):
        body = {"amount": amount_paise, "currency": "INR", "receipt": receipt}
        if self.route:
            body["transfers"] = [{"account": worker_account_id, "amount": worker_payout_paise,
                                  "currency": "INR", "on_hold": 1}]
        data = self._post("/orders", body, idem=receipt)
        transfers = data.get("transfers") or []
        return EscrowOrder(data["id"], transfers[0]["id"] if transfers else None, amount_paise, self.key_id)

    def verify_checkout_signature(self, order_id, payment_id, signature):
        return _hmac_ok(self.key_secret, f"{order_id}|{payment_id}".encode(), signature)

    def verify_webhook(self, raw_body, signature):
        return bool(self.webhook_secret) and _hmac_ok(self.webhook_secret, raw_body, signature)

    def release(self, transfer_id):
        if not self.route or not transfer_id:  # plain orders: the worker is paid by the payout provider
            return "payout_provider"
        r = self.http.patch(f"/transfers/{transfer_id}", json={"on_hold": 0})
        r.raise_for_status()
        return r.json()["id"]

    def _payment_for(self, ref: str) -> str:
        if ref.startswith("pay_"):
            return ref
        r = self.http.get(f"/orders/{ref}/payments")
        r.raise_for_status()
        items = [x for x in r.json().get("items", []) if x.get("status") in ("captured", "authorized")]
        if not items:
            raise RuntimeError("no captured payment for order")
        return items[0]["id"]

    def refund(self, payment_id, amount_paise, transfer_id, reverse_paise):
        """`payment_id` may be the pay_ id or (fallback) the order id. Idempotent per (payment, amount)."""
        if self.route and transfer_id and reverse_paise:
            self._post(f"/transfers/{transfer_id}/reversals", {"amount": reverse_paise})
        pid = self._payment_for(payment_id)
        return self._post(f"/payments/{pid}/refund", {"amount": amount_paise, "speed": "normal"},
                          idem=f"rf_{pid}_{amount_paise}")["id"]

    def create_linked_account(self, *, name, phone, upi_id):
        raise NotImplementedError("Route linked-account onboarding needs business KYC; use RazorpayX payouts instead")


RazorpayRouteProvider = RazorpayProvider  # backwards-compatible name


def build_payment_provider(s) -> PaymentProvider:
    """auto: live iff both key id + secret are set. mock forces the demo flow even if keys exist."""
    if s.payment_provider == "mock":
        return MockPaymentProvider()
    if s.payment_provider == "razorpay" or (s.razorpay_key_id and s.razorpay_key_secret):
        return RazorpayProvider(s.razorpay_key_id, s.razorpay_key_secret, s.razorpay_webhook_secret,
                                route=s.razorpay_route_enabled)
    return MockPaymentProvider()
