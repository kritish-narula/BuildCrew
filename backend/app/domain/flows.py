"""Business operations. Routers stay thin; every money/state rule lives here and is tested.

Lifecycle:  open ─bid─▶ bidding ─accept─▶ assigned ─start/check-in─▶ in_progress ─customer "done"─▶
            completed ─MANDATORY customer rating─▶ payment released ─▶ worker balance ─withdraw─▶ UPI
"""
import uuid
from datetime import datetime, timezone

from sqlalchemy import func, select
from sqlalchemy.orm import Session

from .. import services
from ..audit import audit
from ..config import get_settings
from ..crypto import mask_upi
from ..enums import BidStatus, DisputeStatus, EscrowState, JobStatus, RatingDirection, Role
from ..errors import AppError
from ..models import (
    Assignment, Attendance, Bid, Dispute, Job, Payment, Payout, Rating, User, WorkerProfile,
)
from .fees import compute_fees
from .state import transition

now = lambda: datetime.now(timezone.utc)  # noqa: E731


# ------------------------------------------------------------------ bids
def place_bid(db: Session, worker: User, job: Job, price_paise: int, client_ref: str | None) -> Bid:
    """Idempotent on client_ref: an offline-queued bid replayed twice creates ONE bid.
    Team jobs: the price is the worker's DAILY wage and the bid is tied to one trade line."""
    if client_ref:
        existing = db.scalar(select(Bid).where(Bid.client_ref == client_ref))
        if existing:
            return existing
    from . import team  # local import: team builds on this module
    is_team = job.kind == "team"
    if job.status not in (JobStatus.open, JobStatus.bidding) and not (
            is_team and job.status in (JobStatus.assigned, JobStatus.in_progress) and team.open_slots(db, job) > 0):
        raise AppError("err.job_closed", 409)
    if price_paise < 100 * 100 or price_paise > 10_000_000 * 100:
        raise AppError("err.validation", 422)
    trades = set(worker.worker_profile.trades or [])
    if trades and not any(wi.trade.value in trades for wi in job.work_items):
        raise AppError("err.trade_mismatch", 403)
    item = team.pick_item(db, job, worker) if is_team else None
    bid = db.scalar(select(Bid).where(Bid.job_id == job.id, Bid.worker_id == worker.id))
    if bid and bid.status == BidStatus.pending:  # re-quote: update price instead of a duplicate
        bid.quoted_price_paise = price_paise
        audit(db, actor_id=worker.id, action="bid.updated", entity="bid", entity_id=bid.id, price=price_paise)
        return bid
    if bid:
        raise AppError("err.bid_exists", 409)
    bid = Bid(job_id=job.id, worker_id=worker.id, quoted_price_paise=price_paise, client_ref=client_ref,
              work_item_id=item.id if item else None)
    db.add(bid)
    db.flush()
    audit(db, actor_id=worker.id, action="bid.placed", entity="bid", entity_id=bid.id, price=price_paise)
    if job.status == JobStatus.open:
        transition(db, job, kind="job", field="status", new=JobStatus.bidding, actor_id=worker.id)
    services.realtime().publish(f"job:{job.id}", "bid", {"bid_id": str(bid.id)})
    return bid


def withdraw_bid(db: Session, worker: User, bid: Bid) -> None:
    if bid.worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    transition(db, bid, kind="bid", field="status", new=BidStatus.withdrawn, actor_id=worker.id)


# ------------------------------------------------------------------ accept + escrow
def accept_bid(db: Session, customer: User, job: Job, bid: Bid) -> Assignment:
    """Customer accepts one bid. Others are rejected, an escrow order is created for
    quote + flat fee. Amounts come from the stored bid — never from the client."""
    if job.customer_id != customer.id:
        raise AppError("err.not_your_job", 403)
    if bid.job_id != job.id or bid.status != BidStatus.pending:
        raise AppError("err.job_closed", 409)
    if job.kind == "team":  # several workers per job: see domain/team.py
        from . import team
        return team.accept_team_bid(db, customer, job, bid)
    transition(db, job, kind="job", field="status", new=JobStatus.assigned, actor_id=customer.id)
    transition(db, bid, kind="bid", field="status", new=BidStatus.accepted, actor_id=customer.id)
    for other in db.scalars(select(Bid).where(Bid.job_id == job.id, Bid.id != bid.id, Bid.status == BidStatus.pending)):
        transition(db, other, kind="bid", field="status", new=BidStatus.rejected, actor_id=customer.id)

    a = Assignment(job_id=job.id, worker_id=bid.worker_id, accepted_bid_id=bid.id, escrow_status=EscrowState.created)
    db.add(a)
    db.flush()
    fees = compute_fees(bid.quoted_price_paise)
    order = services.payment().create_escrow_order(
        receipt=f"asg_{a.id.hex[:20]}", amount_paise=fees.customer_pays_paise,
        worker_payout_paise=fees.worker_payout_paise, worker_account_id=f"worker_{bid.worker_id.hex[:12]}")
    p = Payment(assignment_id=a.id, amount_paise=fees.customer_pays_paise, platform_fee_paise=fees.platform_fee_paise,
                worker_payout_paise=fees.worker_payout_paise, escrow_state=EscrowState.created,
                razorpay_ref=order.order_id, transfer_ref=order.transfer_id)
    db.add(p)
    db.flush()
    audit(db, actor_id=customer.id, action="payment.order_created", entity="payment", entity_id=p.id,
          amount=fees.customer_pays_paise)
    # Escrow stays CREATED until the customer completes the payment page (pay_escrow).
    return a


