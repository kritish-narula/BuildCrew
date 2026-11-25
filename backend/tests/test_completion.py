"""Completion disagreement flow, auto-confirm, hire release / refund rules and lifecycle edge cases.
Requires the seed (see test_phase1). Time-dependent rules are tested by BACKDATING stored timestamps."""
import uuid
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from sqlalchemy import select

from app.db import SessionLocal
from app.enums import DisputeStatus, JobStatus
from app.main import app
from app.models import Assignment, Dispute, Job, Payment, User, WorkerProfile
from app.security import _hits, issue_token

client = TestClient(app)
CUST, PLUMBER, PLUMBER2 = "9100000003", "9200000003", "9200000004"
STARS = {"quality": 5, "timeliness": 4, "behaviour": 5, "value_for_money": 4, "comment": "ok"}


def _reset_workers():
    with SessionLocal() as db:  # strikes from earlier tests must not suspend a worker mid-suite
        for wp in db.query(WorkerProfile).all():
            wp.strikes, wp.is_suspended = 0, False
        db.commit()


@pytest.fixture(scope="module", autouse=True)
def _leave_no_trace():
    """Other modules assert on seeded KPIs / the seeded dispute: close what we opened and unsuspend workers."""
    started = datetime.now(timezone.utc)
    with SessionLocal() as db:
        seeded_jobs = set(db.scalars(select(Job.id)))
    yield
    _reset_workers()
    with SessionLocal() as db:
        for d in db.query(Dispute).filter(Dispute.created_at >= started).all():
            d.status = DisputeStatus.resolved
        for j in db.query(Job).filter(Job.status.in_([JobStatus.open, JobStatus.bidding])).all():
            if j.id not in seeded_jobs:  # keep the seeded open jobs (and their audio) first in admin lists
                j.status = JobStatus.cancelled
        db.commit()


@pytest.fixture(autouse=True)
def _clean():
    _hits.clear()
    _reset_workers()


def tok(phone: str) -> dict:
    """Mint a session directly: OTP requests are rate-limited per phone and the other test modules use the same logins."""
    with SessionLocal() as db:
        user = db.scalar(select(User).where(User.phone == phone))
        return {"Authorization": f"Bearer {issue_token(user)}"}


LONG = "Kitchen sink is leaking under the counter, please fix the pipe and the tap."


def photo(h, name="x.jpg"):
    r = client.post("/media/upload", headers=h, data={"kind": "photo"}, files={"file": (name, b"\xff\xd8fake" + uuid.uuid4().bytes)})
    assert r.status_code == 200, r.text
    return r.json()["key"]


class Hire:
    def __init__(self, worker=PLUMBER, price=1500, pay=True, extra_bidder=None):
        self.c, self.w = tok(CUST), tok(worker)
        r = client.post("/customer/jobs", headers=self.c, json={
            "location_lat": 18.5986, "location_lng": 73.7604, "address_text": "B-402 Wakad",
            "start_date": str(date.today() + timedelta(days=1)),
            "work_items": [{"trade": "plumber", "text_description": LONG, "description_language": "en",
                            "photo_keys": [photo(self.c, "before.jpg"), photo(self.c, "before2.jpg")]}]})
        assert r.status_code == 200, r.text
        self.jid = r.json()["id"]
        self.other = None
        if extra_bidder:
            self.ow = tok(extra_bidder)
            self.other = client.post("/worker/bids", headers=self.ow, json={"job_id": self.jid, "price_inr": 1700}).json()["id"]
        bid = client.post("/worker/bids", headers=self.w, json={"job_id": self.jid, "price_inr": price}).json()
        self.bid = bid["id"]
        acc = client.post(f"/customer/jobs/{self.jid}/bids/{self.bid}/accept", headers=self.c)
        assert acc.status_code == 200, acc.text
        self.asg = acc.json()["assignment_id"]
        if pay:
            assert client.post(f"/customer/jobs/{self.jid}/pay", headers=self.c, json={"method": "upi"}).status_code == 200

    def job(self):
        return client.get(f"/customer/jobs/{self.jid}", headers=self.c).json()

    def a(self):
        return self.job()["assignment"]

    def done(self, note=None):
        r = client.post(f"/worker/assignments/{self.asg}/done", headers=self.w, json={"photos": [photo(self.w, "after.jpg")], "note": note})
        assert r.status_code == 200, r.text

    def rework(self, reasons=("incomplete",), note="not finished", photos=()):
        return client.post(f"/customer/jobs/{self.jid}/rework", headers=self.c, json={"reasons": list(reasons), "note": note, "photos": list(photos)})

    def pay_state(self):
        return self.a()["payment"]["escrow_state"] if self.a() else None


