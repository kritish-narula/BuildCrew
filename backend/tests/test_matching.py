"""Best-match scoring for quotes: pure model tests + the customer job-detail fields (needs the seed)."""
import pytest
from fastapi.testclient import TestClient

from app.domain import matching
from app.main import app
from app.security import _hits

client = TestClient(app)

GOOD = dict(verdict="fair", rating=4.8, rating_count=40, completed_jobs=60, distance_km=1.2,
            police_verified=True, level="master", response_min=10)
POOR = dict(verdict="high", rating=3.2, rating_count=10, completed_jobs=2, distance_km=14, police_verified=False,
            level="helper", response_min=2000)


def test_score_orders_and_bounds():
    assert matching.score(**GOOD) > matching.score(**POOR)
    assert 0 <= matching.score(**POOR) <= matching.score(**GOOD) <= 100
    assert matching.score(**GOOD) >= 90


def test_each_factor_helps():
    base = matching.score(**{**GOOD, "police_verified": False})
    assert matching.score(**GOOD) > base
    assert matching.score(**{**GOOD, "verdict": "high"}) < matching.score(**GOOD)
    assert matching.score(**{**GOOD, "distance_km": 12}) < matching.score(**GOOD)
    assert matching.score(**{**GOOD, "rating": 4.0}) < matching.score(**GOOD)


def test_new_worker_is_not_punished_to_zero_and_few_reviews_count_less():
    new = matching.score(**{**GOOD, "rating": 0, "rating_count": 0})
    assert new > matching.score(**POOR)
    assert matching.rating_points(5.0, 1) < matching.rating_points(5.0, 10)


def test_reasons_are_short_and_ordered():
    r = matching.reasons(**GOOD)
    assert [x["code"] for x in r] == ["fair", "rating", "distance", "police"]
    assert matching.reasons(**POOR) == []


def test_can_come_today():
    assert matching.can_come_today(job_is_today=True, distance_km=3, busy_today=False)
    assert not matching.can_come_today(job_is_today=False, distance_km=3, busy_today=False)
    assert not matching.can_come_today(job_is_today=True, distance_km=3, busy_today=True)
    assert not matching.can_come_today(job_is_today=True, distance_km=30, busy_today=False)
    assert not matching.can_come_today(job_is_today=True, distance_km=None, busy_today=False)


def test_mark_best_needs_two_quotes_and_picks_one():
    rows = [{"status": "pending", "match_score": 70, "price_inr": 500}]
    matching.mark_best(rows)
    assert rows[0]["best_match"] is False
    rows = [{"status": "pending", "match_score": 70, "price_inr": 600}, {"status": "pending", "match_score": 70, "price_inr": 500},
            {"status": "rejected", "match_score": 99, "price_inr": 100}]
    matching.mark_best(rows)
    assert [r["best_match"] for r in rows] == [False, True, False]  # tie -> cheaper; rejected never best


@pytest.fixture(autouse=True)
def _clear():
    _hits.clear()


def tok(phone):
    client.post("/auth/otp/request", json={"phone": phone})
    r = client.post("/auth/otp/verify", json={"phone": phone, "code": "123456"})
    return {"Authorization": f"Bearer {r.json()['token']}"}


def test_job_detail_has_match_fields():
    h = tok("9100000003")
    jobs = client.get("/customer/jobs", headers=h).json()
    bidding = [j for j in jobs if j["status"] == "bidding" and j.get("bid_count", 0) >= 2]
    assert bidding, "seed has a job with several quotes"
    d = client.get(f"/customer/jobs/{bidding[0]['id']}", headers=h).json()
    bids = d["bids"]
    assert len(bids) >= 2
    for b in bids:
        assert isinstance(b["match_score"], int) and 0 <= b["match_score"] <= 100
        assert isinstance(b["match_reasons"], list) and isinstance(b["can_come_today"], bool)
        assert "distance_km" in b and isinstance(b["best_match"], bool)
    best = [b for b in bids if b["best_match"]]
    assert len(best) == 1
    assert best[0]["match_score"] == max(b["match_score"] for b in bids if b["status"] == "pending")
