"""Trust & worker-growth features: start-work code, share trip, police verification, work warranty (free
re-fix), same-day pay, skill ladder + streak, hire-again direct requests. Requires the seed."""
from app.domain.flows import today_ist
import uuid
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app.db import SessionLocal
from app.domain import levels, pricing, trust
from app.enums import DisputeStatus, JobStatus
from app.main import app
from app.models import Assignment, Attendance, Dispute, Job, Payment, Payout, TripShare, User, WorkerProfile
from app.security import _hits, issue_token

client = TestClient(app)
PRIYA, NEHA, ANIL, ADMIN = "9100000001", "9100000003", "9100000002", "9000000001"
MURUGAN, SHAMSHAD, IMRAN = "9200000013", "9200000014", "9200000003"  # plumbers

def new_l0_worker(trade: str = "carpenter") -> str:
    """A brand-new phone-verified (level 0) worker: no name, selfie or UPI yet."""
    from app.enums import Role
    phone = "93" + uuid.uuid4().hex[:8].translate(str.maketrans("abcdef", "123456"))
    with SessionLocal() as db:
        u = User(phone=phone, role=Role.worker, language_code="hi", kyc_level=0)
        db.add(u)
        db.flush()
        db.add(WorkerProfile(user_id=u.id, trades=[trade], city="Pune", home_lat=SITE[0], home_lng=SITE[1]))
        db.commit()
    return phone


RAMESH = "9200000001"  # mason, police verified in the seed
STARS = {"quality": 5, "timeliness": 5, "behaviour": 5, "value_for_money": 5, "comment": "great"}
LONG = "Kitchen sink is leaking under the counter, please fix the pipe and the tap."
SITE = (18.5986, 73.7604)


def tok(phone: str) -> dict:
    with SessionLocal() as db:
        return {"Authorization": f"Bearer {issue_token(db.scalar(select(User).where(User.phone == phone)))}"}


def err(r) -> str:
    return r.json()["error"]["code"]


def photo(h, name="x.jpg"):
    r = client.post("/media/upload", headers=h, data={"kind": "photo"}, files={"file": (name, b"\xff\xd8fake" + uuid.uuid4().bytes)})
    assert r.status_code == 200, r.text
    return r.json()["key"]


@pytest.fixture(autouse=True)
def _clean():
    _hits.clear()
    with SessionLocal() as db:
        for wp in db.query(WorkerProfile).all():
            wp.strikes, wp.is_suspended = 0, False
        db.commit()


@pytest.fixture(scope="module", autouse=True)
def _leave_no_trace():
    started = datetime.now(timezone.utc)
    yield
    with SessionLocal() as db:
        for d in db.query(Dispute).filter(Dispute.created_at >= started).all():
            d.status = DisputeStatus.resolved
        for j in db.query(Job).filter(Job.status.in_([JobStatus.open, JobStatus.bidding]), Job.created_at >= started).all():
            j.status = JobStatus.cancelled
        db.commit()


class Hire:
    """A single-worker job taken all the way to a PAID hire."""

    def __init__(self, worker=MURUGAN, cust=PRIYA, trade="plumber", price=1500, pay=True, direct=None):
        self.c, self.w, self.phone = tok(cust), tok(worker), worker
        body = {"location_lat": SITE[0], "location_lng": SITE[1], "address_text": "B-402 Wakad",
                "start_date": str(today_ist() + timedelta(days=1)),
                "work_items": [{"trade": trade, "text_description": LONG, "description_language": "en",
                                "photo_keys": [photo(self.c, "b1.jpg"), photo(self.c, "b2.jpg")]}]}
        if direct:
            body["direct_worker_id"] = direct
        r = client.post("/customer/jobs", headers=self.c, json=body)
        assert r.status_code == 200, r.text
        self.jid = r.json()["id"]
        if direct and worker is None:
            return
        self.bid = client.post("/worker/bids", headers=self.w, json={"job_id": self.jid, "price_inr": price}).json()["id"]
        self.asg = client.post(f"/customer/jobs/{self.jid}/bids/{self.bid}/accept", headers=self.c).json()["assignment_id"]
        if pay:
            assert client.post(f"/customer/jobs/{self.jid}/pay", headers=self.c, json={"method": "upi"}).status_code == 200

    def job(self):
        return client.get(f"/customer/jobs/{self.jid}", headers=self.c).json()

    def a(self):
        return self.job()["assignment"]

    def code(self):
        return self.a()["start_code"]["code"]

    def start(self, code=None):
        return client.post(f"/worker/assignments/{self.asg}/start", headers=self.w, json={"code": code or self.code()})

    def done(self):
        if self.a()["started_at"] is None:
            assert self.start().status_code == 200
        r = client.post(f"/worker/assignments/{self.asg}/done", headers=self.w, json={"photos": [photo(self.w, "after.jpg")]})
        assert r.status_code == 200, r.text

    def finish(self):
        """done -> customer confirms -> rated -> released."""
        self.done()
        assert client.post(f"/customer/jobs/{self.jid}/complete", headers=self.c).status_code == 200
        r = client.post(f"/customer/jobs/{self.jid}/rate", headers=self.c, json=STARS)
        assert r.status_code == 200, r.text

    def sql(self, fn):
        with SessionLocal() as db:
            fn(db, db.get(Assignment, uuid.UUID(self.asg)))
            db.commit()


