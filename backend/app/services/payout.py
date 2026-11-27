"""PayoutProvider - same-day pay: sends a released escrow straight to the worker's UPI.

The mock settles after `payout_mock_settle_seconds` (evaluated lazily when the payout is read, like the
48 h auto-confirm). A real adapter (RazorpayX payouts to a UPI VPA) implements the same two methods:
`send` returns (provider_ref, status) and `status` later reports processing | paid | failed.
"""
import uuid
from abc import ABC, abstractmethod
from datetime import datetime, timedelta, timezone


class PayoutProvider(ABC):
    @abstractmethod
    def send(self, *, upi_id: str, amount_paise: int, reference: str) -> tuple[str, str]:
        """-> (provider_ref, initial status)"""

    @abstractmethod
    def status(self, provider_ref: str, created_at: datetime) -> str:
        """-> processing | paid | failed"""


class MockPayoutProvider(PayoutProvider):
    def __init__(self, settle_seconds: int = 5):
        self.settle_seconds = settle_seconds
        self.sent: list[dict] = []

    def send(self, *, upi_id, amount_paise, reference):
        ref = f"pout_mock_{uuid.uuid4().hex[:10]}"
        self.sent.append({"ref": ref, "upi": upi_id, "amount": amount_paise, "reference": reference})
        return ref, "processing"

    def status(self, provider_ref, created_at):
        age = datetime.now(timezone.utc) - created_at
        return "paid" if age >= timedelta(seconds=self.settle_seconds) else "processing"


class RazorpayXPayoutProvider(PayoutProvider):
    """RazorpayX payout to a UPI VPA: contact -> fund account (vpa) -> payout (mode UPI). Needs a RazorpayX business account
    (RAZORPAYX_ACCOUNT_NUMBER = the virtual account you fund). Statuses map: processed -> paid; failed/rejected/cancelled/
    reversed -> failed; everything else (queued/pending/processing) -> processing. `client` is injectable for tests."""
    BASE = "https://api.razorpay.com/v1"

    def __init__(self, key_id: str, key_secret: str, account_number: str, client=None):
        if not (key_id and key_secret and account_number):
            raise RuntimeError("RazorpayX keys / account number missing")
        self.account_number = account_number
        if client is None:
            import httpx
            client = httpx.Client(base_url=self.BASE, auth=(key_id, key_secret), timeout=20)
        self.http = client

    def _post(self, path, json, idem=None):
        r = self.http.post(path, json=json, headers={"X-Payout-Idempotency": idem} if idem else {})
        r.raise_for_status()
        return r.json()

    def send(self, *, upi_id, amount_paise, reference):
        contact = self._post("/contacts", {"name": "BuildCrew worker", "type": "vendor", "reference_id": reference[:40]})
        fa = self._post("/fund_accounts", {"contact_id": contact["id"], "account_type": "vpa", "vpa": {"address": upi_id}})
        out = self._post("/payouts", {"account_number": self.account_number, "fund_account_id": fa["id"],
                                      "amount": amount_paise, "currency": "INR", "mode": "UPI", "purpose": "payout",
                                      "queue_if_low_balance": True, "reference_id": reference[:40],
                                      "narration": "BuildCrew"}, idem=reference)
        return out["id"], self._map(out.get("status"))

    @staticmethod
    def _map(status: str | None) -> str:
        if status == "processed":
            return "paid"
        if status in ("failed", "rejected", "cancelled", "reversed"):
            return "failed"
        return "processing"

    def status(self, provider_ref, created_at):
        r = self.http.get(f"/payouts/{provider_ref}")
        r.raise_for_status()
        return self._map(r.json().get("status"))


def build_payout_provider(s) -> PayoutProvider:
    """auto: RazorpayX iff account number + keys are set (RAZORPAYX_KEY_ID/SECRET fall back to the RAZORPAY_* pair)."""
    kid, ksec = s.razorpayx_key_id or s.razorpay_key_id, s.razorpayx_key_secret or s.razorpay_key_secret
    if s.payout_provider == "razorpayx" or (s.payout_provider == "auto" and s.razorpayx_account_number and kid and ksec):
        return RazorpayXPayoutProvider(kid, ksec, s.razorpayx_account_number)
    return MockPayoutProvider(s.payout_mock_settle_seconds)