def backdate(asg, **hours):
    with SessionLocal() as db:
        a = db.get(Assignment, uuid.UUID(asg))
        for field, h in hours.items():
            setattr(a, field, datetime.now(timezone.utc) - timedelta(hours=h))
        db.commit()


def error(r):
    return r.json()["error"]["code"]


# ------------------------------------------------------------------ send back / redo / confirm
def test_proof_photo_is_required_and_customer_sees_before_and_after():
    h = Hire()
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=h.w, json={"photos": []}).status_code == 422
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=h.w).status_code == 422
    assert h.a()["worker_done_at"] is None
    h.done("Tap replaced")
    a = h.a()
    assert a["worker_done_at"] and len(a["proof_photos"]) == 1 and a["worker_done_note"] == "Tap replaced"
    assert len(a["before_photos"]) == 2 and a["auto_confirm_at"]
    h.done()  # double tap / offline replay: still ONE "finished" event
    assert [e["kind"] for e in h.a()["timeline"]] == ["worker_done"]


def test_send_back_redo_then_confirm_rate_and_release():
    h = Hire()
    h.done()
    ev = photo(h.c, "evidence.jpg")
    r = h.rework(("poor_quality", "damage"), "Tile cracked", [ev])
    assert r.status_code == 200 and r.json() == {"outcome": "rework", "rework_count": 1, "rework_left": 1}
    a = h.a()
    assert a["rework_open"] and a["worker_done_at"] is None and a["auto_confirm_at"] is None
    assert a["rework"]["reasons"] == ["poor_quality", "damage"] and a["rework"]["note"] == "Tile cracked" and len(a["rework"]["photos"]) == 1
    # the worker sees the same card in their own list
    mine = next(x for x in client.get("/worker/assignments", headers=h.w).json() if x["id"] == h.asg)
    assert mine["rework_open"] and mine["rework"]["reasons"] == ["poor_quality", "damage"]
    # cannot send back twice in a row, nor confirm-by-silence while the worker still has to fix it
    assert error(h.rework()) == "err.nothing_to_send_back"
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=h.w, json={"photos": []}).status_code == 422  # new proof needed
    h.done("Fixed")
    assert not h.a()["rework_open"] and h.a()["auto_confirm_at"]
    assert client.post(f"/customer/jobs/{h.jid}/complete", headers=h.c).status_code == 200
    assert client.post(f"/customer/jobs/{h.jid}/complete", headers=h.c).status_code == 200  # idempotent
    assert client.post(f"/customer/jobs/{h.jid}/release", headers=h.c).status_code == 409  # rating still required
    assert client.post(f"/customer/jobs/{h.jid}/rate", headers=h.c, json=STARS).json()["payment"]["escrow_state"] == "released"
    assert [e["kind"] for e in h.a()["timeline"]] == ["worker_done", "rework_requested", "worker_done", "confirmed"]


def test_rework_validation():
    h = Hire()
    assert error(h.rework()) == "err.nothing_to_send_back"  # worker has not said "finished"
    h.done()
    assert h.rework(("bogus",)).status_code == 422
    assert h.rework(()).status_code == 422
    assert h.rework(("other",), "x" * 1001).status_code == 422
    assert client.post(f"/customer/jobs/{h.jid}/rework", headers=tok("9100000001"),
                       json={"reasons": ["other"]}).status_code == 404  # not their job
    assert h.rework(("other",), None).status_code == 200


