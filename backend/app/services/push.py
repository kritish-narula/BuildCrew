"""Push delivery (FCM). Mock by default: logs and records what would be sent.

Enable the real provider by setting `FCM_SERVICE_ACCOUNT_JSON` to the Firebase service-account JSON (either the JSON text
or a path to the file). The mobile app must ALSO ship a Firebase config (google-services.json) and register its token via
`POST /me/push-token`; until then the app falls back to local notifications fired while it is open (see README).
"""
import json
import logging
import time
from abc import ABC, abstractmethod
from pathlib import Path

log = logging.getLogger("app.push")


class PushProvider(ABC):
    @abstractmethod
    def send(self, tokens: list[str], title: str, body: str, data: dict[str, str]) -> list[str]:
        """Deliver to every token. Returns the tokens that are DEAD (unregistered) so the caller can delete them."""


class MockPush(PushProvider):
    def __init__(self):
        self.sent: list[dict] = []

    def send(self, tokens, title, body, data):
        for tk in tokens:
            self.sent.append({"token": tk, "title": title, "body": body, "data": data})
            log.info("push(mock) -> %s...: %s | %s", tk[:8], title, body)
        return []


class FcmPush(PushProvider):
    """FCM HTTP v1. OAuth2 access token from a service-account JWT (RS256); cached for ~55 minutes."""
    SCOPE = "https://www.googleapis.com/auth/firebase.messaging"

    def __init__(self, service_account_json: str, client=None):
        raw = service_account_json.strip()
        self.sa = json.loads(raw if raw.startswith("{") else Path(raw).read_text("utf-8"))
        self.project_id = self.sa["project_id"]
        if client is None:
            import httpx
            client = httpx.Client(timeout=10)
        self.http = client
        self._tok: tuple[str, float] | None = None

    def _access_token(self) -> str:
        if self._tok and self._tok[1] > time.time() + 60:
            return self._tok[0]
        import jwt
        now = int(time.time())
        assertion = jwt.encode({"iss": self.sa["client_email"], "scope": self.SCOPE, "aud": self.sa["token_uri"],
                                "iat": now, "exp": now + 3300}, self.sa["private_key"], algorithm="RS256")
        r = self.http.post(self.sa["token_uri"], data={"grant_type": "urn:ietf:params:oauth:grant-type:jwt-bearer",
                                                        "assertion": assertion})
        r.raise_for_status()
        j = r.json()
        self._tok = (j["access_token"], time.time() + int(j.get("expires_in", 3300)))
        return self._tok[0]

    def send(self, tokens, title, body, data):
        dead: list[str] = []
        url = f"https://fcm.googleapis.com/v1/projects/{self.project_id}/messages:send"
        for tk in tokens:
            msg = {"message": {"token": tk, "notification": {"title": title, "body": body},
                               "data": {k: str(v) for k, v in data.items()},
                               "android": {"priority": "HIGH", "notification": {"channel_id": "buildcrew_updates"}}}}
            try:
                r = self.http.post(url, json=msg, headers={"Authorization": f"Bearer {self._access_token()}"})
                if r.status_code == 404 or (r.status_code == 400 and "UNREGISTERED" in r.text):
                    dead.append(tk)
                elif r.status_code >= 400:
                    log.warning("fcm %s: %s", r.status_code, r.text[:200])
            except Exception:  # push must never break a request
                log.exception("fcm send failed")
        return dead