# ================================================================== 1. start-work code
def test_customer_sees_a_4_digit_code_after_paying_and_the_worker_never_does():
    h = Hire(pay=False)
    assert h.a()["start_code"] is None  # nothing to show before the payment
    client.post(f"/customer/jobs/{h.jid}/pay", headers=h.c, json={"method": "upi"})
    sc = h.a()["start_code"]
    assert len(sc["code"]) == 4 and sc["code"].isdigit() and sc["needed"] and sc["attempts_left"] == 5
    mine = next(a for a in client.get("/worker/assignments", headers=h.w).json() if a["id"] == h.asg)
    assert "start_code" not in mine and mine["start_code_state"] == "needed"
    assert sc["code"] not in str(mine)
    # derived, never stored: the same code every time, nothing readable in the DB
    assert h.code() == sc["code"]
    with SessionLocal() as db:
        a = db.get(Assignment, uuid.UUID(h.asg))
        assert a.start_code_nonce and sc["code"] != a.start_code_nonce


def test_work_cannot_start_without_the_right_code():
    h = Hire()
    r = client.post(f"/worker/assignments/{h.asg}/start", headers=h.w)
    assert r.status_code == 422 and err(r) == "err.start_code_required"
    wrong = "0000" if h.code() != "0000" else "1111"
    r = h.start(wrong)
    assert r.status_code == 409 and err(r) == "err.start_code_invalid"
    assert h.a()["start_code"]["attempts_left"] == 4  # the wrong try was remembered (and committed)
    check = {"assignment_id": h.asg, "kind": "in", "lat": SITE[0], "lng": SITE[1]}
    assert err(client.post("/worker/attendance", headers=h.w, json=check)) == "err.start_code_required"
    assert err(client.post("/worker/attendance", headers=h.w, json={**check, "start_code": wrong})) == "err.start_code_invalid"
    # finishing the work without ever starting it is refused too
    r = client.post(f"/worker/assignments/{h.asg}/done", headers=h.w, json={"photos": [photo(h.w)]})
    assert err(r) == "err.start_code_required"
    ok = client.post("/worker/attendance", headers=h.w, json={**check, "start_code": h.code()})
    assert ok.status_code == 200 and ok.json()["code_status"] == "verified"
    assert h.job()["status"] == "in_progress"
    assert h.a()["start_code"]["needed"] is False and h.a()["start_code"]["code"] is None  # no longer shown once used


def test_five_wrong_codes_lock_for_ten_minutes():
    h = Hire()
    wrong = "0000" if h.code() != "0000" else "1111"
    for i in range(4):
        r = h.start(wrong)
        assert err(r) == "err.start_code_invalid"
    r = h.start(wrong)
    assert r.status_code == 429 and err(r) == "err.start_code_locked" and "10" in r.json()["error"]["message"]
    assert err(h.start()) == "err.start_code_locked"  # even the RIGHT code is refused while locked
    assert h.a()["start_code"]["state"] == "locked" and h.a()["start_code"]["locked_until"]
    assert next(a for a in client.get("/worker/assignments", headers=h.w).json() if a["id"] == h.asg)["start_code_state"] == "locked"
    h.sql(lambda db, a: setattr(a, "start_code_locked_until", datetime.now(timezone.utc) - timedelta(minutes=1)))  # 10 minutes later
    assert h.start().status_code == 200


