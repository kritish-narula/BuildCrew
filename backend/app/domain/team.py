"""Contractor team hiring.

A TEAM job has one work item per trade: `headcount` workers x `days` days at `daily_wage_paise` each.
Workers apply (a bid whose price is their DAILY wage, tied to one trade line). The contractor accepts
as many applicants per trade as `headcount` allows. Each accepted worker gets his OWN assignment +
payment (escrow = wage x days + flat fee), so check-in, chat, earnings and withdrawals reuse the
single-job machinery unchanged.

Settlement is per worker: the contractor rates the worker, who is paid for the days actually worked
(distinct check-in dates, capped at the planned days). Unworked days are refunded to the contractor.
"""
from datetime import datetime, timedelta, timezone

from sqlalchemy import select
from sqlalchemy.orm import Session

from .. import services
from ..audit import audit
from ..enums import BidStatus, EscrowState, JobStatus, RatingDirection
from ..errors import AppError
from ..models import Assignment, Attendance, Bid, Job, Payment, Rating, User, WorkerProfile, WorkItem
from . import pricing
from .fees import compute_fees
from .state import transition

IST = timezone(timedelta(hours=5, minutes=30))
now = lambda: datetime.now(timezone.utc)  # noqa: E731
HIRING = (JobStatus.open, JobStatus.bidding, JobStatus.assigned, JobStatus.in_progress)  # a team can grow while the site runs
SETTLED = (EscrowState.released, EscrowState.refunded, EscrowState.split)


def _assignments(db: Session, job: Job) -> list[Assignment]:
    return list(db.scalars(select(Assignment).where(Assignment.job_id == job.id).order_by(Assignment.id)))


def filled(db: Session, item: WorkItem) -> int:
    return len(list(db.scalars(select(Assignment.id).where(Assignment.work_item_id == item.id))))


def open_slots(db: Session, job: Job) -> int:
    return sum(max(0, wi.headcount - filled(db, wi)) for wi in job.work_items)


def pick_item(db: Session, job: Job, worker: User) -> WorkItem:
    """The trade line a worker applies to: first line matching his trades that still has room."""
    trades = set(worker.worker_profile.trades or [])
    cands = [wi for wi in job.work_items if not trades or wi.trade.value in trades]
    if not cands:
        raise AppError("err.trade_mismatch", 403)
    for wi in cands:
        if filled(db, wi) < wi.headcount:
            return wi
    raise AppError("err.team_full", 409)


def days_worked(db: Session, a: Assignment) -> int:
    rows = db.scalars(select(Attendance.checkin_at).where(Attendance.assignment_id == a.id)).all()
    return min(a.days_planned, len({r.astimezone(IST).date() for r in rows}))


def present_today(db: Session, a: Assignment) -> bool:
    today = now().astimezone(IST).date()
    rows = db.scalars(select(Attendance.checkin_at).where(Attendance.assignment_id == a.id)).all()
    return any(r.astimezone(IST).date() == today for r in rows)


def wage_paise(db: Session, a: Assignment) -> int:
    return db.get(Bid, a.accepted_bid_id).quoted_price_paise


def summary(db: Session, job: Job) -> dict | None:
    """Compact team facts for cards: per-trade headcount/filled/wage + attendance today."""
    if job.kind != "team":
        return None
    asg = _assignments(db, job)
    lines = []
    for wi in job.work_items:
        n = sum(1 for a in asg if a.work_item_id == wi.id)
        lines.append({"item_id": str(wi.id), "trade": wi.trade.value, "headcount": wi.headcount, "filled": n, "days": wi.days,
                      "daily_wage_inr": (wi.daily_wage_paise or 0) / 100})
    return {"headcount": sum(i["headcount"] for i in lines), "filled": sum(i["filled"] for i in lines),
            "present_today": sum(1 for a in asg if present_today(db, a)), "items": lines}