def test_third_disagreement_opens_dispute_and_money_stays_frozen():
    h = Hire()
    for rnd in (1, 2):
        h.done()
        assert h.rework(("incomplete",), f"round {rnd}").json()["rework_count"] == rnd
    h.done()
    r = h.rework(("incomplete",), "still not done")
    assert r.status_code == 200 and r.json()["outcome"] == "disputed"
    assert h.job()["status"] == "disputed" and h.pay_state() == "held"
    kinds = [e["kind"] for e in h.a()["timeline"]]
    assert kinds[-2:] == ["rework_requested", "disputed"] and kinds.count("rework_requested") == 3
    # frozen: nobody can confirm, send back, mark done, rate, or release
    assert error(client.post(f"/customer/jobs/{h.jid}/complete", headers=h.c)) == "err.job_disputed"
    assert error(h.rework()) == "err.job_disputed"
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=h.w, json={"photos": ["k"]}).status_code == 409
    assert client.post(f"/customer/jobs/{h.jid}/rate", headers=h.c, json=STARS).status_code == 409
    assert client.post(f"/customer/jobs/{h.jid}/release", headers=h.c).status_code == 409
    assert error(client.post(f"/customer/jobs/{h.jid}/cancel", headers=h.c)) == "err.job_closed"
    # a manual dispute tap is idempotent
    d1 = client.post(f"/customer/jobs/{h.jid}/dispute", headers=h.c, json={"reason": "please help"}).json()
    # admin decides with the existing resolver: 40 % to the worker
    admin = tok("9000000001")
    open_d = next(d for d in client.get("/admin/disputes", headers=admin).json() if d["id"] == d1["id"])
    assert open_d["status"] == "open"
    ev = client.get(f"/admin/disputes/{d1['id']}", headers=admin).json()
    assert len(ev["assignment"]["timeline"]) >= 7 and len(ev["assignment"]["proof_photos"]) == 1
    res = client.post(f"/admin/disputes/{d1['id']}/resolve", headers=admin, json={"worker_share_pct": 40, "penalise": False, "note": "split"})
    assert res.status_code == 200
    assert h.pay_state() == "split" and h.job()["status"] == "completed"
    assert h.a()["payment"]["worker_payout_inr"] == 600  # 40 % of 1500


def test_worker_can_raise_a_dispute_when_customer_is_unfair():
    h = Hire()
    assert error(client.post(f"/worker/assignments/{h.asg}/dispute", headers=h.w, json={"reason": "customer ignoring me"})) == "err.too_early_to_dispute"
    h.done()
    r = client.post(f"/worker/assignments/{h.asg}/dispute", headers=h.w, json={"reason": "customer is not confirming"})
    assert r.status_code == 200
    assert h.job()["status"] == "disputed" and h.pay_state() == "held"
    assert client.post(f"/worker/assignments/{h.asg}/dispute", headers=h.w, json={"reason": "customer is not confirming"}).json()["id"] == r.json()["id"]
    assert [e["kind"] for e in h.a()["timeline"]][-1] == "disputed"
    # dispute needs money in escrow: an unpaid hire is cancelled instead
    u = Hire(pay=False)
    assert error(client.post(f"/customer/jobs/{u.jid}/dispute", headers=u.c, json={"reason": "no pay yet"})) == "err.payment_not_held"


