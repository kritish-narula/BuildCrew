"""Field-level encryption for PII columns.

Why: a DB dump / backup leak must not expose workers' UPI IDs or eShram IDs. The DB only ever
sees ciphertext; the key lives in the app's secret store (env var), never in the repo for prod.
"""
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import String
from sqlalchemy.types import TypeDecorator

from .config import get_settings


@lru_cache
def _fernet() -> Fernet:
    return Fernet(get_settings().data_encryption_key.encode())


def encrypt(value: str) -> str:
    return _fernet().encrypt(value.encode()).decode()


def decrypt(token: str) -> str:
    try:
        return _fernet().decrypt(token.encode()).decode()
    except InvalidToken as exc:  # wrong key or tampered row — fail loudly, never return garbage
        raise ValueError("cannot decrypt PII column (check DATA_ENCRYPTION_KEY)") from exc


class EncryptedString(TypeDecorator):
    impl = String
    cache_ok = True

    def process_bind_param(self, value, dialect):
        return None if value is None else encrypt(value)

    def process_result_value(self, value, dialect):
        return None if value is None else decrypt(value)


def mask_upi(upi: str | None) -> str | None:
    """Show 'ra****@okaxis' to anyone but the owner/admin."""
    if not upi or "@" not in upi:
        return upi
    name, bank = upi.split("@", 1)
    return f"{name[:2]}{'*' * max(len(name) - 2, 2)}@{bank}"


def mask_phone(phone: str) -> str:
    return f"{phone[:2]}******{phone[-2:]}" if len(phone) >= 6 else "****"
