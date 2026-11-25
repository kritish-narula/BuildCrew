"""Phase 1 tests — run against a real Postgres with the seed loaded:
    DATABASE_URL=... alembic upgrade head && python -m app.seed --reset && pytest -q
"""
import time
import uuid

import pytest
from fastapi.testclient import TestClient
from sqlalchemy import select, text

from app import services
from app.db import SessionLocal
from app.domain.fees import compute_fees
from app.domain.policies import can_access_job_media
from app.domain.state import transition
from app.enums import EscrowState, JobStatus
from app.errors import AppError
from app.i18n import missing_keys, t
from app.main import app
from app.models import AuditLog, Job, Payment, User
from app.security import _hits

client = TestClient(app)


@pytest.fixture(autouse=True)
def _clear_rate_limits():
    _hits.clear()


def login(phone: str, **extra) -> dict:
    assert client.post("/auth/otp/request", json={"phone": phone}).status_code == 200
    r = client.post("/auth/otp/verify", json={"phone": phone, "code": "123456", **extra})
    assert r.status_code == 200, r.text
    return r.json()


def auth(tok: str) -> dict:
    return {"Authorization": f"Bearer {tok}"}


def test_role_routing_for_each_seeded_role():
    assert login("9000000001")["home_route"] == "/admin"
    assert login("9100000001")["home_route"] == "/customer/home"
    assert login("9200000001")["home_route"] == "/worker/jobs"


def test_otp_sms_is_vernacular():
    client.post("/auth/otp/request", json={"phone": "9200000005"})  # Venkat, Telugu
    sms = client.get("/dev/sms-outbox").json()[0]
    assert sms["to"] == "9200000005" and "కోడ్" in sms["text"] and "123456" in sms["text"]


def test_wrong_otp_error_is_localised_hindi():
    client.post("/auth/otp/request", json={"phone": "9200000002"})
    r = client.post("/auth/otp/verify", json={"phone": "9200000002", "code": "000000", "language_code": "hi"})
    assert r.status_code == 400
    assert r.json()["error"]["message"] == t("err.otp_invalid", "hi")


def test_otp_cannot_be_reused():
    login("9200000003")
    r = client.post("/auth/otp/verify", json={"phone": "9200000003", "code": "123456"})
    assert r.status_code == 400 and r.json()["error"]["code"] == "err.otp_expired"


def test_otp_brute_force_locked_after_max_attempts():
    client.post("/auth/otp/request", json={"phone": "9200000004"})
    for _ in range(5):
        client.post("/auth/otp/verify", json={"phone": "9200000004", "code": "999999"})
    r = client.post("/auth/otp/verify", json={"phone": "9200000004", "code": "123456"})
    assert r.status_code == 429


def test_new_user_signup_and_admin_signup_forbidden():
    phone = f"98{uuid.uuid4().int % 10**8:08d}"
    out = login(phone, role="worker", language_code="ta")
    assert out["is_new"] and out["user"]["kyc_level"] == 0 and out["user"]["language_code"] == "ta"
    phone2 = f"97{uuid.uuid4().int % 10**8:08d}"
    client.post("/auth/otp/request", json={"phone": phone2})
    r = client.post("/auth/otp/verify", json={"phone": phone2, "code": "123456", "role": "admin"})
    assert r.status_code == 403


def test_role_guards():
    worker = login("9200000001")["token"]
    customer = login("9100000001")["token"]
    assert client.get("/admin/kpis", headers=auth(worker)).status_code == 403
    assert client.get("/worker/feed", headers=auth(customer)).status_code == 403
    assert client.get("/customer/jobs", headers=auth(customer)).status_code == 200
    assert client.get("/me").status_code == 401


def test_worker_feed_has_audio_badge_but_no_audio_url():
    tok = login("9200000003")["token"]  # plumber in Wakad
    feed = client.get("/worker/feed", headers=auth(tok)).json()
    assert feed, "plumber should see the open Kothrud plumbing job"
    with_audio = [j for j in feed if j["audio"]]
    assert with_audio and with_audio[0]["audio"]["total_kb"] < 100   # voice-optimised, not MBs
    assert "audio_url" not in str(feed)


