"""Post-job rules, scheduling, fair-range spread, sample people and contractor team hiring (HTTP level)."""
import random
from datetime import date, datetime, timedelta, timezone

import pytest
from fastapi.testclient import TestClient

from app.domain import pricing
from sqlalchemy import select

from app.db import SessionLocal
from app.main import app
from app.models import User
from app.security import _hits, issue_token

client = TestClient(app)
IST = timezone(timedelta(hours=5, minutes=30))
PHOTOS = ["https://picsum.photos/seed/t1/800/600", "https://picsum.photos/seed/t2/800/600"]
DESC = "Boundary wall needs building and plastering, material is already on the site and water is available."


@pytest.fixture(autouse=True)
def _clear():
    _hits.clear()


_TOKENS: dict[str, dict] = {}


def tok(phone: str) -> dict:
    """Token straight from the seeded user (OTP requests are rate limited to 5/hour/phone and other test files use them)."""
    if phone not in _TOKENS:
        with SessionLocal() as db:
            user = db.scalar(select(User).where(User.phone == phone))
            _TOKENS[phone] = {"Authorization": f"Bearer {issue_token(user)}"}
    return dict(_TOKENS[phone])


def item(trade="mason", **kw):
    return {"trade": trade, "text_description": DESC, "description_language": "en", "photo_keys": PHOTOS, **kw}


def body(items, **kw):
    return {"location_lat": 18.5089, "location_lng": 73.9260, "address_text": "Plot 9, Hadapsar", "city": "Pune",
            "start_date": str(date.today() + timedelta(days=1)), "work_items": items, **kw}


# ------------------------------------------------------------------ pricing spread
def test_range_always_spread_even_for_tiny_jobs():
    rnd = random.Random(1)
    for trade in ("mason", "plumber", "electrician", "carpenter", "painter", "helper"):
        for city in ("Pune", "Jalandhar", "Some Village", None):
            for text in (None, "tap leak", "1 point", "2 days", "wall 20 ft", "paint 100 sq ft", "x" * rnd.randint(1, 20)):
                e = pricing.estimate_item(trade, text, city)
                assert e["low_inr"] < e["median_inr"] < e["high_inr"], (trade, city, text, e)
                assert e["median_inr"] >= e["low_inr"] * 1.12 - 50 and e["high_inr"] >= e["low_inr"] * 1.3 - 50
                assert e["low_inr"] >= e["min_wage_total"]


def test_spread_function_guarantees_order_and_rounding():
    for lo, md, hi in [(400, 400, 400), (400, 380, 390), (1000, 1000, 1000), (50, 50, 50), (12345, 12000, 12100)]:
        a, b, c = pricing.spread(lo, md, hi)
        assert a < b < c
        assert c >= a * 1.3 - 1 and b >= a * 1.12 - 1
        step = 50 if a >= 500 else 10
        assert a % step == b % step == c % step == 0


def test_day_wage_range_never_below_minimum_wage():
    for trade in ("mason", "helper", "painter", "electrician"):
        r = pricing.day_wage_range(trade, "Jalandhar")
        assert r["min_wage"] <= r["low"] < r["median"] < r["high"]


def test_price_estimate_and_wage_suggestion_endpoints():
    h = tok("9100000002")
    est = client.get("/customer/price-estimate?trades=plumber,helper&texts=tap leak|1 day&city=Pune", headers=h).json()
    assert est["total_low_inr"] < est["total_median_inr"] < est["total_high_inr"]
    for it in est["items"]:
        assert it["low_inr"] < it["high_inr"]
    w = client.get("/customer/wage-suggestion?trades=mason,helper&city=Pune", headers=h).json()
    assert [i["trade"] for i in w["items"]] == ["mason", "helper"]
    assert all(i["low"] >= i["min_wage"] for i in w["items"])


