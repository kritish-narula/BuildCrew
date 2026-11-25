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
    """Placeholder for RazorpayX (POST /v1/payouts with a UPI fund account). Needs a RazorpayX business account."""

    def send(self, *, upi_id, amount_paise, reference):
        raise NotImplementedError("Configure RazorpayX before PAYOUT_PROVIDER=razorpayx")

    def status(self, provider_ref, created_at):
        raise NotImplementedError("Configure RazorpayX before PAYOUT_PROVIDER=razorpayx")