def test_offline_check_in_is_verified_when_it_syncs():
    # right code typed offline -> verified on sync, work starts
    h = Hire()
    at = (datetime.now(timezone.utc) - timedelta(minutes=30)).isoformat()
    row = {"assignment_id": h.asg, "kind": "in", "lat": SITE[0], "lng": SITE[1], "offline": True, "at": at, "client_ref": uuid.uuid4().hex}
    r = client.post("/worker/attendance", headers=h.w, json={**row, "start_code": h.code()})
    assert r.status_code == 200 and r.json()["code_status"] == "verified" and h.job()["status"] == "in_progress"
    # replay is idempotent
    assert client.post("/worker/attendance", headers=h.w, json={**row, "start_code": h.code()}).json()["code_status"] == "verified"
    # wrong code on sync: recorded as evidence but the work does NOT start (and no no-show dodging)
    h2 = Hire(worker=SHAMSHAD)
    wrong = "0000" if h2.code() != "0000" else "1111"
    r = client.post("/worker/attendance", headers=h2.w, json={**row, "assignment_id": h2.asg, "client_ref": uuid.uuid4().hex, "start_code": wrong})
    assert r.status_code == 200 and r.json()["code_status"] == "failed"
    assert h2.job()["status"] == "assigned" and h2.a()["attendance"][0]["code_status"] == "failed"
    assert next(a for a in client.get("/worker/assignments", headers=h2.w).json() if a["id"] == h2.asg)["start_code_state"] == "failed"
    # no code at all while offline: "pending" until the worker confirms with a connection
    h3 = Hire(worker=IMRAN)
    r = client.post("/worker/attendance", headers=h3.w, json={**row, "assignment_id": h3.asg, "client_ref": uuid.uuid4().hex})
    assert r.json()["code_status"] == "pending" and h3.job()["status"] == "assigned"
    assert h3.start().status_code == 200
    assert h3.a()["attendance"][0]["code_status"] == "verified" and h3.job()["status"] == "in_progress"
    # offline tries cannot be used to guess: they count against the same 5-try lock
    h4 = Hire()
    wrong4 = "0000" if h4.code() != "0000" else "1111"
    for _ in range(5):
        client.post("/worker/attendance", headers=h4.w, json={**row, "assignment_id": h4.asg, "client_ref": uuid.uuid4().hex, "start_code": wrong4})
    assert h4.a()["start_code"]["state"] == "locked"


def test_team_code_is_per_worker_per_day_on_the_roster():
    c, w1 = tok(ANIL), tok(RAMESH)
    r = client.post("/customer/jobs", headers=c, json={
        "location_lat": 18.5089, "location_lng": 73.9260, "address_text": "Plot 9, Hadapsar", "city": "Pune", "kind": "team",
        "start_date": str(today_ist() + timedelta(days=1)),
        "work_items": [{"trade": "mason", "text_description": "Boundary wall and plaster for a new plot, bring tools.", "description_language": "en",
                        "photo_keys": [photo(c), photo(c)], "headcount": 1, "days": 2, "daily_wage_inr": 1000}]})
    jid = r.json()["id"]
    bid = client.post("/worker/bids", headers=w1, json={"job_id": jid, "price_inr": 1000}).json()["id"]
    assert client.post(f"/customer/jobs/{jid}/bids/{bid}/accept", headers=c).status_code == 200
    ros = client.get(f"/customer/jobs/{jid}/team", headers=c).json()
    assert ros["workers"][0]["start_code"] is None  # not paid yet
    client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi"})
    row = client.get(f"/customer/jobs/{jid}/team", headers=c).json()["workers"][0]
    code, asg = row["start_code"]["code"], row["assignment_id"]
    assert len(code) == 4 and row["start_code"]["verified_today"] is False
    chk = {"assignment_id": asg, "kind": "in", "lat": 18.5089, "lng": 73.9260}
    assert err(client.post("/worker/attendance", headers=w1, json=chk)) == "err.start_code_required"
    assert client.post("/worker/attendance", headers=w1, json={**chk, "start_code": code}).status_code == 200
    row = client.get(f"/customer/jobs/{jid}/team", headers=c).json()["workers"][0]
    assert row["start_code"]["verified_today"] is True and row["present_today"] and row["days_worked"] == 1
    with SessionLocal() as db:  # tomorrow's code is another number, derived from the same hire
        a = db.get(Assignment, uuid.UUID(asg))
        tomorrow = datetime.now(timezone.utc) + timedelta(days=1)
        assert trust.start_code_required(db, a, tomorrow) is True and trust.start_code_required(db, a) is False
        # a check-in whose code failed on sync never counts as a worked day
        db.add(Attendance(assignment_id=a.id, checkin_at=tomorrow, checkin_lat=1, checkin_lng=1, code_status="failed"))
        db.commit()
        from app.domain import team
        assert team.days_worked(db, a) == 1
    client.post(f"/customer/jobs/{jid}/cancel", headers=c)