# ------------------------------------------------------------------ auto-confirm
def test_auto_confirm_after_48h_pays_worker_with_neutral_rating():
    h = Hire()
    with SessionLocal() as db:
        wp = db.get(WorkerProfile, db.get(Assignment, uuid.UUID(h.asg)).worker_id)
        avg0, cnt0, jobs0 = wp.overall_rating, wp.rating_count, wp.completed_jobs
    h.done()
    backdate(h.asg, worker_done_at=47)
    a = h.a()  # 47 h: still waiting, countdown visible
    assert h.job()["status"] == "in_progress" and a["auto_confirm_at"] and not a["auto_confirmed"]
    backdate(h.asg, worker_done_at=49)
    j = h.job()  # the customer's next open after 48 h
    assert j["status"] == "completed" and j["assignment"]["auto_confirmed"] and j["assignment"]["payment"]["escrow_state"] == "released"
    assert j["assignment"]["ratings"]["customer_to_worker"]["is_auto"] is True
    assert [e["kind"] for e in j["assignment"]["timeline"]] == ["worker_done", "auto_confirmed"]
    with SessionLocal() as db:
        wp = db.get(WorkerProfile, db.get(Assignment, uuid.UUID(h.asg)).worker_id)
        assert (wp.overall_rating, wp.rating_count) == (avg0, cnt0) and wp.completed_jobs == jobs0 + 1  # average untouched
    hist = client.get("/worker/profile", headers=h.w).json()
    assert all(x["job_id"] != h.jid for x in hist["history"])
    assert error(client.post(f"/customer/jobs/{h.jid}/rate", headers=h.c, json=STARS)) == "err.already_rated"
    assert client.post(f"/customer/jobs/{h.jid}/rework", headers=h.c, json={"reasons": ["other"]}).status_code == 409
    # the worker may still rate the customer
    assert client.post(f"/worker/assignments/{h.asg}/rate-customer", headers=h.w, json={"clarity": 5, "timely_payment": 3}).status_code == 200


def test_auto_confirm_never_fires_while_reworking_or_disputed():
    h = Hire()
    h.done()
    h.rework()
    backdate(h.asg, worker_done_at=100)  # stale stamp must not matter: the worker owes a fix, not the customer a reply
    assert h.job()["status"] == "in_progress" and h.pay_state() == "held"
    d = Hire()
    d.done()
    client.post(f"/customer/jobs/{d.jid}/dispute", headers=d.c, json={"reason": "work is bad"})
    backdate(d.asg, worker_done_at=100)
    assert d.job()["status"] == "disputed" and d.pay_state() == "held"
    w = next(x for x in client.get("/worker/assignments", headers=h.w).json() if x["id"] == h.asg)
    assert w["job"]["status"] == "in_progress"


def test_confirmed_but_never_rated_for_48h_releases_with_neutral_rating():
    h = Hire()
    h.done()
    client.post(f"/customer/jobs/{h.jid}/complete", headers=h.c)
    assert h.pay_state() == "held"
    backdate(h.asg, completed_at=49)
    assert h.job()["status"] == "completed" and h.pay_state() == "released"
    assert h.a()["timeline"][-1]["kind"] == "auto_rated"


def test_listing_sweeps_due_assignments_for_the_worker():
    h = Hire()
    h.done()
    backdate(h.asg, worker_done_at=50)
    mine = next(x for x in client.get("/worker/assignments", headers=h.w).json() if x["id"] == h.asg)
    assert mine["job"]["status"] == "completed" and mine["payment"]["escrow_state"] == "released"


# ------------------------------------------------------------------ cancel / refund / re-open
def test_cancel_after_accept_before_payment_voids_the_order():
    h = Hire(pay=False)
    r = client.post(f"/customer/jobs/{h.jid}/cancel", headers=h.c)
    assert r.status_code == 200 and r.json()["status"] == "cancelled"
    assert client.post(f"/customer/jobs/{h.jid}/cancel", headers=h.c).json()["status"] == "cancelled"  # double tap
    with SessionLocal() as db:
        assert db.query(Payment).filter(Payment.assignment_id == uuid.UUID(h.asg)).count() == 0  # nothing ever charged
    # a stale payment page cannot charge anything afterwards
    r = client.post(f"/customer/jobs/{h.jid}/pay", headers=h.c, json={"method": "upi"})
    assert r.status_code == 409 and error(r) == "err.hire_cancelled"


