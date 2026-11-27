"""Sync change feed, notifications + push, Razorpay (signatures, webhook idempotency, refunds), payout provider choice.
No network: Razorpay / RazorpayX run against httpx.MockTransport. Requires the seed."""
import hashlib
import hmac
import json
import uuid
from datetime import timedelta

import httpx
import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select

from app import services
from app.config import Settings
from app.db import SessionLocal
from app.domain.flows import today_ist
from app.main import app
from app.models import Payment, User
from app.security import _hits, issue_token
from app.services.payment import MockPaymentProvider, RazorpayProvider, build_payment_provider
from app.services.payout import MockPayoutProvider, RazorpayXPayoutProvider, build_payout_provider

client = TestClient(app)
CUST, PLUMBER = "9100000003", "9200000003"
LONG = "Kitchen sink is leaking under the counter, please fix the pipe and the tap."


@pytest.fixture(autouse=True)
def _clean():
    _hits.clear()


def tok(phone):
    with SessionLocal() as db:
        return {"Authorization": f"Bearer {issue_token(db.scalar(select(User).where(User.phone == phone)))}"}


def uid(phone):
    with SessionLocal() as db:
        return str(db.scalar(select(User.id).where(User.phone == phone)))


def photo(h):
    return client.post("/media/upload", headers=h, data={"kind": "photo"},
                       files={"file": ("x.jpg", b"\xff\xd8fake" + uuid.uuid4().bytes)}).json()["key"]


def post_job(c):
    r = client.post("/customer/jobs", headers=c, json={
        "location_lat": 18.5986, "location_lng": 73.7604, "address_text": "B-402 Wakad",
        "start_date": str(today_ist() + timedelta(days=1)),
        "work_items": [{"trade": "plumber", "text_description": LONG, "description_language": "en",
                        "photo_keys": [photo(c), photo(c)]}]})
    assert r.status_code == 200, r.text
    return r.json()["id"]


def hire(pay=False):
    c, w = tok(CUST), tok(PLUMBER)
    jid = post_job(c)
    bid = client.post("/worker/bids", headers=w, json={"job_id": jid, "price_inr": 1500}).json()["id"]
    acc = client.post(f"/customer/jobs/{jid}/bids/{bid}/accept", headers=c).json()
    if pay:
        assert client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi"}).status_code == 200
    return c, w, jid, acc["assignment_id"]


def kinds(h):
    return [n["kind"] for n in client.get("/notifications", headers=h).json()["items"]]


# ------------------------------------------------------------------ sync
def test_sync_cursor_semantics():
    c, w = tok(CUST), tok(PLUMBER)
    base = client.get("/sync", headers=c).json()
    assert base["full"] is True and base["changed"]["jobs"] == []
    cur = base["cursor"]
    same = client.get("/sync", params={"since": cur}, headers=c).json()
    assert same["cursor"] == cur and same["full"] is False and same["changed"]["jobs"] == []  # nothing new = empty + same cursor
    jid = post_job(c)
    r1 = client.get("/sync", params={"since": cur}, headers=c).json()
    assert jid in r1["changed"]["jobs"] and r1["cursor"] > cur
    wbase = client.get("/sync", headers=w).json()["cursor"]
    bid = client.post("/worker/bids", headers=w, json={"job_id": jid, "price_inr": 1500}).json()["id"]
    r2 = client.get("/sync", params={"since": r1["cursor"]}, headers=c).json()
    assert jid in r2["changed"]["jobs"] and r2["changed"]["notifications"] >= 1  # the new quote notification
    client.post(f"/customer/jobs/{jid}/bids/{bid}/accept", headers=c)
    rw = client.get("/sync", params={"since": wbase}, headers=w).json()
    assert jid in rw["changed"]["jobs"] and rw["changed"]["assignments"]
    # replaying the cursor you already hold yields nothing
    assert client.get("/sync", params={"since": rw["cursor"]}, headers=w).json()["changed"]["jobs"] == []
    # users only see their own changes
    other = tok("9100000001")
    ob = client.get("/sync", headers=other).json()["cursor"]
    assert client.get("/sync", params={"since": ob}, headers=other).json()["changed"]["jobs"] == []


