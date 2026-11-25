"""StorageService — media (photos, voice notes, selfies) with signed, time-limited URLs.

Objects are stored under opaque keys (uuid-based, unguessable) and NEVER exposed publicly.
Every read goes through `signed_url()`, which the API only calls after an access-policy check
(see domain/policies.py: audio is visible only to the job's customer, eligible workers, admin).
"""
import hashlib
import hmac
import time
import uuid
from abc import ABC, abstractmethod
from pathlib import Path
from urllib.parse import urlencode


class StorageService(ABC):
    @abstractmethod
    def put(self, data: bytes, *, prefix: str, ext: str, content_type: str) -> str: ...

    @abstractmethod
    def get(self, key: str) -> bytes: ...

    @abstractmethod
    def signed_url(self, key: str, ttl_seconds: int) -> str: ...

    @staticmethod
    def new_key(prefix: str, ext: str) -> str:
        return f"{prefix}/{uuid.uuid4().hex}.{ext.lstrip('.')}"


class LocalStorage(StorageService):
    """Dev adapter: files on disk, served by GET /media/{key}?exp=&sig= with HMAC verification."""

    def __init__(self, root: str, base_url: str, secret: str):
        self.root, self.base_url, self.secret = Path(root), base_url.rstrip("/"), secret.encode()
        self.root.mkdir(parents=True, exist_ok=True)

    def _path(self, key: str) -> Path:
        p = (self.root / key).resolve()
        if not str(p).startswith(str(self.root.resolve())):  # block ../ traversal
            raise ValueError("bad key")
        return p

    def put(self, data, *, prefix, ext, content_type):
        key = self.new_key(prefix, ext)
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return key

    def put_at(self, key: str, data: bytes) -> str:  # seed helper
        path = self._path(key)
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return key

    def get(self, key):
        return self._path(key).read_bytes()

    def _sig(self, key: str, exp: int) -> str:
        return hmac.new(self.secret, f"{key}:{exp}".encode(), hashlib.sha256).hexdigest()

    def signed_url(self, key, ttl_seconds):
        exp = int(time.time()) + ttl_seconds
        return f"{self.base_url}/media/{key}?{urlencode({'exp': exp, 'sig': self._sig(key, exp)})}"

    def verify(self, key: str, exp: int, sig: str) -> str:
        """Returns 'ok' | 'expired' | 'bad'."""
        if not hmac.compare_digest(self._sig(key, exp), sig or ""):
            return "bad"
        return "ok" if exp >= time.time() else "expired"


class S3Storage(StorageService):
    """MinIO locally (docker compose) or AWS S3 / GCS-interop in prod. Bucket must be PRIVATE."""

    def __init__(self, endpoint, bucket, access_key, secret_key):
        import boto3
        self.bucket = bucket
        self.s3 = boto3.client("s3", endpoint_url=endpoint, aws_access_key_id=access_key,
                               aws_secret_access_key=secret_key)

    def put(self, data, *, prefix, ext, content_type):
        key = self.new_key(prefix, ext)
        self.s3.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType=content_type,
                           ServerSideEncryption="AES256")
        return key

    def get(self, key):
        return self.s3.get_object(Bucket=self.bucket, Key=key)["Body"].read()

    def signed_url(self, key, ttl_seconds):
        return self.s3.generate_presigned_url("get_object", Params={"Bucket": self.bucket, "Key": key},
                                              ExpiresIn=ttl_seconds)