def test_cancel_after_payment_before_start_refunds_in_full():
    h = Hire()
    assert h.pay_state() == "held"
    r = client.post(f"/customer/jobs/{h.jid}/cancel", headers=h.c).json()
    assert r["status"] == "cancelled" and r["refunded_inr"] == 1530  # quote + platform fee
    with SessionLocal() as db:
        p = db.query(Payment).filter(Payment.assignment_id == uuid.UUID(h.asg)).one()
        assert p.escrow_state.value == "refunded" and p.refund_paise == 153000 and p.worker_payout_paise == 0
    pays = client.get("/customer/payments", headers=h.c).json()
    assert any(x["job_id"] == h.jid and x["escrow_state"] == "refunded" for x in pays)
    assert all(x["id"] != h.asg for x in client.get("/worker/assignments", headers=h.w).json())  # gone from the worker's list


def test_cancel_after_work_started_must_go_through_support():
    h = Hire()
    client.post(f"/worker/assignments/{h.asg}/start", headers=h.w)
    r = client.post(f"/customer/jobs/{h.jid}/cancel", headers=h.c)
    assert r.status_code == 409 and error(r) == "err.job_started_dispute"
    assert h.pay_state() == "held"
    assert client.post(f"/customer/jobs/{h.jid}/dispute", headers=h.c, json={"reason": "I want to stop this job"}).status_code == 200
    r = client.post(f"/customer/jobs/{h.jid}/reopen", headers=h.c)
    assert r.status_code == 409


def test_change_worker_refunds_and_brings_earlier_quotes_back():
    h = Hire(extra_bidder=PLUMBER2)
    assert h.job()["status"] == "assigned"
    r = client.post(f"/customer/jobs/{h.jid}/reopen", headers=h.c).json()
    assert r["status"] == "bidding" and r["refunded_inr"] == 1530
    j = h.job()
    assert j["assignment"] is None and [b["status"] for b in j["bids"]] == ["pending"]  # the other worker's quote is back; the old one is gone
    assert client.post(f"/customer/jobs/{h.jid}/reopen", headers=h.c).json()["status"] == "bidding"  # double tap
    acc = client.post(f"/customer/jobs/{h.jid}/bids/{h.other}/accept", headers=h.c)
    assert acc.status_code == 200 and acc.json()["assignment_id"] != h.asg
    assert client.post(f"/customer/jobs/{h.jid}/pay", headers=h.c, json={"method": "upi"}).json()["escrow_state"] == "held"
    assert client.post(f"/customer/jobs/{h.jid}/pay", headers=h.c, json={"method": "upi"}).json()["escrow_state"] == "held"  # paying twice charges once
    with SessionLocal() as db:
        assert db.get(Job, uuid.UUID(h.jid)).status.value == "assigned"
        held = [p for p in db.query(Payment).join(Assignment, Assignment.id == Payment.assignment_id)
                .filter(Assignment.job_id == uuid.UUID(h.jid)).all() if p.escrow_state.value == "held"]
        assert len(held) == 1


def test_worker_withdraws_after_being_hired():
    h = Hire(worker=PLUMBER2)
    r = client.post(f"/worker/assignments/{h.asg}/withdraw", headers=h.w)
    assert r.status_code == 200 and r.json()["refunded_inr"] == 1530
    assert h.job()["status"] == "open" and h.job()["assignment"] is None
    assert client.post(f"/worker/assignments/{h.asg}/withdraw", headers=h.w).status_code == 200  # idempotent
    prof = client.get("/worker/profile", headers=h.w).json()
    assert prof["strikes"] == 1
    # withdrawing from an unpaid hire costs nothing
    u = Hire(worker=PLUMBER2, pay=False)
    client.post(f"/worker/assignments/{u.asg}/withdraw", headers=u.w)
    assert client.get("/worker/profile", headers=u.w).json()["strikes"] == 1


