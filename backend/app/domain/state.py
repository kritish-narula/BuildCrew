"""State machines for Job, Bid and Escrow.

Every status change in the system MUST go through `transition()`, which (1) rejects illegal
moves and (2) writes an AuditLog row in the same DB transaction.

Escrow state machine (Razorpay Route mapping in services/payment.py):

    created ──capture──▶ held ──release (needs customer→worker rating!)──▶ released
                          │
                          ├──refund (admin / cancellation)──────────────▶ refunded
                          └──split  (admin dispute resolution)──────────▶ split

`held → released` is additionally gated by the mandatory-rating rule, enforced in the payment
domain service (Phase 4), not here — this module only knows about legal *shapes* of moves.
"""
import uuid

from sqlalchemy.orm import Session

from ..audit import audit
from ..enums import BidStatus, EscrowState, JobStatus
from ..errors import AppError

JOB_TRANSITIONS: dict[JobStatus, set[JobStatus]] = {
    JobStatus.open: {JobStatus.bidding, JobStatus.cancelled},
    JobStatus.bidding: {JobStatus.assigned, JobStatus.cancelled},
    JobStatus.assigned: {JobStatus.in_progress, JobStatus.cancelled, JobStatus.disputed},
    JobStatus.in_progress: {JobStatus.completed, JobStatus.disputed},
    JobStatus.completed: {JobStatus.disputed},  # dispute window after completion
    JobStatus.disputed: {JobStatus.completed, JobStatus.cancelled},  # admin resolution
    JobStatus.cancelled: set(),
}

BID_TRANSITIONS: dict[BidStatus, set[BidStatus]] = {
    BidStatus.pending: {BidStatus.accepted, BidStatus.rejected, BidStatus.withdrawn},
    BidStatus.accepted: set(),
    BidStatus.rejected: set(),
    BidStatus.withdrawn: set(),
}

ESCROW_TRANSITIONS: dict[EscrowState, set[EscrowState]] = {
    EscrowState.created: {EscrowState.held},
    EscrowState.held: {EscrowState.released, EscrowState.refunded, EscrowState.split},
    EscrowState.released: set(),
    EscrowState.refunded: set(),
    EscrowState.split: set(),
}

_TABLES = {"job": JOB_TRANSITIONS, "bid": BID_TRANSITIONS, "escrow": ESCROW_TRANSITIONS}


def transition(db: Session, obj, *, kind: str, field: str, new, actor_id: uuid.UUID | None,
               reason: str | None = None) -> None:
    table = _TABLES[kind]
    old = getattr(obj, field)
    if new == old:
        return
    if new not in table[old]:
        raise AppError("err.illegal_transition", 409, frm=old.value, to=new.value)
    setattr(obj, field, new)
    audit(db, actor_id=actor_id, action=f"{kind}.{new.value}", entity=type(obj).__name__.lower(),
          entity_id=obj.id if hasattr(obj, "id") else obj.assignment_id,
          frm=old.value, to=new.value, reason=reason)