# ================================================================== 2. share live trip
def test_share_trip_link_is_public_unguessable_and_leaks_nothing():
    h = Hire(worker=SHAMSHAD)
    assert err(client.post(f"/customer/jobs/{h.jid}/share-trip", headers=h.c)) == "err.trip_not_active"  # not on the way yet
    assert client.post(f"/worker/assignments/{h.asg}/journey", headers=h.w, json={"lat": SITE[0] + 0.02, "lng": SITE[1] - 0.01}).status_code == 200
    r = client.post(f"/customer/jobs/{h.jid}/share-trip", headers=h.c)
    assert r.status_code == 200, r.text
    s = r.json()
    assert s["url"] == f"https://buildcrew.app/t/{s['token']}" and len(s["token"]) >= 30
    assert "*" in s["worker_phone_masked"] and s["trade"] == "plumber"
    assert client.post(f"/customer/jobs/{h.jid}/share-trip", headers=h.c).json()["token"] == s["token"]  # same link while it lives
    assert err(client.post(f"/customer/jobs/{h.jid}/share-trip", headers=tok(NEHA))) == "err.not_found"  # someone else's job
    pub = client.get(f"/public/trip/{s['token']}")  # no Authorization header at all
    assert pub.status_code == 200
    d = pub.json()
    assert d["name"] == "Shamshad Alam" and d["trade"] == "plumber" and d["distance_km"] > 0 and d["eta_min"] >= 1
    assert {"photo", "rating", "police_verified", "expires_at", "status"} <= set(d)
    blob = str(d)
    for secret in ("B-402", "Wakad", "Priya", "9200000014", h.phone, "lat", "lng", str(SITE[0])):
        assert secret not in blob  # no address, customer, phone or exact coordinates
    assert client.get("/public/trip/" + "x" * 32).status_code == 404
    page = client.get(f"/t/{s['token']}")
    assert page.status_code == 200 and "Shamshad" in page.text and "B-402" not in page.text
    # arriving (the check-in) ends the link
    assert client.post("/worker/attendance", headers=h.w, json={"assignment_id": h.asg, "kind": "in", "lat": SITE[0], "lng": SITE[1],
                                                                 "start_code": h.code()}).status_code == 200
    gone = client.get(f"/public/trip/{s['token']}")
    assert gone.status_code == 410 and err(gone) == "err.trip_expired"
    assert client.get(f"/t/{s['token']}").status_code == 410


def test_share_trip_expires_after_six_hours():
    h = Hire(worker=MURUGAN)
    client.post(f"/worker/assignments/{h.asg}/journey", headers=h.w, json={"lat": SITE[0] + 0.02, "lng": SITE[1]})
    tokn = client.post(f"/customer/jobs/{h.jid}/share-trip", headers=h.c).json()["token"]
    assert client.get(f"/public/trip/{tokn}").status_code == 200
    with SessionLocal() as db:
        row = db.scalar(select(TripShare).where(TripShare.token == tokn))
        assert abs((row.expires_at - row.created_at) - timedelta(hours=6)) < timedelta(seconds=5)
        row.expires_at = datetime.now(timezone.utc) - timedelta(minutes=1)
        db.commit()
    assert err(client.get(f"/public/trip/{tokn}")) == "err.trip_expired"


# ================================================================== 3. police verification
def test_police_verification_request_admin_decision_and_badge():
    mohan = tok(new_l0_worker())  # level 0: has not even added a name/UPI yet
    assert err(client.post("/worker/police-verification", headers=mohan)) == "err.kyc_required"
    w = tok("9200000018")  # Bikash: L1, no police request yet
    assert client.get("/worker/profile", headers=w).json()["police"]["status"] == "none"
    assert client.post("/worker/police-verification", headers=w).json() == {"status": "pending"}
    assert client.post("/worker/police-verification", headers=w).json() == {"status": "pending"}  # idempotent
    admin = tok(ADMIN)
    q = client.get("/admin/police-queue", headers=admin).json()
    me = next(x for x in q if x["name"] == "Bikash Nayak")
    assert me["police_status"] == "pending" and me["requested_at"]
    assert client.get("/admin/kpis", headers=admin).json()["police_pending"] >= 1
    assert client.post(f"/admin/workers/{me['id']}/police", headers=tok(PRIYA), json={"approve": True}).status_code == 403
    r = client.post(f"/admin/workers/{me['id']}/police", headers=admin, json={"approve": True})
    assert r.json() == {"status": "verified"}
    assert client.get("/worker/profile", headers=w).json()["police_verified"] is True
    assert all(x["id"] != me["id"] for x in client.get("/admin/police-queue", headers=admin).json())
    assert client.post(f"/admin/workers/{me['id']}/police", headers=admin, json={"approve": True}).status_code == 404  # nothing pending now
    # rejected -> reason shown to the worker, may ask again
    other = tok("9200000020")
    client.post("/worker/police-verification", headers=other)
    oid = client.get("/worker/profile", headers=other).json()["id"]
    assert client.post(f"/admin/workers/{oid}/police", headers=admin, json={"approve": False, "note": "Address mismatch"}).json()["status"] == "rejected"
    p = client.get("/worker/profile", headers=other).json()["police"]
    assert p["status"] == "rejected" and p["note"] == "Address mismatch"
    assert client.post("/worker/police-verification", headers=other).json()["status"] == "pending"