def pay_escrow(db: Session, customer: User, a: Assignment, *, method: str, razorpay_payment_id: str | None = None,
               signature: str | None = None) -> Payment:
    """Customer pays quote + fee into escrow. Mock provider: the payment page's test mode.
    Razorpay: the Checkout result is accepted ONLY if its HMAC signature verifies; the
    `payment.captured` webhook is the second, independent confirmation."""
    if a.job.customer_id != customer.id:
        raise AppError("err.not_your_job", 403)
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    if p.escrow_state == EscrowState.held:
        return p  # idempotent: double-tap on "Pay" never charges twice
    if get_settings().payment_provider != "mock":
        if not (razorpay_payment_id and signature and
                services.payment().verify_checkout_signature(p.razorpay_ref or "", razorpay_payment_id, signature)):
            raise AppError("err.forbidden", 403)
    mark_held(db, p, a, actor_id=customer.id)
    p.method, p.paid_at = method, now()
    services.realtime().publish(f"job:{a.job_id}", "paid", {})
    return p


def _require_paid(db: Session, a: Assignment) -> None:
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    if not p or p.escrow_state == EscrowState.created:
        raise AppError("err.payment_pending", 409)


def mark_held(db: Session, p: Payment, a: Assignment, actor_id) -> None:
    transition(db, p, kind="escrow", field="escrow_state", new=EscrowState.held, actor_id=actor_id)
    a.escrow_status = EscrowState.held


# ------------------------------------------------------------------ work
def start_work(db: Session, actor: User, a: Assignment) -> None:
    job = a.job
    _require_paid(db, a)  # nobody starts work before the money is safely in escrow
    if job.status == JobStatus.assigned:
        transition(db, job, kind="job", field="status", new=JobStatus.in_progress, actor_id=actor.id)
        a.started_at = a.started_at or now()


# ------------------------------------------------------------------ journey (live tracking)
CITY_SPEED_KMH = 20  # two-wheeler in city traffic; used for the customer's ETA


def start_journey(db: Session, worker: User, a: Assignment, lat: float | None, lng: float | None) -> None:
    if a.worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    _require_paid(db, a)
    a.journey_started_at = a.journey_started_at or now()
    if lat is not None and lng is not None:
        update_location(db, worker, a, lat, lng)
    audit(db, actor_id=worker.id, action="journey.started", entity="assignment", entity_id=a.id)


def update_location(db: Session, worker: User, a: Assignment, lat: float, lng: float) -> None:
    if a.worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    a.worker_lat, a.worker_lng, a.worker_loc_at = lat, lng, now()
    services.realtime().publish(f"job:{a.job_id}", "worker_location", {"lat": lat, "lng": lng})


def tracking(a: Assignment) -> dict | None:
    """Distance + ETA from the worker's last shared position to the customer's house."""
    if not a.journey_started_at:
        return None
    out = {"journey_started_at": a.journey_started_at.isoformat(), "worker_lat": a.worker_lat, "worker_lng": a.worker_lng,
           "updated_at": a.worker_loc_at.isoformat() if a.worker_loc_at else None, "distance_km": None, "eta_min": None,
           "arrived": a.started_at is not None}
    if a.worker_lat is not None:
        km = services.maps().distance_km((a.worker_lat, a.worker_lng), (a.job.location_lat, a.job.location_lng))
        out["distance_km"] = round(km, 2)
        out["eta_min"] = max(1, round(km / CITY_SPEED_KMH * 60)) if km > 0.15 else 0
        out["arrived"] = out["arrived"] or km <= 0.15
    return out