# ------------------------------------------------------------------ notifications + push
def test_notifications_per_event_unread_and_read_marking():
    c, w = tok(CUST), tok(PLUMBER)
    before_c = client.get("/notifications/unread-count", headers=c).json()["unread"]
    before_w = client.get("/notifications/unread-count", headers=w).json()["unread"]
    jid = post_job(c)
    assert "new_job" in kinds(w)  # matching plumber hears about it
    assert client.get("/notifications/unread-count", headers=w).json()["unread"] == before_w + 1
    bid = client.post("/worker/bids", headers=w, json={"job_id": jid, "price_inr": 1500}).json()["id"]
    assert kinds(c)[0] == "new_quote" and client.get("/notifications/unread-count", headers=c).json()["unread"] == before_c + 1
    acc = client.post(f"/customer/jobs/{jid}/bids/{bid}/accept", headers=c).json()
    assert kinds(w)[0] == "quote_accepted"
    client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi"})
    assert kinds(w)[0] == "payment_held"
    # chat
    client.post(f"/jobs/{jid}/chat", headers=c, json={"to": uid(PLUMBER), "body": "9 am?"})
    first = client.get("/notifications", headers=w).json()["items"][0]
    assert first["kind"] == "chat_message" and first["link"] == f"/chat/{jid}/{uid(CUST)}" and "9 am?" in first["body"]
    # journey + done -> customer
    client.post(f"/worker/assignments/{acc['assignment_id']}/journey", headers=w, json={"lat": 18.59, "lng": 73.76})
    assert kinds(c)[0] == "worker_on_way"
    # read marking
    items = client.get("/notifications", headers=w).json()
    ids = [n["id"] for n in items["items"][:2]]
    r = client.post("/notifications/read", headers=w, json={"ids": ids}).json()
    assert r["marked"] == 2 and r["unread"] == items["unread"] - 2
    assert client.post("/notifications/read", headers=w, json={}).json()["unread"] == 0
    assert all(n["read"] for n in client.get("/notifications", headers=w).json()["items"])
    # other people cannot mark mine
    assert client.post("/notifications/read", headers=c, json={"ids": ids}).json()["marked"] == 0


def test_push_token_and_mock_provider_receives_notifications():
    c, w = tok(CUST), tok(PLUMBER)
    token = "fcm-" + uuid.uuid4().hex
    assert client.post("/me/push-token", headers=w, json={"token": token}).status_code == 200
    assert client.post("/me/push-token", headers=w, json={"token": token}).status_code == 200  # idempotent
    push = services.push()
    assert isinstance(push, services.MockPush)
    n = len(push.sent)
    jid = post_job(c)
    sent = [m for m in push.sent[n:] if m["token"] == token]
    assert sent and sent[0]["data"]["kind"] == "new_job" and sent[0]["data"]["link"] == f"/job/{jid}"
    assert client.delete("/me/push-token", headers=w, params={"token": token}).status_code == 200


# ------------------------------------------------------------------ Razorpay
SECRET, WH = "rzp_secret_x", "whsec_x"


def live_provider(calls):
    def handler(req: httpx.Request):
        calls.append((req.method, req.url.path, json.loads(req.content) if req.content else None))
        if req.url.path == "/v1/orders" and req.method == "POST":
            return httpx.Response(200, json={"id": "order_" + uuid.uuid4().hex[:10]})
        if req.url.path.endswith("/refund"):
            return httpx.Response(200, json={"id": "rfnd_1"})
        return httpx.Response(404, json={})
    return RazorpayProvider("rzp_test_k", SECRET, WH, client=httpx.Client(base_url=RazorpayProvider.BASE, transport=httpx.MockTransport(handler)))