# ------------------------------------------------------------------ sample people
def test_every_trade_has_two_workers_and_an_open_job():
    admin = tok("9000000001")
    workers = client.get("/admin/workers", headers=admin).json()
    for trade in ("mason", "plumber", "electrician", "carpenter", "painter", "helper"):
        assert sum(trade in w["trades"] for w in workers) >= 2, trade
    for phone, trade in [("9200000001", "mason"), ("9200000003", "plumber"), ("9200000005", "electrician"),
                         ("9200000007", "carpenter"), ("9200000009", "painter"), ("9200000021", "helper")]:
        feed = client.get("/worker/feed", headers=tok(phone)).json()
        assert any(trade in [t["code"] for t in j["trades"]] for j in feed), trade


# ------------------------------------------------------------------ post-job rules
def test_two_photos_and_fifty_characters_are_enforced():
    h = tok("9100000001")
    r = client.post("/customer/jobs", headers=h, json=body([item(photo_keys=PHOTOS[:1])]))
    assert r.status_code == 422 and r.json()["error"]["code"] == "err.photos_required"
    r = client.post("/customer/jobs", headers=h, json=body([item(text_description="short leak")]))
    assert r.status_code == 422 and r.json()["error"]["code"] == "err.description_short"
    r = client.post("/customer/jobs", headers=h, json=body([item(text_description="  " + "a" * 49 + "   ")]))
    assert r.json()["error"]["code"] == "err.description_short"  # trimmed length counts
    r = client.post("/customer/jobs", headers=h, json=body([item(text_description="a" * 50)]))
    assert r.status_code == 200, r.text
    hi = client.post("/customer/jobs", headers={**h, "Accept-Language": "hi"}, json=body([item(photo_keys=[])])).json()["error"]
    assert "2" in hi["message"] and hi["message"] != "Add at least 2 photos of the work."


def test_schedule_stored_validated_and_shown():
    h = tok("9100000001")
    past = (datetime.now(timezone.utc) - timedelta(hours=3)).isoformat()
    r = client.post("/customer/jobs", headers=h, json=body([item()], scheduled_for=past, time_slot="exact"))
    assert r.json()["error"]["code"] == "err.schedule_past"
    r = client.post("/customer/jobs", headers=h, json=body([item()], start_date=str(date.today() - timedelta(days=1))))
    assert r.json()["error"]["code"] == "err.date_in_past"
    tomorrow9 = datetime.combine(date.today() + timedelta(days=1), datetime.min.time()).replace(hour=9, minute=30, tzinfo=IST)
    r = client.post("/customer/jobs", headers=h, json=body([item()], scheduled_for=tomorrow9.isoformat(), time_slot="exact"))
    assert r.status_code == 200, r.text
    d = client.get(f"/customer/jobs/{r.json()['id']}", headers=h).json()
    assert d["time_slot"] == "exact" and datetime.fromisoformat(d["scheduled_for"]) == tomorrow9 and d["kind"] == "single"
    feed = client.get("/worker/feed", headers=tok("9200000001")).json()
    mine = next(j for j in feed if j["id"] == r.json()["id"])
    assert mine["scheduled_for"] and mine["time_slot"] == "exact"
    # a slot that ended earlier today is refused, a future slot is accepted
    early = datetime.combine(datetime.now(IST).date(), datetime.min.time()).replace(hour=8, tzinfo=IST)
    r = client.post("/customer/jobs", headers=h, json=body([item()], start_date=str(early.date()),
                                                           scheduled_for=early.isoformat(), time_slot="morning"))
    if datetime.now(IST).hour >= 11:
        assert r.json()["error"]["code"] == "err.schedule_past"
    r = client.post("/customer/jobs", headers=h, json=body([item()], scheduled_for=tomorrow9.replace(hour=12).isoformat(), time_slot="afternoon"))
    assert r.status_code == 200


# ------------------------------------------------------------------ contractor team hiring
def team_body(**kw):
    return body([item("mason", headcount=2, days=2, daily_wage_inr=1000), item("helper", headcount=1, days=2, daily_wage_inr=850)], kind="team", **kw)