def worker_done(db: Session, worker: User, a: Assignment) -> None:
    """Worker says the work is finished; the customer still confirms (complete_work) and rates."""
    if a.worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    start_work(db, worker, a)
    a.worker_done_at = a.worker_done_at or now()
    audit(db, actor_id=worker.id, action="work.worker_done", entity="assignment", entity_id=a.id)
    services.realtime().publish(f"job:{a.job_id}", "worker_done", {})


def complete_work(db: Session, customer: User, a: Assignment) -> None:
    job = a.job
    if job.customer_id != customer.id:
        raise AppError("err.not_your_job", 403)
    start_work(db, customer, a)  # assigned → in_progress if the worker never tapped "start"
    transition(db, job, kind="job", field="status", new=JobStatus.completed, actor_id=customer.id)
    a.completed_at = now()


# ------------------------------------------------------------------ ratings
def _avg(*vals: int) -> float:
    return round(sum(vals) / len(vals), 2)


def _check_stars(*vals: int) -> None:
    if any(v is None or not 1 <= v <= 5 for v in vals):
        raise AppError("err.validation", 422)


def rate_worker(db: Session, customer: User, a: Assignment, *, quality: int, timeliness: int, behaviour: int,
                value_for_money: int, comment: str | None) -> Rating:
    """Customer → worker. Overall = average of the four operational parameters (spec C5),
    computed here; a client-sent 'overall' is ignored. Submitting it releases the escrow."""
    if a.job.customer_id != customer.id:
        raise AppError("err.not_your_job", 403)
    if a.job.status != JobStatus.completed:
        raise AppError("err.job_not_completed", 409)
    _check_stars(quality, timeliness, behaviour, value_for_money)
    if db.scalar(select(Rating.id).where(Rating.assignment_id == a.id, Rating.direction == RatingDirection.customer_to_worker)):
        raise AppError("err.already_rated", 409)
    overall = _avg(quality, timeliness, behaviour, value_for_money)
    r = Rating(assignment_id=a.id, direction=RatingDirection.customer_to_worker, rater_id=customer.id,
               ratee_id=a.worker_id, quality=quality, timeliness=timeliness, behaviour=behaviour,
               value_for_money=value_for_money, overall=overall, comment=(comment or "").strip()[:500] or None)
    db.add(r)
    db.flush()
    wp = db.get(WorkerProfile, a.worker_id)
    wp.overall_rating = round((wp.overall_rating * wp.rating_count + overall) / (wp.rating_count + 1), 2)
    wp.rating_count += 1
    wp.completed_jobs += 1
    _award_badges(wp)
    audit(db, actor_id=customer.id, action="rating.submitted", entity="assignment", entity_id=a.id, overall=overall)
    release_payment(db, a, actor_id=customer.id)
    return r


def rate_customer(db: Session, worker: User, a: Assignment, *, clarity: int, timely_payment: int, comment: str | None) -> Rating:
    if a.worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    if a.job.status not in (JobStatus.completed,):
        raise AppError("err.job_not_completed", 409)
    _check_stars(clarity, timely_payment)
    if db.scalar(select(Rating.id).where(Rating.assignment_id == a.id, Rating.direction == RatingDirection.worker_to_customer)):
        raise AppError("err.already_rated", 409)
    overall = _avg(clarity, timely_payment)
    r = Rating(assignment_id=a.id, direction=RatingDirection.worker_to_customer, rater_id=worker.id,
               ratee_id=a.job.customer_id, clarity=clarity, timely_payment=timely_payment, overall=overall,
               comment=(comment or "").strip()[:500] or None)
    db.add(r)
    cp = db.get(User, a.job.customer_id).customer_profile
    if cp:
        cp.overall_rating = round((cp.overall_rating * cp.rating_count + overall) / (cp.rating_count + 1), 2)
        cp.rating_count += 1
    audit(db, actor_id=worker.id, action="rating.customer_rated", entity="assignment", entity_id=a.id, overall=overall)
    return r


BADGE_RULES = [("trusted", 4.5, 20), ("rising", 4.2, 5)]


def _award_badges(wp: WorkerProfile) -> None:
    trade = (wp.trades or ["helper"])[0]
    for tier, min_rating, min_jobs in BADGE_RULES:
        badge = f"{tier}_{trade}"
        if wp.overall_rating >= min_rating and wp.rating_count >= min_jobs and badge not in (wp.badges or []):
            wp.badges = [*(wp.badges or []), badge]


