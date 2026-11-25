"""End-to-end lifecycle through the HTTP API (Phases 2–5). Requires the seed (see test_phase1)."""
import uuid
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.security import _hits

client = TestClient(app)


@pytest.fixture(autouse=True)
def _clear():
    _hits.clear()


def tok(phone: str) -> dict:
    client.post("/auth/otp/request", json={"phone": phone})
    r = client.post("/auth/otp/verify", json={"phone": phone, "code": "123456"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}


def upload(h, kind, name, data):
    r = client.post("/media/upload", headers=h, data={"kind": kind}, files={"file": (name, data)})
    assert r.status_code == 200, r.text
    return r.json()["key"]


def test_full_lifecycle_with_mandatory_rating():
    cust, plumber, plumber2 = tok("9100000003"), tok("9200000003"), tok("9200000004")

    # C2: post a job with photo + voice note + text, transcript reviewed by the customer
    photo = upload(cust, "photo", "leak.jpg", b"\xff\xd8fakejpeg")
    audio = upload(cust, "audio", "note.m4a", b"\x00" * 60_000)
    tr = client.post("/media/transcribe", headers=cust, json={"key": audio, "lang": "en"})
    assert tr.status_code == 200 and tr.json()["transcript"]
    est = client.get("/customer/price-estimate?trades=plumber&locality=Wakad", headers=cust).json()
    assert est["items"][0]["low_inr"] <= est["items"][0]["high_inr"]
    job = client.post("/customer/jobs", headers=cust, json={
        "location_lat": 18.5986, "location_lng": 73.7604, "address_text": "B-402 Wakad", "start_date": str(date.today() + timedelta(days=1)),
        "work_items": [{"trade": "plumber", "text_description": "Kitchen sink leaks under the basin and the water pipe joint is dripping all day.", "transcript": "edited transcript",
                        "description_language": "en", "audio_key": audio, "audio_duration_sec": 24,
                        "audio_size_bytes": 60_000, "photo_keys": [photo, photo]}]}).json()
    jid = job["id"]

    # S4/S5: worker sees it, detail is translated into Hindi (worker's language) with signed audio
    feed = client.get("/worker/feed", headers=plumber).json()
    assert any(j["id"] == jid for j in feed)
    d = client.get(f"/worker/jobs/{jid}", headers=plumber).json()
    wi = d["work_items"][0]
    assert wi["translated"] and wi["text"].startswith("[हिन्दी]") and wi["audio"]["url"]
    assert client.get(wi["audio"]["url"].replace("http://localhost:8000", "")).status_code == 200

    # offline-queued bid replayed twice → one bid
    ref = uuid.uuid4().hex
    b1 = client.post("/worker/bids", headers=plumber, json={"job_id": jid, "price_inr": 1500, "client_ref": ref}).json()
    b2 = client.post("/worker/bids", headers=plumber, json={"job_id": jid, "price_inr": 1500, "client_ref": ref}).json()
    assert b1["id"] == b2["id"]
    client.post("/worker/bids", headers=plumber2, json={"job_id": jid, "price_inr": 1700})
    det = client.get(f"/customer/jobs/{jid}", headers=cust).json()
    assert det["status"] == "bidding" and len(det["bids"]) == 2

    # C3: accept → escrow HELD for quote + ₹30
    acc = client.post(f"/customer/jobs/{jid}/bids/{b1['id']}/accept", headers=cust).json()
    assert acc["payment"]["escrow_state"] == "created" and acc["payment"]["amount_inr"] == 1530
    asg = acc["assignment_id"]
    # nobody starts before the money is in escrow
    r = client.post(f"/worker/assignments/{asg}/journey", headers=plumber, json={})
    assert r.status_code == 409 and r.json()["error"]["code"] == "err.payment_pending"
    paid = client.post(f"/customer/jobs/{jid}/pay", headers=cust, json={"method": "upi"}).json()
    assert paid["escrow_state"] == "held" and paid["method"] == "upi" and paid["paid_at"]
    assert client.post(f"/customer/jobs/{jid}/pay", headers=cust, json={"method": "upi"}).json()["escrow_state"] == "held"  # idempotent
    # live tracking: worker ~3 km away → ETA ~9 min at 20 km/h; customer sees it
    client.post(f"/worker/assignments/{asg}/journey", headers=plumber, json={"lat": 18.6250, "lng": 73.7604})
    tr = client.get(f"/customer/jobs/{jid}", headers=cust).json()["assignment"]["tracking"]
    assert 2.5 < tr["distance_km"] < 3.5 and 7 <= tr["eta_min"] <= 11 and not tr["arrived"]
    client.post(f"/worker/assignments/{asg}/location", headers=plumber, json={"lat": 18.5987, "lng": 73.7605})
    tr = client.get(f"/customer/jobs/{jid}", headers=cust).json()["assignment"]["tracking"]
    assert tr["arrived"] and tr["eta_min"] == 0
    mine = client.get("/worker/bids", headers=tok("9200000004")).json()
    loser = next(b for b in mine if b["job"]["id"] == jid)
    assert loser["status"] == "rejected" and loser["message"]

    # MANDATORY RATING: release without a rating is refused at the API
    r = client.post(f"/customer/jobs/{jid}/release", headers=cust)
    assert r.status_code == 409 and r.json()["error"]["code"] == "err.rating_required"
    # cannot rate before work is done
    stars = {"quality": 5, "timeliness": 4, "behaviour": 5, "value_for_money": 4, "comment": "great"}
    assert client.post(f"/customer/jobs/{jid}/rate", headers=cust, json=stars).status_code == 409

    # S9 attendance: offline check-in replayed twice → one row; geofence respected
    ref2 = uuid.uuid4().hex
    code = client.get(f"/customer/jobs/{jid}", headers=cust).json()["assignment"]["start_code"]["code"]
    for _ in range(2):
        a = client.post("/worker/attendance", headers=plumber, json={"assignment_id": asg, "kind": "in", "lat": 18.5987, "start_code": code,
                                                                    "lng": 73.7605, "client_ref": ref2, "offline": True})
        assert a.status_code == 200 and a.json()["geofence_ok"]
    far = client.post("/worker/attendance", headers=plumber, json={"assignment_id": asg, "kind": "out", "lat": 18.40, "lng": 73.70})
    assert far.json()["geofence_ok"] is False  # recorded, but flagged
    assert client.post(f"/worker/assignments/{asg}/done", headers=plumber).status_code == 422  # proof photo is required
    proof = upload(plumber, "photo", "after.jpg", b"\xff\xd8afterjpeg")
    assert client.post(f"/worker/assignments/{asg}/done", headers=plumber, json={"photos": [proof]}).status_code == 200
    assert client.get(f"/customer/jobs/{jid}", headers=cust).json()["assignment"]["worker_done_at"]

    assert client.post(f"/customer/jobs/{jid}/complete", headers=cust).status_code == 200
    before = client.get("/worker/earnings", headers=plumber).json()["available_inr"]
    rated = client.post(f"/customer/jobs/{jid}/rate", headers=cust, json=stars).json()
    assert rated["overall"] == 4.5 and rated["payment"]["escrow_state"] == "released"
    assert client.post(f"/customer/jobs/{jid}/rate", headers=cust, json=stars).status_code == 409  # once only

    earn = client.get("/worker/earnings", headers=plumber).json()
    assert earn["available_inr"] == before  # same-day pay: the 1500 went straight to UPI (see test_trust)
    assert any(x["amount_inr"] == 1500 and x["source"] == "auto" for x in earn["paid_today"]["items"])
    w = client.post("/worker/withdraw", headers=plumber).json()  # the leftover balance can still be withdrawn by hand
    assert w["amount_inr"] == before and "*" in w["upi"]
    assert client.post("/worker/withdraw", headers=plumber).status_code == 409  # nothing left

    # two-way: worker rates customer
    assert client.post(f"/worker/assignments/{asg}/rate-customer", headers=plumber,
                       json={"clarity": 5, "timely_payment": 5}).status_code == 200


def test_dispute_split_and_penalty_by_admin():
    admin = tok("9000000001")
    ds = client.get("/admin/disputes", headers=admin).json()
    open_d = next(d for d in ds if d["status"] == "open")
    ev = client.get(f"/admin/disputes/{open_d['id']}", headers=admin).json()
    audio_items = [wi for wi in ev["job"]["work_items"] if wi["audio"]]
    assert audio_items and audio_items[0]["transcript"] and ev["chat"] and ev["assignment"]["payment"]["escrow_state"] == "held"
    r = client.post(f"/admin/disputes/{open_d['id']}/resolve", headers=admin,
                    json={"worker_share_pct": 50, "penalise": True, "note": "partial leak fix"}).json()
    assert r["status"] == "resolved"
    ledger = client.get("/admin/payments", headers=admin).json()
    assert any(p["escrow_state"] == "split" for p in ledger)


def test_admin_tools():
    admin = tok("9000000001")
    assert client.get("/admin/kyc-queue", headers=admin).json()
    workers = client.get("/admin/workers?trade=mason", headers=admin).json()
    assert workers and all("mason" in w["trades"] for w in workers)
    wid = workers[0]["id"]
    assert client.post(f"/admin/workers/{wid}/suspend", headers=admin, json={"suspend": True}).json()["suspended"]
    client.post(f"/admin/workers/{wid}/suspend", headers=admin, json={"suspend": False})
    csv = client.get("/admin/compliance.csv", headers=admin)
    assert csv.status_code == 200 and "eshram_registered" in csv.text
    m = client.get("/admin/map", headers=admin).json()
    assert m["pins"] and m["by_locality"]
    job = next(j for j in client.get("/admin/jobs?status=open", headers=admin).json() if not j["direct"])  # not the exclusive "hire again" offer
    detail = client.get(f"/admin/jobs/{job['id']}", headers=admin).json()
    item = next(wi for wi in detail["work_items"] if wi["audio"])
    mod = client.post(f"/admin/work-items/{item['id']}/audio", headers=admin, json={"muted": True}).json()
    assert mod["muted"]
    # muted audio disappears from the worker side but is retained for admin
    feed = client.get("/worker/feed", headers=tok("9200000003")).json()
    j = next(x for x in feed if x["id"] == job["id"])
    assert j["audio"] is None
    client.post(f"/admin/work-items/{item['id']}/audio", headers=admin, json={"muted": False})


def test_worker_profile_and_labour_card():
    h = tok("9200000001")
    p = client.get("/worker/profile", headers=h).json()
    assert p["breakdown"]["quality"] > 0 and p["history"] and p["badges"]
    card = client.get("/worker/labour-card", headers=h).json()
    assert card["card_id"].startswith("BC-") and "phone" not in card and "upi" not in card


def test_progressive_kyc_and_voice():
    new = tok("9200000008")  # KYC L0
    e = client.get("/worker/earnings", headers=new).json()
    assert e["kyc"]["needs_level1"]
    assert client.post("/worker/withdraw", headers=new).json()["error"]["code"] == "err.upi_required"
    assert client.post("/worker/kyc/level1", headers=new, json={"name": "Mohan Jadhav", "upi_id": "mohan8@okicici"}).json()["kyc_level"] == 1
    near_cap = client.get("/worker/earnings", headers=tok("9200000007")).json()
    assert near_cap["kyc"]["nudge_level2"]
    ans = client.post("/voice/query", headers=tok("9200000002"), json={"text": "mera paisa kab aayega?"}).json()
    assert "UPI" in ans["answer"] and "ग्राहक" in ans["answer"]  # answered in Hindi


def test_upload_limits_and_audio_policy():
    cust = tok("9100000001")
    big = client.post("/media/upload", headers=cust, data={"kind": "audio"}, files={"file": ("x.m4a", b"0" * 1_600_000)})
    assert big.status_code == 413
    bad = client.post("/media/upload", headers=cust, data={"kind": "photo"}, files={"file": ("x.exe", b"MZ")})
    assert bad.status_code == 422
    other = tok("9100000002")
    key = upload(cust, "audio", "a.m4a", b"0" * 100)
    assert client.post("/media/transcribe", headers=other, json={"key": key, "lang": "hi"}).status_code == 403
    long = client.post("/customer/jobs", headers=cust, json={
        "location_lat": 18.5, "location_lng": 73.8, "address_text": "Kothrud", "start_date": str(date.today()),
        "work_items": [{"trade": "mason", "audio_key": key, "audio_duration_sec": 300}]})
    assert long.json()["error"]["code"] == "err.audio_too_long"


def test_chat_between_customer_and_bidder_only():
    cust, worker, stranger = tok("9100000003"), tok("9200000005"), tok("9200000001")
    job = next(j for j in client.get("/customer/jobs", headers=cust).json() if j["status"] == "bidding")
    bid = client.get(f"/customer/jobs/{job['id']}", headers=cust).json()["bids"][0]
    wid = bid["worker"]["id"]
    assert client.post(f"/jobs/{job['id']}/chat", headers=cust, json={"to": wid, "body": "Kal aa sakte ho?"}).status_code == 200
    me = client.get("/me", headers=worker).json()["id"]
    if me == wid:
        msgs = client.get(f"/jobs/{job['id']}/chat?with={job['id']}", headers=worker).json()
        assert msgs and not msgs[-1]["mine"]
    assert client.get(f"/jobs/{job['id']}/chat?with={wid}", headers=stranger).status_code == 403


def test_worker_location_update_changes_feed_distance():
    h = tok("9200000009")
    assert client.patch("/worker/profile", headers=h, json={"home_lat": 31.326, "home_lng": 75.5762}).status_code == 200  # Jalandhar
    assert client.get("/worker/feed", headers=h).json() == []  # Pune jobs are outside the radius
    client.patch("/worker/profile", headers=h, json={"home_lat": 18.5074, "home_lng": 73.8077})
    assert client.get("/worker/feed", headers=h).json()
    assert client.patch("/worker/profile", headers=h, json={"home_lat": 51.5, "home_lng": -0.12}).status_code == 422