def test_verified_workers_rank_first_at_equal_rating_and_show_the_shield():
    c = tok(PRIYA)
    rows = client.get("/customer/workers?trade=plumber", headers=c).json()
    assert all("police_verified" in r and "level" in r for r in rows)
    keys = [(-round(r["rating"], 1), not r["police_verified"]) for r in rows]
    assert keys == sorted(keys)  # best rating first; verified before unverified at the same rating
    with SessionLocal() as db:  # two plumbers with the same rating, one verified
        a, b = (db.scalar(select(User).where(User.phone == p)).worker_profile for p in (MURUGAN, SHAMSHAD))
        a0, b0 = (a.overall_rating, a.police_status), (b.overall_rating, b.police_status)
        a.overall_rating = b.overall_rating = 4.4
        a.police_status, b.police_status = "none", "verified"
        db.commit()
    try:
        names = [r["name"] for r in client.get("/customer/workers?trade=plumber", headers=c).json() if r["rating"] == 4.4]
        assert names.index("Shamshad Alam") < names.index("Murugan S")
    finally:
        with SessionLocal() as db:
            for p, (rate, st) in ((MURUGAN, a0), (SHAMSHAD, b0)):
                wp = db.scalar(select(User).where(User.phone == p)).worker_profile
                wp.overall_rating, wp.police_status = rate, st
            db.commit()


# ================================================================== 4. warranty + free re-fix
def test_warranty_days_per_trade_on_quotes_and_receipt():
    assert [trust.WARRANTY_DAYS[t] for t in ("plumber", "electrician", "carpenter", "mason", "painter", "helper")] == [30, 30, 15, 15, 7, 0]
    h = Hire(pay=False)
    bid = next(b for b in h.job()["bids"] if b["id"] == h.bid)
    assert bid["warranty_days"] == 30
    h.sql(lambda db, a: None)
    client.post(f"/customer/jobs/{h.jid}/pay", headers=h.c, json={"method": "upi"})
    h.finish()
    pay = next(p for p in client.get("/customer/payments", headers=h.c).json() if p["job_id"] == h.jid)
    assert pay["warranty_days"] == 30 and pay["warranty_until"]
    w = h.a()["warranty"]
    assert w["days"] == 30 and w["active"] and w["can_request"] and w["refixes_used"] == 0


def test_problem_came_back_creates_a_free_refix_for_the_same_worker():
    h = Hire(worker=MURUGAN)
    body = {"reason": "The tap is leaking again", "photos": [photo(h.c, "leak.jpg")]}
    assert err(client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json=body)) == "err.job_not_completed"  # not finished/paid out yet
    h.finish()
    assert err(client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json={"reason": "again", "photos": []})) in ("err.validation", "err.proof_required")
    assert err(client.post(f"/customer/jobs/{h.jid}/refix", headers=tok(NEHA), json=body)) == "err.not_found"
    r = client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json=body)
    assert r.status_code == 200, r.text
    rj, ra = r.json()["job_id"], r.json()["assignment_id"]
    # the worker sees it, flagged, with no money involved
    mine = next(a for a in client.get("/worker/assignments", headers=h.w).json() if a["id"] == ra)
    assert mine["kind"] == "refix" and mine["refix"]["reason"] == "The tap is leaking again" and mine["price_inr"] == 0 and mine["payment"] is None
    assert mine["start_code_state"] == "needed" and mine["job"]["address"] == "B-402 Wakad"
    # one open re-fix per job
    assert err(client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json=body)) == "err.refix_open"
    assert h.a()["warranty"]["open_job_id"] == rj
    # the customer shows the code, the worker checks in with it and finishes with proof; the customer confirms - no rating, no payment
    cj = client.get(f"/customer/jobs/{rj}", headers=h.c).json()
    code = cj["assignment"]["start_code"]["code"]
    assert cj["assignment"]["kind"] == "refix" and cj["assignment"]["payment"] is None
    assert client.post(f"/worker/attendance", headers=h.w, json={"assignment_id": ra, "kind": "in", "lat": SITE[0], "lng": SITE[1], "start_code": code}).status_code == 200
    assert client.post(f"/worker/assignments/{ra}/done", headers=h.w, json={"photos": []}).status_code == 422  # proof required
    assert client.post(f"/worker/assignments/{ra}/done", headers=h.w, json={"photos": [photo(h.w)]}).status_code == 200
    assert client.post(f"/customer/jobs/{rj}/complete", headers=h.c).status_code == 200
    assert err(client.post(f"/customer/jobs/{rj}/rate", headers=h.c, json=STARS)) == "err.validation"
    with SessionLocal() as db:
        assert db.scalar(select(Payment).where(Payment.assignment_id == uuid.UUID(ra))) is None
    # second one is allowed, a third is not (max 2 per job)
    assert client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json=body).status_code == 200
    ra2 = h.a()["warranty"]["open_job_id"]
    client.post(f"/customer/jobs/{ra2}/cancel", headers=h.c)  # cancelling a visit that never happened frees the slot
    assert client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json=body).status_code == 200
    h.sql(lambda db, a: None)
    # finish #2 quickly through the API to hit the cap
    rj2 = h.a()["warranty"]["open_job_id"]
    cj2 = client.get(f"/customer/jobs/{rj2}", headers=h.c).json()
    asg2 = cj2["assignment"]["id"]
    client.post(f"/worker/assignments/{asg2}/start", headers=h.w, json={"code": cj2["assignment"]["start_code"]["code"]})
    client.post(f"/worker/assignments/{asg2}/done", headers=h.w, json={"photos": [photo(h.w)]})
    client.post(f"/customer/jobs/{rj2}/complete", headers=h.c)
    r = client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json=body)
    assert r.status_code == 409 and err(r) == "err.refix_limit"
    # the worker's record
    rec = client.get("/worker/profile", headers=h.w).json()["warranty_record"]
    assert rec["refixes"] >= 3 and rec["jobs"] > 0
    assert client.get(f"/customer/workers/{client.get('/worker/profile', headers=h.w).json()['id']}", headers=h.c).json()["warranty_record"]["refixes"] == rec["refixes"]