def test_only_contractors_post_team_jobs_and_wage_floor_blocks():
    assert client.post("/customer/jobs", headers=tok("9100000001"), json=team_body()).json()["error"]["code"] == "err.contractor_only"
    c = tok("9100000002")
    low = body([item("mason", headcount=2, days=2, daily_wage_inr=500)], kind="team")
    r = client.post("/customer/jobs", headers=c, json=low)
    assert r.status_code == 422 and r.json()["error"]["code"] == "err.wage_below_minimum"
    assert "954" in r.json()["error"]["message"]
    dup = body([item("mason", headcount=1, days=1, daily_wage_inr=1000)] * 2, kind="team")
    assert client.post("/customer/jobs", headers=c, json=dup).status_code == 422
    me = client.get("/me", headers=c).json()
    assert me["customer_type"] == "contractor" and me["org_name"]


def test_team_lifecycle_join_accept_pay_attend_settle_refund():
    c = tok("9100000002")
    jid = client.post("/customer/jobs", headers=c, json=team_body()).json()["id"]
    w1, w2, w3, h1 = tok("9200000001"), tok("9200000011"), tok("9200000012"), tok("9200000021")

    # workers see it in the feed with the team facts, and the detail has a DAILY-wage fair range
    feed = client.get("/worker/feed", headers=w1).json()
    f = next(j for j in feed if j["id"] == jid)
    assert f["kind"] == "team" and {i["trade"]: i["headcount"] for i in f["team"]["items"]} == {"mason": 2, "helper": 1}
    det = client.get(f"/worker/jobs/{jid}", headers=w1).json()
    assert det["my_item"]["daily_wage_inr"] == 1000 and det["fair_range"]["low"] < det["fair_range"]["high"]
    # join at the offered wage (w1), quote own rate (w2, w3), helper applies (h1)
    for h, price in ((w1, 1000), (w2, 1050), (w3, 1000), (h1, 850)):
        assert client.post("/worker/bids", headers=h, json={"job_id": jid, "price_inr": price}).status_code == 200
    assert client.post("/worker/bids", headers=tok("9200000003"), json={"job_id": jid, "price_inr": 900}).json()["error"]["code"] == "err.trade_mismatch"

    d = client.get(f"/customer/jobs/{jid}", headers=c).json()
    assert d["team"]["summary"]["headcount"] == 3 and d["team"]["summary"]["filled"] == 0
    bids = {b["worker"]["name"]: b for b in d["bids"]}
    assert all(b["trade"] and b["daily_wage_inr"] and b["days"] == 2 for b in d["bids"])
    ids = {n: b["id"] for n, b in bids.items()}
    names = list(ids)
    mason_bids = [b for b in d["bids"] if b["trade"] == "mason"]
    helper_bid = next(b for b in d["bids"] if b["trade"] == "helper")

    # accept 2 of 3 masons (headcount 2) -> third is refused as full; the rest stay pending
    for b in mason_bids[:2]:
        r = client.post(f"/customer/jobs/{jid}/bids/{b['id']}/accept", headers=c)
        assert r.status_code == 200, r.text
    r = client.post(f"/customer/jobs/{jid}/bids/{mason_bids[2]['id']}/accept", headers=c)
    assert r.status_code == 409 and r.json()["error"]["code"] == "err.team_full"  # that trade line is full
    assert client.post(f"/customer/jobs/{jid}/bids/{helper_bid['id']}/accept", headers=c).status_code == 200

    ros = client.get(f"/customer/jobs/{jid}/team", headers=c).json()
    assert ros["summary"]["filled"] == 3 and len(ros["workers"]) == 3 and ros["payment_due_count"] == 3
    assert ros["payment_due_inr"] == sum(w["total_inr"] for w in ros["workers"]) + 3 * 30
    # worker cannot check in before the team is paid
    asg = client.get("/worker/assignments", headers=w1).json()
    a1 = next(a for a in asg if a["job"]["id"] == jid)
    assert a1["team_member"] and a1["daily_wage_inr"] == 1000 and a1["price_inr"] == 2000
    att = {"assignment_id": a1["id"], "kind": "in", "lat": 18.5089, "lng": 73.9260}
    assert client.post("/worker/attendance", headers=w1, json=att).json()["error"]["code"] == "err.payment_pending"

    # ONE checkout pays the whole team
    pay = client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi"}).json()
    assert pay["count"] == 3 and pay["paid_inr"] == ros["payment_due_inr"]
    assert pay["amount_inr"] == pay["paid_inr"] and pay["ref"] and pay["escrow_state"] == "held"  # same keys as a single payment
    assert client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi"}).json()["count"] == 0  # idempotent
    assert client.get(f"/customer/jobs/{jid}/team", headers=c).json()["payment_due_count"] == 0

    # attendance: w1 works 1 of 2 days; nobody else turns up (the contractor reads today's code off the roster)
    ros = client.get(f"/customer/jobs/{jid}/team", headers=c).json()
    code = next(w for w in ros["workers"] if w["assignment_id"] == a1["id"])["start_code"]["code"]
    att["start_code"] = code
    assert client.post("/worker/attendance", headers=w1, json=att).status_code == 200
    ros = client.get(f"/customer/jobs/{jid}/team", headers=c).json()
    r1 = next(w for w in ros["workers"] if w["assignment_id"] == a1["id"])
    assert r1["present_today"] and r1["days_worked"] == 1 and r1["amount_due_inr"] == 1000
    assert ros["summary"]["present_today"] == 1
    assert client.get(f"/customer/jobs/{jid}", headers=c).json()["status"] == "in_progress"

    stars = {"quality": 5, "timeliness": 4, "behaviour": 5, "value_for_money": 4}
    # worked 1 of 2 days -> paid 1000, 1000 refunded
    out = client.post(f"/customer/jobs/{jid}/team/{a1['id']}/settle", headers=c, json=stars).json()
    assert out["days_worked"] == 1 and out["payout_inr"] == 1000 and out["refund_inr"] == 1000
    assert client.post(f"/customer/jobs/{jid}/team/{a1['id']}/settle", headers=c, json=stars).status_code == 409
    bal = client.get("/worker/earnings", headers=w1).json()
    assert bal["total_earned_inr"] >= 1000
    # no-shows are fully refunded; the job completes when everyone is settled
    for w in ros["workers"]:
        if w["assignment_id"] != a1["id"]:
            o = client.post(f"/customer/jobs/{jid}/team/{w['assignment_id']}/settle", headers=c, json=stars).json()
            assert o["days_worked"] == 0 and o["payout_inr"] == 0 and o["refund_inr"] == w["total_inr"] + 30
    assert client.get(f"/customer/jobs/{jid}", headers=c).json()["status"] == "completed"
    # rating is mandatory: out-of-range stars are rejected
    assert client.post(f"/customer/jobs/{jid}/complete", headers=c).json()["error"]["code"] == "err.team_use_roster"


