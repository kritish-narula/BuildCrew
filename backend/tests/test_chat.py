"""Two-way job chat, inbox and read receipts. Requires the seed."""
from datetime import date, timedelta

import pytest
from fastapi.testclient import TestClient

from app.main import app
from app.security import _hits

client = TestClient(app)


@pytest.fixture(autouse=True)
def _clear():
    _hits.clear()


def login(phone: str):
    client.post("/auth/otp/request", json={"phone": phone})
    r = client.post("/auth/otp/verify", json={"phone": phone, "code": "123456"})
    assert r.status_code == 200, r.text
    return {"Authorization": f"Bearer {r.json()['token']}"}, r.json()["user"]["id"]


def inbox(h, jid):
    return [t for t in client.get("/chats", headers=h).json() if t["job_id"] == jid]


def test_chat_flows_both_ways_with_inbox_and_read_state():
    ch, cid = login("9100000001")
    wh, wid = login("9200000003")
    oh, oid = login("9200000004")  # never quoted
    job = client.post("/customer/jobs", headers=ch, json={
        "location_lat": 18.5986, "location_lng": 73.7604, "address_text": "B-402 Wakad",
        "start_date": str(date.today() + timedelta(days=1)),
        "work_items": [{"trade": "plumber", "text_description": "Sink leak", "description_language": "en"}]}).json()
    jid = job["id"]
    assert client.post("/worker/bids", headers=wh, json={"job_id": jid, "price_inr": 1500}).status_code == 200

    # the worker sees the customer id on the job (needed to open the chat)
    det = client.get(f"/worker/jobs/{jid}", headers=wh).json()
    assert det["customer_id"] == cid

    # worker -> customer, then customer -> worker
    assert client.post(f"/jobs/{jid}/chat", headers=wh, json={"to": cid, "body": "Namaste, can start tomorrow"}).status_code == 200
    assert client.post(f"/jobs/{jid}/chat", headers=ch, json={"to": wid, "body": "Great, 9 am?"}).status_code == 200

    # inbox before opening: each side has exactly one unread
    ci = inbox(ch, jid)
    wi = inbox(wh, jid)
    assert len(ci) == 1 and ci[0]["unread"] == 1 and ci[0]["with_user"] == wid and ci[0]["job_id"] == jid
    assert ci[0]["last_body"] == "Great, 9 am?" and ci[0]["with_name"] == "Imran Shaikh"
    assert ci[0]["trades"] == ["plumber"] and ci[0]["locality"]
    assert len(wi) == 1 and wi[0]["unread"] == 1 and wi[0]["with_user"] == cid

    # both see both messages, with correct "mine"
    cm = client.get(f"/jobs/{jid}/chat", headers=ch, params={"with": wid}).json()
    wm = client.get(f"/jobs/{jid}/chat", headers=wh, params={"with": cid}).json()
    assert [(m["mine"], m["body"]) for m in cm] == [(False, "Namaste, can start tomorrow"), (True, "Great, 9 am?")]
    assert [m["mine"] for m in wm] == [True, False]

    # opening marked them read
    assert inbox(ch, jid)[0]["unread"] == 0
    assert inbox(wh, jid)[0]["unread"] == 0

    # a new message raises unread only for the recipient
    client.post(f"/jobs/{jid}/chat", headers=ch, json={"to": wid, "body": "Bring tools"})
    assert inbox(wh, jid)[0]["unread"] == 1
    assert inbox(ch, jid)[0]["unread"] == 0

    # a worker who did not quote is locked out; so is the customer talking to them
    assert client.post(f"/jobs/{jid}/chat", headers=oh, json={"to": cid, "body": "hi"}).status_code == 403
    assert client.get(f"/jobs/{jid}/chat", headers=oh, params={"with": cid}).status_code == 403
    assert client.post(f"/jobs/{jid}/chat", headers=ch, json={"to": oid, "body": "hi"}).status_code == 403
    assert inbox(oh, jid) == []