def sig(secret, msg: bytes):
    return hmac.new(secret.encode(), msg, hashlib.sha256).hexdigest()


def test_razorpay_signature_verification():
    p = live_provider([])
    good = sig(SECRET, b"order_1|pay_1")
    assert p.verify_checkout_signature("order_1", "pay_1", good)
    assert not p.verify_checkout_signature("order_1", "pay_2", good)
    assert not p.verify_checkout_signature("order_1", "pay_1", "")
    assert p.verify_webhook(b"{}", sig(WH, b"{}")) and not p.verify_webhook(b"{}", sig(SECRET, b"{}"))
    assert not RazorpayProvider("k", SECRET, "").verify_webhook(b"{}", sig("", b"{}"))  # no webhook secret = never valid


def test_live_pay_flow_verify_webhook_idempotency_and_refund_on_cancel(monkeypatch):
    calls: list = []
    prov = live_provider(calls)
    monkeypatch.setattr(services, "payment", lambda: prov)
    c, w, jid, asg = hire()
    # 1) /pay without a payment id returns Checkout params (never marks paid)
    co = client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi"}).json()
    assert co["provider"] == "razorpay" and co["key_id"] == "rzp_test_k" and co["currency"] == "INR" and co["amount"] == 153000
    order = co["order_id"]
    # 2) bad signature -> refused, still unpaid
    bad = client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi", "razorpay_payment_id": "pay_1", "razorpay_signature": "nope"})
    assert bad.status_code == 403 and bad.json()["error"]["code"] == "err.payment_signature"
    # 3) valid signature -> held, payment id stored
    ok = client.post(f"/customer/jobs/{jid}/pay", headers=c, json={
        "method": "upi", "razorpay_payment_id": "pay_1", "razorpay_signature": sig(SECRET, f"{order}|pay_1".encode())})
    assert ok.status_code == 200 and ok.json()["escrow_state"] == "held"
    with SessionLocal() as db:
        assert db.scalar(select(Payment.razorpay_payment_id).where(Payment.razorpay_ref == order)) == "pay_1"
    assert "payment_held" in kinds(w)
    # 4) cancel before work starts -> provider refund is called with the full amount
    r = client.post(f"/customer/jobs/{jid}/cancel", headers=c)
    assert r.status_code == 200, r.text
    refunds = [x for x in calls if x[1] == "/v1/payments/pay_1/refund"]
    assert len(refunds) == 1 and refunds[0][2]["amount"] == 153000
    assert "refund_done" in kinds(c)


def test_webhook_signature_captured_idempotent_and_failed(monkeypatch):
    calls: list = []
    prov = live_provider(calls)
    monkeypatch.setattr(services, "payment", lambda: prov)
    c, w, jid, asg = hire()
    with SessionLocal() as db:
        order = db.scalar(select(Payment.razorpay_ref).where(Payment.assignment_id == uuid.UUID(asg)))
    body = json.dumps({"event": "payment.captured", "payload": {"payment": {"entity": {"id": "pay_w1", "order_id": order, "method": "upi"}}}}).encode()
    assert client.post("/payments/webhook", content=body, headers={"x-razorpay-signature": "bad"}).status_code == 403
    hdr = {"x-razorpay-signature": sig(WH, body), "x-razorpay-event-id": "evt_" + uuid.uuid4().hex}
    assert client.post("/payments/webhook", content=body, headers=hdr).json() == {"ok": True}
    held = [n for n in client.get("/notifications", headers=w).json()["items"] if n["kind"] == "payment_held"]
    again = client.post("/payments/webhook", content=body, headers=hdr).json()
    assert again.get("duplicate") is True
    assert len([n for n in client.get("/notifications", headers=w).json()["items"] if n["kind"] == "payment_held"]) == len(held)
    with SessionLocal() as db:
        p = db.scalar(select(Payment).where(Payment.assignment_id == uuid.UUID(asg)))
        assert p.escrow_state.value == "held" and p.razorpay_payment_id == "pay_w1"
    # a second, different event id for the same capture is harmless (state machine idempotent)
    hdr2 = {"x-razorpay-signature": sig(WH, body), "x-razorpay-event-id": "evt_" + uuid.uuid4().hex}
    assert client.post("/payments/webhook", content=body, headers=hdr2).status_code == 200
    # failed payment -> customer is told
    c2, w2, jid2, asg2 = hire()
    with SessionLocal() as db:
        order2 = db.scalar(select(Payment.razorpay_ref).where(Payment.assignment_id == uuid.UUID(asg2)))
    fb = json.dumps({"event": "payment.failed", "payload": {"payment": {"entity": {"id": "pay_f", "order_id": order2, "error_code": "BAD_REQUEST_ERROR"}}}}).encode()
    assert client.post("/payments/webhook", content=fb, headers={"x-razorpay-signature": sig(WH, fb), "x-razorpay-event-id": "evt_" + uuid.uuid4().hex}).status_code == 200
    assert kinds(c2)[0] == "payment_failed"