def test_refix_after_the_warranty_window_is_refused():
    h = Hire(worker=SHAMSHAD)
    h.finish()
    body = {"reason": "Leaking again", "photos": [photo(h.c)]}
    with SessionLocal() as db:  # 31 days later (plumber: 30 days)
        p = db.scalar(select(Payment).where(Payment.assignment_id == uuid.UUID(h.asg)))
        p.released_at = datetime.now(timezone.utc) - timedelta(days=31)
        db.commit()
    r = client.post(f"/customer/jobs/{h.jid}/refix", headers=h.c, json=body)
    assert r.status_code == 409 and err(r) == "err.warranty_expired"
    w = h.a()["warranty"]
    assert w["active"] is False and w["can_request"] is False and w["reason"] == "expired"
    # helpers carry no warranty at all
    hh = Hire(worker="9200000021", trade="helper", price=700)
    hh.finish()
    assert err(client.post(f"/customer/jobs/{hh.jid}/refix", headers=hh.c, json=body)) == "err.warranty_expired"


# ================================================================== 5. same-day pay
def test_release_sends_the_payout_straight_to_upi_and_settles_in_seconds():
    h = Hire(worker=IMRAN)
    before = client.get("/worker/earnings", headers=h.w).json()
    h.finish()
    e = client.get("/worker/earnings", headers=h.w).json()
    assert e["available_inr"] == before["available_inr"]  # nothing waits in the balance
    mine = next(x for x in e["paid_today"]["items"] if x["amount_inr"] == 1500 and x["locality"])
    assert mine["state"] == "processing" and "*" in mine["upi"] and mine["upi"].endswith("@okaxis")
    n = client.get("/worker/notices", headers=h.w).json()
    note = next(x for x in n if x["amount_inr"] == 1500)
    assert note["kind"] == "payout_sent" and "*" in note["upi"]
    with SessionLocal() as db:  # a few seconds later
        p = db.get(Payout, uuid.UUID(mine["id"]))
        p.created_at = datetime.now(timezone.utc) - timedelta(seconds=30)
        db.commit()
    e2 = client.get("/worker/earnings", headers=h.w).json()
    assert next(x for x in e2["paid_today"]["items"] if x["id"] == mine["id"])["state"] == "paid"
    assert e2["paid_today"]["total_inr"] >= 1500
    assert client.post("/worker/notices/ack", headers=h.w, json={"ids": [x["id"] for x in n]}).status_code == 200
    assert all(x["amount_inr"] != 1500 for x in client.get("/worker/notices", headers=h.w).json())


def test_no_upi_yet_means_the_money_waits_in_the_balance_with_a_nudge():
    h = Hire(worker=new_l0_worker(), trade="carpenter", price=2000)  # level-0 worker: no UPI
    h.finish()
    e = client.get("/worker/earnings", headers=h.w).json()
    assert e["available_inr"] == 2000 and e["nudge_add_upi"] is True and not e["paid_today"]["items"]
    assert err(client.post("/worker/withdraw", headers=h.w)) == "err.upi_required"
    # adds UPI later -> the leftover balance is withdrawn by hand (manual withdraw still works)
    assert client.post("/worker/kyc/level1", headers=h.w, json={"name": "Mohan Jadhav", "upi_id": "mohan@okaxis"}).status_code == 200
    assert client.post("/worker/withdraw", headers=h.w).json()["amount_inr"] == 2000