def test_no_show_needs_the_eta_plus_60_minutes():
    h = Hire()
    client.post(f"/worker/assignments/{h.asg}/journey", headers=h.w, json={"lat": 18.6250, "lng": 73.7604})  # ~9 min ETA
    r = client.post(f"/customer/jobs/{h.jid}/no-show", headers=h.c)
    assert r.status_code == 409 and error(r) == "err.no_show_too_early"
    a = h.a()
    assert a["no_show_after"] and a["can_report_no_show"] is False
    backdate(h.asg, expected_arrival_at=2)  # ETA was 2 h ago -> 60 min grace is over
    assert h.a()["can_report_no_show"] is True
    r = client.post(f"/customer/jobs/{h.jid}/no-show", headers=h.c)
    assert r.status_code == 200 and r.json()["refunded_inr"] == 1530 and r.json()["status"] in ("open", "bidding")
    assert client.get("/worker/profile", headers=h.w).json()["strikes"] == 1
    assert error(client.post(f"/customer/jobs/{h.jid}/no-show", headers=h.c)) == "err.hire_cancelled"


def test_no_show_refused_once_the_worker_checked_in():
    h = Hire()
    client.post(f"/worker/attendance", headers=h.w, json={"assignment_id": h.asg, "kind": "in", "lat": 18.5987, "lng": 73.7605})
    backdate(h.asg, expected_arrival_at=5)
    assert error(client.post(f"/customer/jobs/{h.jid}/no-show", headers=h.c)) == "err.job_started"


def test_third_strike_suspends_the_worker():
    for _ in range(3):
        h = Hire(worker=PLUMBER2)
        assert client.post(f"/worker/assignments/{h.asg}/withdraw", headers=h.w).status_code == 200
    with SessionLocal() as db:
        assert db.query(WorkerProfile).filter(WorkerProfile.strikes >= 3, WorkerProfile.is_suspended.is_(True)).count() == 1
    assert client.get("/worker/profile", headers=h.w).status_code == 403  # suspended accounts are blocked everywhere


# ------------------------------------------------------------------ misc edge cases
def test_job_date_in_the_past_or_absurdly_far_is_rejected():
    c = tok(CUST)
    body = {"location_lat": 18.5, "location_lng": 73.8, "address_text": "Somewhere 12",
            "work_items": [{"trade": "plumber", "text_description": LONG, "photo_keys": [photo(c), photo(c)]}]}
    r = client.post("/customer/jobs", headers=c, json={**body, "start_date": str(date.today() - timedelta(days=2))})
    assert r.status_code == 422 and error(r) == "err.date_in_past"
    r = client.post("/customer/jobs", headers=c, json={**body, "start_date": str(date.today() + timedelta(days=800))})
    assert r.status_code == 422 and error(r) == "err.date_too_far"
    assert client.post("/customer/jobs", headers=c, json={**body, "start_date": str(date.today())}).status_code == 200


def test_prices_zero_negative_and_huge_are_rejected():
    c, w = tok(CUST), tok(PLUMBER)
    jid = Hire(pay=False).jid
    for bad in (0, -50, 99, 10_000_001):
        assert client.post("/worker/bids", headers=w, json={"job_id": jid, "price_inr": bad}).status_code == 422


def test_no_quotes_for_24h_hint_and_nudge_cooldown():
    c = tok(CUST)
    jid = client.post("/customer/jobs", headers=c, json={"location_lat": 18.5, "location_lng": 73.8, "address_text": "Nowhere 12",
                      "start_date": str(date.today() + timedelta(days=1)), "work_items": [{"trade": "painter", "text_description": LONG, "photo_keys": [photo(c), photo(c)]}]}).json()["id"]
    assert client.get(f"/customer/jobs/{jid}", headers=c).json()["no_quotes_24h"] is False
    with SessionLocal() as db:
        db.get(Job, uuid.UUID(jid)).created_at = datetime.now(timezone.utc) - timedelta(hours=30)
        db.commit()
    assert client.get(f"/customer/jobs/{jid}", headers=c).json()["no_quotes_24h"] is True
    assert next(j for j in client.get("/customer/jobs", headers=c).json() if j["id"] == jid)["no_quotes_24h"] is True
    assert client.post(f"/customer/jobs/{jid}/nudge", headers=c).status_code == 200
    assert error(client.post(f"/customer/jobs/{jid}/nudge", headers=c)) == "err.nudge_too_soon"
    assert client.get(f"/customer/jobs/{jid}", headers=c).json()["nudged_at"]