# ------------------------------------------------------------------ escrow release / refund
def release_payment(db: Session, a: Assignment, actor_id, *, by_admin: bool = False) -> Payment:
    """THE MANDATORY-RATING GATE. Money leaves escrow only if the customer→worker rating
    exists. This is enforced here, at the domain layer, so no endpoint (including a future
    one) can release without it. The only bypass is an admin resolving a dispute."""
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    if not p or p.escrow_state != EscrowState.held:
        raise AppError("err.payment_not_held", 409)
    rated = db.scalar(select(Rating.id).where(Rating.assignment_id == a.id,
                                              Rating.direction == RatingDirection.customer_to_worker))
    if not rated and not by_admin:
        raise AppError("err.rating_required", 409)
    ref = services.payment().release(p.transfer_ref or p.razorpay_ref or "")
    transition(db, p, kind="escrow", field="escrow_state", new=EscrowState.released, actor_id=actor_id,
               reason="admin_resolution" if by_admin else "rated")
    p.released_at = now()
    a.escrow_status = EscrowState.released
    wp = db.get(WorkerProfile, a.worker_id)
    wp.lifetime_earnings_paise += p.worker_payout_paise
    audit(db, actor_id=actor_id, action="payment.released", entity="payment", entity_id=p.id, ref=ref,
          payout=p.worker_payout_paise)
    return p


def refund_or_split(db: Session, a: Assignment, admin: User, worker_share_pct: int) -> Payment:
    """Admin dispute resolution. 0% → full refund; 1–99% → split; 100% → release."""
    p = db.scalar(select(Payment).where(Payment.assignment_id == a.id))
    if not p or p.escrow_state != EscrowState.held:
        raise AppError("err.payment_not_held", 409)
    if worker_share_pct >= 100:
        return release_payment(db, a, admin.id, by_admin=True)
    worker_part = p.worker_payout_paise * worker_share_pct // 100
    refund = p.amount_paise - worker_part - (p.platform_fee_paise if worker_share_pct else 0)
    services.payment().refund(p.razorpay_ref or "", refund, p.transfer_ref, p.worker_payout_paise - worker_part)
    new = EscrowState.split if worker_share_pct else EscrowState.refunded
    transition(db, p, kind="escrow", field="escrow_state", new=new, actor_id=admin.id, reason=f"worker_share={worker_share_pct}%")
    p.refund_paise = refund
    p.worker_payout_paise = worker_part
    if worker_share_pct == 0:
        p.platform_fee_paise = 0
    p.released_at = now()
    a.escrow_status = new
    if worker_part:
        db.get(WorkerProfile, a.worker_id).lifetime_earnings_paise += worker_part
    return p


# ------------------------------------------------------------------ earnings
def worker_balance(db: Session, worker_id: uuid.UUID) -> dict:
    released = db.scalar(select(func.coalesce(func.sum(Payment.worker_payout_paise), 0))
                         .join(Assignment, Assignment.id == Payment.assignment_id)
                         .where(Assignment.worker_id == worker_id,
                                Payment.escrow_state.in_([EscrowState.released, EscrowState.split]))) or 0
    held = db.scalar(select(func.coalesce(func.sum(Payment.worker_payout_paise), 0))
                     .join(Assignment, Assignment.id == Payment.assignment_id)
                     .where(Assignment.worker_id == worker_id, Payment.escrow_state == EscrowState.held)) or 0
    paid_out = db.scalar(select(func.coalesce(func.sum(Payout.amount_paise), 0))
                         .where(Payout.worker_id == worker_id, Payout.status == "processed")) or 0
    released, held, paid_out = int(released), int(held), int(paid_out)  # SUM() returns Decimal
    return {"available_paise": released - paid_out, "held_paise": held, "paid_out_paise": paid_out,
            "total_earned_paise": released}


def kyc_state(user: User) -> dict:
    s = get_settings()
    wp = user.worker_profile
    earned = wp.lifetime_earnings_paise if wp else 0
    need_l2 = user.kyc_level < 2 and earned >= s.kyc_l2_cap_paise * s.kyc_l2_prompt_ratio
    return {"level": user.kyc_level, "needs_level1": user.kyc_level < 1,
            "nudge_level2": need_l2, "blocked_by_level2": user.kyc_level < 2 and earned >= s.kyc_l2_cap_paise,
            "doc_status": (wp.aadhaar_status.value if wp and wp.kyc_doc_type == "aadhaar" else
                           wp.pan_status.value if wp and wp.kyc_doc_type == "pan" else "not_submitted"),
            "note": wp.kyc_note if wp else None, "cap_inr": s.kyc_l2_earnings_cap_inr}


