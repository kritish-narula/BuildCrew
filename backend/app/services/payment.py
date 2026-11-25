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


class RazorpayRouteProvider(PaymentProvider):
    """Live adapter. Set PAYMENT_PROVIDER=razorpay + RAZORPAY_KEY_ID/SECRET/WEBHOOK_SECRET.
    Untested here without keys — verify against Razorpay test mode before going live."""
    BASE = "https://api.razorpay.com/v1"

    def __init__(self, key_id: str, key_secret: str, webhook_secret: str):
        import httpx
        if not (key_id and key_secret and webhook_secret):
            raise RuntimeError("Razorpay keys missing")
        self.key_id, self.key_secret, self.webhook_secret = key_id, key_secret, webhook_secret
        self.http = httpx.Client(base_url=self.BASE, auth=(key_id, key_secret), timeout=20)

    def _post(self, path, json, idem: str | None = None):
        headers = {"X-Razorpay-Idempotency-Key": idem} if idem else {}
        r = self.http.post(path, json=json, headers=headers)
        r.raise_for_status()
        return r.json()

    def create_escrow_order(self, *, receipt, amount_paise, worker_payout_paise, worker_account_id):
        data = self._post("/orders", {
            "amount": amount_paise, "currency": "INR", "receipt": receipt,
            "transfers": [{"account": worker_account_id, "amount": worker_payout_paise,
                           "currency": "INR", "on_hold": 1}],
        }, idem=receipt)
        transfers = data.get("transfers") or []
        return EscrowOrder(data["id"], transfers[0]["id"] if transfers else None, amount_paise, self.key_id)

    def verify_checkout_signature(self, order_id, payment_id, signature):
        return _hmac_ok(self.key_secret, f"{order_id}|{payment_id}".encode(), signature)

    def verify_webhook(self, raw_body, signature):
        return _hmac_ok(self.webhook_secret, raw_body, signature)

    def release(self, transfer_id):
        r = self.http.patch(f"/transfers/{transfer_id}", json={"on_hold": 0})
        r.raise_for_status()
        return r.json()["id"]

    def refund(self, payment_id, amount_paise, transfer_id, reverse_paise):
        if transfer_id and reverse_paise:
            self._post(f"/transfers/{transfer_id}/reversals", {"amount": reverse_paise})
        return self._post(f"/payments/{payment_id}/refund", {"amount": amount_paise})["id"]

    def create_linked_account(self, *, name, phone, upi_id):
        # Route linked-account onboarding (v2 accounts API) requires business KYC details;
        # for individual workers most teams use RazorpayX payouts to the UPI VPA instead.
        # Documented in README → "Going live with payments".
        raise NotImplementedError("Complete Route linked-account onboarding before go-live")
