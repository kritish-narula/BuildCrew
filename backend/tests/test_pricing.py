"""Pricing model + Fair Wage Shield. Pure-model tests need no DB; endpoint tests need the seed."""
from types import SimpleNamespace as NS

from fastapi.testclient import TestClient

from app.domain import pricing
from app.main import app
from app.security import _hits

client = TestClient(app)


def tok(phone):
    _hits.clear()
    client.post("/auth/otp/request", json={"phone": phone})
    r = client.post("/auth/otp/verify", json={"phone": phone, "code": "123456"})
    return {"Authorization": f"Bearer {r.json()['token']}"}


def job(items, city="Pune"):
    return NS(city=city, work_items=[NS(trade=t, text_description=x, transcript=None) for t, x in items])


def test_city_tiers():
    assert pricing.city_multiplier("Mumbai") == 1.0
    assert pricing.city_multiplier("jalandhar") == 0.85
    assert pricing.city_multiplier("Smalltown") == 0.8
    assert pricing.city_multiplier(None) == 0.8


def test_realistic_ranges():
    wall = pricing.estimate_item("mason", "Compound wall 40 ft, 5 ft height", "Pune")
    assert 12000 <= wall["low_inr"] <= wall["high_inr"] <= 18500 and wall["est_days"] == 5
    leak = pricing.estimate_item("plumber", "bathroom tap leak", "Pune")
    assert 400 <= leak["low_inr"] and leak["high_inr"] <= 700
    wiring = pricing.estimate_item("electrician", "Rewire kitchen, add 4 new sockets", "Pune")
    assert 1500 <= wiring["low_inr"] and wiring["high_inr"] <= 2500
    kitchen = pricing.estimate_item("painter", "Paint the kitchen", "Pune")
    assert 6000 <= kitchen["low_inr"] and kitchen["high_inr"] <= 9000
    hall = pricing.estimate_item("painter", "repaint 900 sq ft", "Mumbai")
    assert hall["median_inr"] == 9000


def test_tier2_is_cheaper_and_min_wage_floor():
    a, b = pricing.estimate_item("mason", "wall 40 ft", "Delhi"), pricing.estimate_item("mason", "wall 40 ft", "Jalandhar")
    assert b["median_inr"] < a["median_inr"]
    h = pricing.estimate_item("helper", "3 days", "Smalltown")
    assert h["low_inr"] >= pricing.MIN_WAGE_PER_DAY["unskilled"] * 3


def test_fair_check_verdicts():
    j = job([("electrician", "Rewire kitchen, 4 points")])
    rng = pricing.fair_range(j)
    assert rng["min_wage_total"] == 954 and rng["low"] <= rng["median"] <= rng["high"]
    assert pricing.fair_check(500, j)["verdict"] == "below_min_wage"
    assert pricing.fair_check(rng["median"], j)["verdict"] == "fair"
    assert pricing.fair_check(rng["high"] * 2, j)["verdict"] == "high"


def test_trade_filter_for_multi_trade_job():
    j = job([("electrician", "4 points rewiring"), ("painter", "paint kitchen")])
    assert pricing.fair_range(j, ["painter"])["median"] < pricing.fair_range(j)["median"]


def test_estimate_endpoint_uses_city_and_texts():
    h = tok("9100000003")
    r = client.get("/customer/price-estimate", headers=h, params={
        "trades": "mason,painter", "texts": "Compound wall 40 ft|repaint 900 sq ft", "city": "Jalandhar"}).json()
    assert r["city"] == "Jalandhar" and len(r["items"]) == 2
    assert r["total_low_inr"] <= r["total_median_inr"] <= r["total_high_inr"]
    assert r["items"][0]["est_days"] == 5
    no_city = client.get("/customer/price-estimate?trades=plumber", headers=h).json()
    assert no_city["items"] and no_city["city"] is None


def test_bids_and_worker_detail_carry_fair_fields():
    cust = tok("9100000003")
    jobs = client.get("/customer/jobs", headers=cust).json()
    bidding = next(j for j in jobs if j["bid_count"] >= 3)
    d = client.get(f"/customer/jobs/{bidding['id']}", headers=cust).json()
    verdicts = {b["fair"]["verdict"] for b in d["bids"]}
    assert "below_min_wage" in verdicts and "fair" in verdicts
    assert all({"verdict", "low", "high", "min_wage_total"} <= set(b["fair"]) for b in d["bids"])
    w = client.get(f"/worker/jobs/{bidding['id']}", headers=tok("9200000005")).json()
    assert {"low", "median", "high", "min_wage_total", "est_days"} <= set(w["fair_range"])
