"""Access policies — who may see which private media.

Spec: customer audio is visible ONLY to bidding workers on that job, the customer, and admin.
Assumption: "bidding workers" = workers ELIGIBLE to bid (active, not suspended, trade
matches a work item, job still open/bidding) plus any worker who already bid. Workers must
hear the note *before* quoting, so restricting to "already bid" would break the core flow.
Nothing is ever publicly listable: no index, no permanent URL, links expire in minutes.
"""
from sqlalchemy import select
from sqlalchemy.orm import Session

from ..enums import JobStatus, Role
from ..models import Bid, Job, User


def can_access_job_media(db: Session, user: User, job: Job) -> bool:
    if user.role == Role.admin or (user.role == Role.customer and job.customer_id == user.id):
        return True
    if user.role != Role.worker or not user.worker_profile or user.worker_profile.is_suspended:
        return False
    already_bid = db.scalar(select(Bid.id).where(Bid.job_id == job.id, Bid.worker_id == user.id))
    if already_bid:
        return True
    if job.status not in (JobStatus.open, JobStatus.bidding) and not (job.kind == "team" and job.status in (JobStatus.assigned, JobStatus.in_progress)):
        return False
    from . import trust
    ex = trust.exclusive_to(job)
    if ex is not None and ex != user.id:
        return False
    trades = set(user.worker_profile.trades or [])
    return any(wi.trade.value in trades for wi in job.work_items)