def test_chat_with_a_worker_who_was_not_hired_is_read_only():
    h = Hire(pay=False, extra_bidder=PLUMBER2)  # PLUMBER2 quoted too, PLUMBER won
    loser = h.ow
    with SessionLocal() as db:
        from app.models import Bid
        loser_id = str(db.get(Bid, uuid.UUID(h.other)).worker_id)
        winner_id = str(db.get(Bid, uuid.UUID(h.bid)).worker_id)
    cust_id = client.get(f"/worker/jobs/{h.jid}", headers=h.w).json()["customer_id"]
    # the hired worker keeps chatting; the loser can read but not write; the customer can't write to the loser either
    assert client.post(f"/jobs/{h.jid}/chat", headers=h.w, json={"to": cust_id, "body": "hello"}).status_code == 200
    r = client.post(f"/jobs/{h.jid}/chat", headers=h.ow, json={"to": cust_id, "body": "still there?"})
    assert r.status_code == 409 and error(r) == "err.chat_closed"
    r = client.post(f"/jobs/{h.jid}/chat", headers=h.c, json={"to": loser_id, "body": "sorry"})
    assert r.status_code == 409 and error(r) == "err.chat_closed"
    assert client.get(f"/jobs/{h.jid}/chat", headers=h.ow, params={"with": cust_id}).status_code == 200  # history stays readable
    assert client.post(f"/jobs/{h.jid}/chat", headers=h.c, json={"to": winner_id, "body": "x" * 1001}).status_code == 422  # long text
    assert client.post(f"/jobs/{h.jid}/chat", headers=h.c, json={"to": winner_id, "body": "see you"}).status_code == 200


def test_long_text_is_capped_everywhere():
    h = Hire()
    h.done()
    assert client.post(f"/customer/jobs/{h.jid}/dispute", headers=h.c, json={"reason": "x" * 2001}).status_code == 422
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=h.w, json={"photos": ["k"], "note": "y" * 1001}).status_code == 422
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=h.w, json={"photos": ["k"] * 6}).status_code == 422


def test_account_switch_cannot_act_on_someone_elses_job():
    h = Hire()
    h.done()
    other = tok("9100000001")
    for path, body in (("complete", None), ("rework", {"reasons": ["other"]}), ("cancel", None), ("reopen", None), ("no-show", None),
                       ("dispute", {"reason": "not my job at all"})):
        r = client.post(f"/customer/jobs/{h.jid}/{path}", headers=other, json=body) if body else client.post(f"/customer/jobs/{h.jid}/{path}", headers=other)
        assert r.status_code == 404, path
    other_worker = tok("9200000001")
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=other_worker, json={"photos": ["k"]}).status_code == 404
    assert client.post(f"/customer/jobs/{h.jid}/complete", headers=tok("9200000001")).status_code == 403  # a worker is not a customer
    assert h.pay_state() == "held"


def test_suspended_worker_is_blocked_but_customer_is_told_and_can_replace_them():
    h = Hire()
    with SessionLocal() as db:
        db.get(WorkerProfile, db.get(Assignment, uuid.UUID(h.asg)).worker_id).is_suspended = True
        db.commit()
    assert client.post(f"/worker/assignments/{h.asg}/done", headers=h.w, json={"photos": ["k"]}).status_code == 403
    assert h.a()["worker_suspended"] is True
    r = client.post(f"/customer/jobs/{h.jid}/reopen", headers=h.c)
    assert r.status_code == 200 and r.json()["refunded_inr"] == 1530