def withdraw(db: Session, worker: User) -> Payout:
    wp = worker.worker_profile
    if worker.kyc_level < 1 or not wp.upi_id:
        raise AppError("err.upi_required", 409)
    if kyc_state(worker)["blocked_by_level2"]:
        raise AppError("err.kyc_l2_required", 409)
    bal = worker_balance(db, worker.id)["available_paise"]
    if bal <= 0:
        raise AppError("err.nothing_to_withdraw", 409)
    p = Payout(worker_id=worker.id, amount_paise=bal, upi_masked=mask_upi(wp.upi_id) or "",
               provider_ref=f"payout_mock_{uuid.uuid4().hex[:10]}")
    db.add(p)
    db.flush()
    audit(db, actor_id=worker.id, action="payout.processed", entity="payout", entity_id=p.id, amount=bal)
    return p


# ------------------------------------------------------------------ attendance
GEOFENCE_METERS = 300


def attendance(db: Session, worker: User, a: Assignment, *, kind: str, lat: float, lng: float, at: datetime | None,
               selfie_key: str | None, client_ref: str | None, offline: bool) -> Attendance:
    """Check-in/out. Offline captures are replayed later with their ORIGINAL timestamp and a
    client_ref, so a flaky network can never create duplicate days. Outside the geofence we
    still record (never block someone from earning) but flag it for the contractor/admin."""
    if a.worker_id != worker.id:
        raise AppError("err.forbidden", 403)
    if client_ref:
        dup = db.scalar(select(Attendance).where(Attendance.client_ref == client_ref))
        if dup:
            return dup
    at = at or now()
    inside = services.maps().distance_km((lat, lng), (a.job.location_lat, a.job.location_lng)) * 1000 <= GEOFENCE_METERS
    if kind == "in":
        row = Attendance(assignment_id=a.id, checkin_at=at, checkin_lat=lat, checkin_lng=lng,
                         checkin_selfie_url=selfie_key, offline_synced=offline, client_ref=client_ref, geofence_ok=inside)
        db.add(row)
        start_work(db, worker, a)
    else:
        row = db.scalar(select(Attendance).where(Attendance.assignment_id == a.id, Attendance.checkout_at.is_(None))
                        .order_by(Attendance.checkin_at.desc()))
        if not row:
            raise AppError("err.not_checked_in", 409)
        row.checkout_at, row.checkout_lat, row.checkout_lng = at, lat, lng
        row.geofence_ok = row.geofence_ok and inside
        row.offline_synced = row.offline_synced or offline
    db.flush()
    audit(db, actor_id=worker.id, action=f"attendance.{kind}", entity="assignment", entity_id=a.id,
          offline=offline, geofence_ok=inside)
    return row


# ------------------------------------------------------------------ disputes
def raise_dispute(db: Session, user: User, a: Assignment, reason: str) -> Dispute:
    job = a.job
    if user.id not in (job.customer_id, a.worker_id):
        raise AppError("err.forbidden", 403)
    if len(reason.strip()) < 5:
        raise AppError("err.validation", 422)
    transition(db, job, kind="job", field="status", new=JobStatus.disputed, actor_id=user.id)
    evidence = [wi.audio_url for wi in job.work_items if wi.audio_url]
    d = Dispute(assignment_id=a.id, raised_by=user.id, reason=reason.strip()[:2000], evidence_refs=evidence)
    db.add(d)
    db.flush()
    audit(db, actor_id=user.id, action="dispute.raised", entity="dispute", entity_id=d.id)
    return d


def resolve_dispute(db: Session, admin: User, d: Dispute, *, worker_share_pct: int, penalise: bool, note: str) -> Dispute:
    if admin.role != Role.admin:
        raise AppError("err.forbidden", 403)
    if d.status == DisputeStatus.resolved:
        raise AppError("err.already_resolved", 409)
    a = db.get(Assignment, d.assignment_id)
    refund_or_split(db, a, admin, max(0, min(100, worker_share_pct)))
    if penalise:
        wp = db.get(WorkerProfile, a.worker_id)
        wp.strikes += 1
        if wp.strikes >= 3:
            wp.is_suspended = True
            audit(db, actor_id=admin.id, action="worker.auto_suspended", entity="user", entity_id=a.worker_id)
    final = JobStatus.completed if worker_share_pct > 0 else JobStatus.cancelled
    transition(db, a.job, kind="job", field="status", new=final, actor_id=admin.id, reason="dispute_resolved")
    d.status, d.resolution, d.resolved_by, d.resolved_at = DisputeStatus.resolved, \
        f"worker_share={worker_share_pct}%; penalise={penalise}; {note}".strip(), admin.id, now()
    audit(db, actor_id=admin.id, action="dispute.resolved", entity="dispute", entity_id=d.id,
          worker_share_pct=worker_share_pct, penalise=penalise)
    return d