def roster(db: Session, job: Job, lang: str) -> dict:
    from ..routers.views import payment_view, worker_summary  # views import flows; avoid import cycle at module load
    asg = _assignments(db, job)
    rows, due_paise, due_n = [], 0, 0
    for a in asg:
        p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
        wage, worked = wage_paise(db, a), days_worked(db, a)
        item = db.get(WorkItem, a.work_item_id)
        rated = db.scalar(select(Rating.id).where(Rating.assignment_id == a.id,
                                                  Rating.direction == RatingDirection.customer_to_worker)) is not None
        if p and p.escrow_state == EscrowState.created:
            due_paise += p.amount_paise
            due_n += 1
        rows.append({"assignment_id": str(a.id), "worker": worker_summary(db, a.worker), "trade": item.trade.value if item else None,
                     "daily_wage_inr": wage / 100, "days_planned": a.days_planned, "days_worked": worked,
                     "present_today": present_today(db, a), "amount_due_inr": wage * worked / 100,
                     "total_inr": wage * a.days_planned / 100, "payment": payment_view(p), "rated": rated,
                     "settled": bool(p and p.escrow_state in SETTLED)})
    return {"summary": summary(db, job), "workers": rows, "payment_due_inr": due_paise / 100, "payment_due_count": due_n}


# ------------------------------------------------------------------ accept + pay
def accept_team_bid(db: Session, customer: User, job: Job, bid: Bid) -> Assignment:
    item = db.get(WorkItem, bid.work_item_id) if bid.work_item_id else None
    if not item or item.job_id != job.id:
        raise AppError("err.not_found", 404)
    if job.status not in HIRING:
        raise AppError("err.job_closed", 409)
    if filled(db, item) >= item.headcount:
        raise AppError("err.team_full", 409)
    if job.status in (JobStatus.open, JobStatus.bidding):
        transition(db, job, kind="job", field="status", new=JobStatus.assigned, actor_id=customer.id)
    transition(db, bid, kind="bid", field="status", new=BidStatus.accepted, actor_id=customer.id)
    a = Assignment(job_id=job.id, work_item_id=item.id, days_planned=item.days, worker_id=bid.worker_id,
                   accepted_bid_id=bid.id, escrow_status=EscrowState.created)
    db.add(a)
    db.flush()
    total = bid.quoted_price_paise * item.days
    fees = compute_fees(total)
    order = services.payment().create_escrow_order(
        receipt=f"asg_{a.id.hex[:20]}", amount_paise=fees.customer_pays_paise,
        worker_payout_paise=fees.worker_payout_paise, worker_account_id=f"worker_{bid.worker_id.hex[:12]}")
    p = Payment(assignment_id=a.id, amount_paise=fees.customer_pays_paise, platform_fee_paise=fees.platform_fee_paise,
                worker_payout_paise=fees.worker_payout_paise, escrow_state=EscrowState.created,
                razorpay_ref=order.order_id, transfer_ref=order.transfer_id)
    db.add(p)
    db.flush()
    audit(db, actor_id=customer.id, action="team.hired", entity="assignment", entity_id=a.id, amount=fees.customer_pays_paise)
    if open_slots(db, job) == 0:  # fully staffed: everyone else is turned down
        for other in db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.status == BidStatus.pending)):
            transition(db, other, kind="bid", field="status", new=BidStatus.rejected, actor_id=customer.id)
    return a


def pay_team(db: Session, customer: User, job: Job, *, method: str, razorpay_payment_id: str | None = None,
             signature: str | None = None) -> dict:
    """ONE checkout for the whole team: every unpaid worker's escrow is funded (sum shown on the roster)."""
    from . import flows
    if job.customer_id != customer.id:
        raise AppError("err.not_your_job", 403)
    paid, fee, payout, count = 0, 0, 0, 0
    for a in _assignments(db, job):
        p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
        if p and p.escrow_state == EscrowState.created:
            flows.pay_escrow(db, customer, a, method=method, razorpay_payment_id=razorpay_payment_id, signature=signature)
            paid += p.amount_paise
            fee += p.platform_fee_paise
            payout += p.worker_payout_paise
            count += 1
    # The same keys as a single payment, so the payment-success page and receipt work for a whole team.
    return {"paid_inr": paid / 100, "count": count, "method": method, "amount_inr": paid / 100, "platform_fee_inr": fee / 100,
            "worker_payout_inr": payout / 100, "refund_inr": 0.0, "escrow_state": "held", "released_at": None,
            "ref": f"BC-TEAM-{job.id.hex[:8].upper()}", "paid_at": now().isoformat()}