def test_admin_kpis_reflect_seed():
    k = client.get("/admin/kpis", headers=auth(login("9000000001")["token"])).json()
    assert k["active_jobs"] == 4 and k["open_disputes"] == 1 and k["gmv_inr"] > 0


def test_pii_is_encrypted_at_rest_and_masked_for_others():
    with SessionLocal() as db:
        raw = db.execute(text("select upi_id from worker_profiles where upi_id is not null limit 1")).scalar()
        assert raw.startswith("gAAAA")  # Fernet ciphertext in the DB
    me = client.get("/me", headers=auth(login("9200000001")["token"])).json()
    assert me["upi_id"].endswith("@okaxis") and "*" not in me["upi_id"]


def test_signed_media_urls_expire_and_reject_tampering():
    store = services.storage()
    key = store.put(b"abc", prefix="audio", ext="ogg", content_type="audio/ogg")
    url = store.signed_url(key, 60).replace("http://localhost:8000", "")
    assert client.get(url).status_code == 200
    assert client.get(url[:-4] + "0000").status_code == 403
    expired = store.signed_url(key, -1).replace("http://localhost:8000", "")
    assert client.get(expired).status_code == 410


def test_audio_access_policy():
    with SessionLocal() as db:
        job = db.scalar(select(Job).where(Job.status == JobStatus.open))
        owner = db.get(User, job.customer_id)
        other_customer = db.scalar(select(User).where(User.phone == "9100000003"))
        plumber = db.scalar(select(User).where(User.phone == "9200000003"))
        electrician = db.scalar(select(User).where(User.phone == "9200000005"))
        admin = db.scalar(select(User).where(User.phone == "9000000001"))
        assert can_access_job_media(db, owner, job) and can_access_job_media(db, admin, job)
        assert can_access_job_media(db, plumber, job)            # eligible to bid
        assert not can_access_job_media(db, electrician, job)    # wrong trade
        assert not can_access_job_media(db, other_customer, job)


def test_state_machine_rejects_illegal_and_audits_legal_moves():
    with SessionLocal() as db:
        pay = db.scalar(select(Payment).where(Payment.escrow_state == EscrowState.held))
        with pytest.raises(AppError):
            transition(db, pay, kind="escrow", field="escrow_state", new=EscrowState.created, actor_id=None)
        before = db.query(AuditLog).count()
        transition(db, pay, kind="escrow", field="escrow_state", new=EscrowState.refunded, actor_id=None, reason="test")
        db.flush()
        assert db.query(AuditLog).count() == before + 1
        db.rollback()  # leave seed untouched


def test_fees_are_config_driven():
    f = compute_fees(1800_00)
    assert f.flat_fee_paise == 30_00 and f.customer_pays_paise == 1830_00 and f.worker_payout_paise == 1800_00


def test_payment_signatures_verified():
    p = services.payment()
    good = p.sign(b"order_1|pay_1")
    assert p.verify_checkout_signature("order_1", "pay_1", good)
    assert not p.verify_checkout_signature("order_1", "pay_2", good)
    assert not p.verify_webhook(b'{"amount":1}', "deadbeef")


def test_mock_language_services():
    assert services.translation().translate("hello", "en", "hi").startswith("[हिन्दी]")
    assert services.speech().transcribe(b"", "hi")
    assert services.speech().synthesize("नमस्ते", "hi")[:4] == b"OggS"


def test_i18n_en_and_hi_complete_others_scaffolded():
    missing = missing_keys()
    assert missing["en"] == [] and missing["hi"] == []
    for lang in ("bn", "te", "mr", "ta", "gu", "kn", "ml", "or", "pa", "as"):
        assert "sms.otp" not in missing[lang] and "trade.mason" not in missing[lang]


def test_validation_errors_localised():
    r = client.post("/auth/otp/request", json={"phone": "12345"}, headers={"Accept-Language": "hi"})
    assert r.status_code == 422 and r.json()["error"]["message"] == t("err.validation", "hi")
