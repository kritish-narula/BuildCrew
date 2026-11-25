"""SMS, Maps and Realtime adapters.

Realtime choice — Supabase Realtime (not Firebase):
  * our source of truth is already Postgres; Supabase streams row changes (bids, chat) straight
    from it, so there is no second database to keep consistent;
  * row-level security reuses the same access rules as the API;
  * self-hostable and available in the Mumbai region (data residency under India's DPDP Act).
Locally we use an in-process mock behind the same interface, so `docker compose up` needs no
cloud account.
"""
import logging
import math
from abc import ABC, abstractmethod
from collections import deque

log = logging.getLogger(__name__)


# ---------------------------------------------------------------- SMS
class SmsProvider(ABC):
    @abstractmethod
    def send(self, phone: str, text: str) -> None: ...


class DevSmsStub(SmsProvider):
    """Keeps the last 50 messages in memory (visible at GET /dev/sms-outbox in dev only).
    Never writes message bodies (which contain OTPs) to logs."""

    def __init__(self):
        self.outbox: deque = deque(maxlen=50)

    def send(self, phone, text):
        self.outbox.appendleft({"to": phone, "text": text})
        log.info("dev sms queued to %s******", phone[:2])


class Msg91Sms(SmsProvider):
    def __init__(self, auth_key: str):
        import httpx
        if not auth_key:
            raise RuntimeError("MSG91_AUTH_KEY missing")
        self.http, self.key = httpx.Client(timeout=10), auth_key

    def send(self, phone, text):
        # DLT-registered template required in India; text must match the approved template.
        self.http.post("https://control.msg91.com/api/v5/flow/", headers={"authkey": self.key},
                       json={"recipients": [{"mobiles": f"91{phone}", "message": text}]}).raise_for_status()


# ---------------------------------------------------------------- Maps
PUNE_LOCALITIES = {  # mock geocoder data (seed city)
    "Kothrud": (18.5074, 73.8077), "Baner": (18.5590, 73.7868), "Hadapsar": (18.5089, 73.9260),
    "Wakad": (18.5986, 73.7604), "Viman Nagar": (18.5679, 73.9143), "Aundh": (18.5580, 73.8075),
    "Kharadi": (18.5515, 73.9348), "Shivajinagar": (18.5308, 73.8475),
}


class MapsService(ABC):
    @abstractmethod
    def geocode(self, query: str) -> tuple[float, float] | None: ...

    @abstractmethod
    def reverse_locality(self, lat: float, lng: float) -> str | None: ...

    @staticmethod
    def distance_km(a: tuple[float, float], b: tuple[float, float]) -> float:
        """Haversine — good enough for feed sorting; real road distance is a Phase-2 nicety."""
        r = 6371.0
        (la1, lo1), (la2, lo2) = [(math.radians(x), math.radians(y)) for x, y in (a, b)]
        h = math.sin((la2 - la1) / 2) ** 2 + math.cos(la1) * math.cos(la2) * math.sin((lo2 - lo1) / 2) ** 2
        return 2 * r * math.asin(math.sqrt(h))


class MockMaps(MapsService):
    def geocode(self, query):
        for name, ll in PUNE_LOCALITIES.items():
            if name.lower() in query.lower():
                return ll
        return None

    def reverse_locality(self, lat, lng):
        return min(PUNE_LOCALITIES, key=lambda n: self.distance_km((lat, lng), PUNE_LOCALITIES[n]))


class GoogleMaps(MapsService):
    def __init__(self, api_key: str):
        import httpx
        if not api_key:
            raise RuntimeError("GOOGLE_MAPS_API_KEY missing")
        self.http, self.key = httpx.Client(timeout=10), api_key

    def geocode(self, query):
        res = self.http.get("https://maps.googleapis.com/maps/api/geocode/json",
                            params={"address": query, "key": self.key, "region": "in"}).json()["results"]
        return (res[0]["geometry"]["location"]["lat"], res[0]["geometry"]["location"]["lng"]) if res else None

    def reverse_locality(self, lat, lng):
        res = self.http.get("https://maps.googleapis.com/maps/api/geocode/json",
                            params={"latlng": f"{lat},{lng}", "key": self.key,
                                    "result_type": "sublocality|locality"}).json()["results"]
        return res[0]["address_components"][0]["long_name"] if res else None


# ---------------------------------------------------------------- Realtime
class RealtimeService(ABC):
    @abstractmethod
    def publish(self, channel: str, event: str, payload: dict) -> None: ...


class MockRealtime(RealtimeService):
    def __init__(self):
        self.events: deque = deque(maxlen=200)

    def publish(self, channel, event, payload):
        self.events.append({"channel": channel, "event": event, "payload": payload})