# ------------------------------------------------------------------ per-worker settlement
def settle_worker(db: Session, customer: User, job: Job, a: Assignment, *, quality: int, timeliness: int, behaviour: int,
                  value_for_money: int, comment: str | None) -> dict:
    """Rate one team member (mandatory) -> pay him for days worked; refund the unworked days."""
    from . import flows
    if job.customer_id != customer.id or a.job_id != job.id:
        raise AppError("err.not_your_job", 403)
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    if not p or p.escrow_state != EscrowState.held:
        raise AppError("err.payment_not_held", 409)
    flows._check_stars(quality, timeliness, behaviour, value_for_money)
    if db.scalar(select(Rating.id).where(Rating.assignment_id == a.id, Rating.direction == RatingDirection.customer_to_worker)):
        raise AppError("err.already_rated", 409)
    wage, worked = wage_paise(db, a), days_worked(db, a)
    unworked = a.days_planned - worked
    if job.status == JobStatus.assigned:
        transition(db, job, kind="job", field="status", new=JobStatus.in_progress, actor_id=customer.id)
    a.completed_at = now()
    overall = flows._avg(quality, timeliness, behaviour, value_for_money)
    db.add(Rating(assignment_id=a.id, direction=RatingDirection.customer_to_worker, rater_id=customer.id, ratee_id=a.worker_id,
                  quality=quality, timeliness=timeliness, behaviour=behaviour, value_for_money=value_for_money,
                  overall=overall, comment=(comment or "").strip()[:500] or None))
    db.flush()
    wp = db.get(WorkerProfile, a.worker_id)
    if worked > 0:
        wp.overall_rating = round((wp.overall_rating * wp.rating_count + overall) / (wp.rating_count + 1), 2)
        wp.rating_count += 1
        wp.completed_jobs += 1
        flows._award_badges(wp)
    if worked == 0:  # nobody turned up: full refund to the contractor
        services.payment().refund(p.razorpay_ref or "", p.amount_paise, p.transfer_ref, p.worker_payout_paise)
        transition(db, p, kind="escrow", field="escrow_state", new=EscrowState.refunded, actor_id=customer.id, reason="no_attendance")
        p.refund_paise, p.worker_payout_paise, p.platform_fee_paise, p.released_at = p.amount_paise, 0, 0, now()
        a.escrow_status = EscrowState.refunded
    else:
        fees = compute_fees(wage * worked)
        refund = wage * unworked
        if unworked:
            services.payment().refund(p.razorpay_ref or "", refund, p.transfer_ref, wage * worked)
        p.refund_paise, p.worker_payout_paise = refund, fees.worker_payout_paise
        p.platform_fee_paise = p.amount_paise - refund - fees.worker_payout_paise
        flows.release_payment(db, a, actor_id=customer.id)
    audit(db, actor_id=customer.id, action="team.settled", entity="assignment", entity_id=a.id, days=worked, refund=p.refund_paise)
    _maybe_complete(db, job, customer)
    return {"days_worked": worked, "days_planned": a.days_planned, "payout_inr": p.worker_payout_paise / 100,
            "refund_inr": p.refund_paise / 100, "overall": overall}


def _maybe_complete(db: Session, job: Job, actor: User) -> None:
    asg = _assignments(db, job)
    pays = [db.scalar(select(Payment).where(Payment.assignment_id == a.id)) for a in asg]
    if asg and all(p and p.escrow_state in SETTLED for p in pays):
        for other in db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.status == BidStatus.pending)):
            transition(db, other, kind="bid", field="status", new=BidStatus.rejected, actor_id=actor.id)
        if job.status == JobStatus.assigned:
            transition(db, job, kind="job", field="status", new=JobStatus.in_progress, actor_id=actor.id)
        transition(db, job, kind="job", field="status", new=JobStatus.completed, actor_id=actor.id, reason="team_settled")


def wage_floor_check(trade: str, daily_wage_inr: int, city: str | None) -> None:
    """Fair Wage Shield for contractors: a daily wage OFFER below the legal minimum is refused outright."""
    if daily_wage_inr < pricing.min_wage_per_day(trade):
        raise AppError("err.wage_below_minimum", 422, trade=trade, minimum=pricing.min_wage_per_day(trade))