def test_single_jobs_unchanged_and_team_job_in_contractor_list():
    c = tok("9100000002")
    jobs = client.get("/customer/jobs", headers=c).json()
    site = next(j for j in jobs if j["kind"] == "team" and j["status"] == "in_progress")
    assert site["team"]["filled"] == 3 and site["team"]["headcount"] == 6 and site["team"]["present_today"] >= 1
    ros = client.get(f"/customer/jobs/{site['id']}/team", headers=c).json()
    assert any(w["present_today"] for w in ros["workers"]) and all(w["days_worked"] >= 1 for w in ros["workers"])
    assert next(j for j in jobs if j["kind"] == "single")["team"] is None


def test_site_can_grow_while_running():
    """The seeded running site (2 of 3 masons hired, 1 applicant waiting) can take another mason mid-way."""
    c = tok("9100000002")
    site = next(j for j in client.get("/customer/jobs", headers=c).json() if j["kind"] == "team" and j["status"] == "in_progress")
    d = client.get(f"/customer/jobs/{site['id']}", headers=c).json()
    pend = next(b for b in d["bids"] if b["status"] == "pending" and b["trade"] == "mason")
    assert client.post(f"/customer/jobs/{site['id']}/bids/{pend['id']}/accept", headers=c).status_code == 200
    ros = client.get(f"/customer/jobs/{site['id']}/team", headers=c).json()
    assert ros["summary"]["filled"] == 4 and ros["payment_due_count"] == 1
    # the third mason line is now full: nobody else can join it, but the helper line still takes applicants
    feed = client.get("/worker/feed", headers=tok("9200000012")).json()
    assert all(j["id"] != site["id"] or j["team"]["items"][0]["filled"] == 3 for j in feed)
