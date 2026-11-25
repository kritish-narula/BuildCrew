"""Fee math. Server-side only — the single source of truth for every rupee that moves."""
from dataclasses import dataclass

from ..config import get_settings


@dataclass(frozen=True)
class FeeBreakdown:
    quote_paise: int           # what the worker quoted
    flat_fee_paise: int        # nominal per-job platform fee, charged to the customer
    take_paise: int            # optional % take rate, deducted from the worker's quote
    customer_pays_paise: int   # quote + flat fee
    worker_payout_paise: int   # quote - take
    platform_fee_paise: int    # flat fee + take


def compute_fees(quote_paise: int) -> FeeBreakdown:
    s = get_settings()
    if quote_paise <= 0:
        raise ValueError("quote must be positive")
    take = round(quote_paise * s.platform_take_rate_pct / 100)
    flat = s.platform_fee_flat_paise
    return FeeBreakdown(quote_paise, flat, take, quote_paise + flat, quote_paise - take, flat + take)