# ================================================================== 6. skill ladder + streak
def test_level_rules_and_progress():
    assert levels.level_for(0, 0, 0)["code"] == "helper"
    assert levels.level_for(4, 5.0, 0)["code"] == "helper"
    assert levels.level_for(5, 4.0, 0)["code"] == "semi_skilled"
    assert levels.level_for(5, 3.9, 0)["code"] == "helper"
    assert levels.level_for(20, 4.3, 0)["code"] == "skilled"
    assert levels.level_for(20, 4.29, 0)["code"] == "semi_skilled"
    assert levels.level_for(60, 4.6, 2)["code"] == "master"       # 3.3% re-fix rate
    assert levels.level_for(60, 4.6, 3)["code"] == "skilled"      # 5% is not < 5%
    assert levels.level_for(60, 4.59, 0)["code"] == "skilled"
    assert [levels.fair_multiplier(c) for c in ("helper", "semi_skilled", "skilled", "master")] == [1.0, 1.0, 1.1, 1.25]
    with SessionLocal() as db:
        wp = db.scalar(select(User).where(User.phone == "9200000010")).worker_profile  # 8 jobs, 4.0
        v = levels.level_view(wp)
        assert v["code"] == "semi_skilled" and v["next"]["code"] == "skilled" and 0 < v["progress"] < 1
        assert {"kind": "jobs", "need": 12} in v["needs"] and {"kind": "rating", "need": 4.3} in v["needs"]


def test_profile_level_card_and_weekly_streak():
    w = tok(MURUGAN)
    p = client.get("/worker/profile", headers=w).json()
    assert p["level_card"]["code"] == p["level"] == "skilled" and p["level_card"]["next"]["code"] == "master"
    assert "weeks" in p["streak"] and "alive_this_week" in p["streak"]
    today = date(2026, 11, 26)  # Thursday, ISO week 48
    wk = lambda d: levels._week(d)  # noqa: E731
    weeks = {wk(today), wk(today - timedelta(days=7)), wk(today - timedelta(days=14)), wk(today - timedelta(days=21))}
    assert levels.streak_from_weeks(weeks, today) == {"weeks": 4, "alive_this_week": True}
    assert levels.streak_from_weeks(weeks - {wk(today)}, today) == {"weeks": 3, "alive_this_week": False}  # this week not over yet
    assert levels.streak_from_weeks({wk(today), wk(today - timedelta(days=14))}, today)["weeks"] == 1  # a missed week breaks it
    assert levels.streak_from_weeks(set(), today) == {"weeks": 0, "alive_this_week": False}
    # a real completed job makes this week count
    h = Hire(worker=SHAMSHAD)
    h.finish()
    s = client.get("/worker/profile", headers=h.w).json()["streak"]
    assert s["alive_this_week"] is True and s["weeks"] >= 1


def test_level_scales_the_fair_band_but_never_the_minimum_wage():
    job = type("J", (), {"city": "Pune", "work_items": [type("W", (), {"trade": "mason", "text_description": "Compound wall 40 ft, 5 ft high", "transcript": None})()]})()
    base = pricing.fair_range(job)
    for code in ("skilled", "master"):
        m = levels.fair_multiplier(code)
        sc = pricing.scale_range(base, m)
        assert sc["min_wage_total"] == base["min_wage_total"]  # the legal floor never moves
        assert sc["low"] >= base["min_wage_total"] and sc["low"] < sc["median"] < sc["high"]
        assert sc["high"] > base["high"] and sc["median"] >= base["median"] * m * 0.97
    assert pricing.scale_range(base, 1.0) == base
    # "Higher than usual" threshold moves with the level: a price that is high for a helper is fair for a master
    price = base["high"] * 1.3
    assert pricing.fair_check(price, job)["verdict"] == "high"
    assert pricing.fair_check(price, job, None, 1.25)["verdict"] == "fair"
    assert pricing.fair_check(base["min_wage_total"] - 1, job, None, 1.25)["verdict"] == "below_min_wage"
    # and the worker's own job screen shows the scaled band
    h = Hire(worker="9200000005", trade="electrician", pay=False)  # Venkat: 42 jobs, 4.8
    d = client.get(f"/worker/jobs/{h.jid}", headers=h.w).json()
    assert d["level"] == "skilled" and d["level_multiplier"] == 1.1