def test_mock_mode_unchanged_and_provider_selection():
    assert isinstance(build_payment_provider(Settings(payment_provider="auto", razorpay_key_id="", razorpay_key_secret="")), MockPaymentProvider)
    assert isinstance(build_payment_provider(Settings(payment_provider="mock", razorpay_key_id="k", razorpay_key_secret="s")), MockPaymentProvider)
    live = build_payment_provider(Settings(payment_provider="auto", razorpay_key_id="k", razorpay_key_secret="s", razorpay_webhook_secret="w"))
    assert isinstance(live, RazorpayProvider) and live.live and not live.route
    c, w, jid, asg = hire()  # services.payment() is the mock here
    r = client.post(f"/customer/jobs/{jid}/pay", headers=c, json={"method": "upi"}).json()
    assert r["provider"] == "mock" and r["escrow_state"] == "held"


def test_payout_provider_selection_and_razorpayx_flow():
    assert isinstance(build_payout_provider(Settings(payout_provider="auto", razorpayx_account_number="")), MockPayoutProvider)
    assert isinstance(build_payout_provider(Settings(payout_provider="mock", razorpayx_account_number="a", razorpay_key_id="k", razorpay_key_secret="s")), MockPayoutProvider)
    x = build_payout_provider(Settings(payout_provider="auto", razorpayx_account_number="2323230000", razorpay_key_id="k", razorpay_key_secret="s"))
    assert isinstance(x, RazorpayXPayoutProvider)
    seen = []

    def handler(req):
        seen.append((req.method, req.url.path, json.loads(req.content) if req.content else None))
        if req.url.path == "/v1/contacts":
            return httpx.Response(200, json={"id": "cont_1"})
        if req.url.path == "/v1/fund_accounts":
            return httpx.Response(200, json={"id": "fa_1"})
        if req.url.path == "/v1/payouts":
            return httpx.Response(200, json={"id": "pout_1", "status": "queued"})
        return httpx.Response(200, json={"status": "processed"})
    p = RazorpayXPayoutProvider("k", "s", "2323230000", client=httpx.Client(base_url=RazorpayXPayoutProvider.BASE, transport=httpx.MockTransport(handler)))
    ref, st = p.send(upi_id="ramesh@upi", amount_paise=150000, reference="asg_abc")
    assert (ref, st) == ("pout_1", "processing")
    payout = [s for s in seen if s[1] == "/v1/payouts"][0][2]
    assert payout["mode"] == "UPI" and payout["amount"] == 150000 and payout["fund_account_id"] == "fa_1"
    assert [s for s in seen if s[1] == "/v1/fund_accounts"][0][2]["vpa"] == {"address": "ramesh@upi"}
    assert p.status("pout_1", None) == "paid"
    assert RazorpayXPayoutProvider._map("reversed") == "failed" and RazorpayXPayoutProvider._map("pending") == "processing"