# ================================================================== 10. hire again
def test_direct_request_is_exclusive_for_two_hours_then_opens_to_everyone():
    ramesh = tok(RAMESH)
    rid = client.get("/worker/profile", headers=ramesh).json()["id"]
    c = tok(PRIYA)
    body = {"location_lat": SITE[0], "location_lng": SITE[1], "address_text": "Flat 302, Kothrud", "start_date": str(today_ist() + timedelta(days=1)),
            "direct_worker_id": rid, "work_items": [{"trade": "mason", "text_description": LONG, "description_language": "en",
                                                     "photo_keys": [photo(c), photo(c)]}]}
    assert err(client.post("/customer/jobs", headers=c, json={**body, "direct_worker_id": client.get("/worker/profile", headers=tok(MURUGAN)).json()["id"]})) == "err.trade_mismatch"
    r = client.post("/customer/jobs", headers=c, json=body)
    jid = r.json()["id"]
    until = datetime.fromisoformat(r.json()["direct_until"])
    assert timedelta(minutes=118) < until - datetime.now(timezone.utc) <= timedelta(hours=2)
    # nobody else can see or quote it; Ramesh gets it first in his feed with the Direct badge
    other = tok("9200000011")  # another mason
    assert jid not in [x["id"] for x in client.get("/worker/feed", headers=other).json()]
    assert err(client.get(f"/worker/jobs/{jid}", headers=other)) == "err.direct_only"
    assert err(client.post("/worker/bids", headers=other, json={"job_id": jid, "price_inr": 1500})) == "err.direct_only"
    feed = client.get("/worker/feed", headers=ramesh).json()
    assert feed[0]["id"] == jid and feed[0]["direct"]["customer_name"] == "Priya Sharma"
    seeded = next(x for x in feed if x["direct"] and x["id"] != jid)  # the seeded "hire again" request
    assert seeded["direct"]["until"]
    det = client.get(f"/worker/jobs/{jid}", headers=ramesh).json()
    assert det["direct"]["state"] == "pending"
    jd = client.get(f"/customer/jobs/{jid}", headers=c).json()
    assert jd["direct"]["state"] == "pending" and jd["direct"]["worker"]["name"] == "Ramesh Pawar" and jd["direct"]["quoted"] is False
    # decline -> opens to all
    assert err(client.post(f"/worker/jobs/{jid}/decline", headers=other)) == "err.forbidden"
    assert client.post(f"/worker/jobs/{jid}/decline", headers=ramesh).json() == {"state": "declined"}
    assert jid in [x["id"] for x in client.get("/worker/feed", headers=other).json()]
    assert client.post("/worker/bids", headers=other, json={"job_id": jid, "price_inr": 1500}).status_code == 200
    assert client.get(f"/customer/jobs/{jid}", headers=c).json()["direct"]["state"] == "declined"
    # timeout path
    j2 = client.post("/customer/jobs", headers=c, json=body).json()["id"]
    assert j2 not in [x["id"] for x in client.get("/worker/feed", headers=other).json()]
    with SessionLocal() as db:
        db.get(Job, uuid.UUID(j2)).direct_until = datetime.now(timezone.utc) - timedelta(seconds=1)
        db.commit()
    assert j2 in [x["id"] for x in client.get("/worker/feed", headers=other).json()]
    assert client.get(f"/customer/jobs/{j2}", headers=c).json()["direct"]["state"] == "expired"
    # the target can quote during the window and the customer hires him
    j3 = client.post("/customer/jobs", headers=c, json=body).json()["id"]
    assert client.post("/worker/bids", headers=ramesh, json={"job_id": j3, "price_inr": 1800}).status_code == 200
    assert client.get(f"/customer/jobs/{j3}", headers=c).json()["direct"]["quoted"] is True


def test_favourites_and_rebook_prefill():
    c = tok(PRIYA)
    fav = client.get("/customer/favourites", headers=c).json()
    assert fav and all(f["rating"] >= 0 for f in fav)
    imran = next(f for f in fav if f["name"] == "Imran Shaikh")  # rated 4.75 in the seed
    assert imran["jobs_together"] >= 1 and imran["last_job_id"]
    # nobody Priya rated below 4 appears; unrated/other customers' workers do not appear
    assert client.get("/customer/favourites", headers=tok(ADMIN)).status_code == 403
    d = client.get(f"/customer/jobs/{imran['last_job_id']}/rebook", headers=c).json()
    assert d["worker"]["name"] == "Imran Shaikh" and d["address_text"] and d["items"][0]["trade"] == "plumber"
    assert d["items"][0]["text_description"] and d["lat"]
    d2 = client.get(f"/customer/workers/{imran['id']}/rebook", headers=c).json()
    assert d2["items"][0]["trade"] == "plumber" and d2["address_text"]
    assert err(client.get(f"/customer/jobs/{imran['last_job_id']}/rebook", headers=tok(NEHA))) == "err.not_found"
    jobs = client.get("/customer/jobs", headers=c).json()
    done = next(j for j in jobs if j["id"] == imran["last_job_id"])
    assert done["hire_again_worker_id"] == imran["id"] and done["warranty"]["active"]
