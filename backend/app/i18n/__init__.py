"""Server-side strings: errors, SMS, support auto-replies, voice-query answers.

Rule: the backend NEVER returns a user-facing English sentence to a non-English user if a
translation exists. Scaffolded languages hold `null` for untranslated keys; those fall back to
English and are reported by `missing_keys()` (Phase 6 completeness check fails CI on any null).
"""
import json
import logging
from functools import lru_cache
from pathlib import Path

from ..enums import LANGUAGE_CODES

log = logging.getLogger(__name__)
_DIR = Path(__file__).parent / "locales"
FALLBACK = "en"


@lru_cache
def bundle(lang: str) -> dict[str, str | None]:
    path = _DIR / f"{lang}.json"
    return json.loads(path.read_text("utf-8")) if path.exists() else {}


def t(key: str, lang: str | None, **params) -> str:
    lang = lang if lang in LANGUAGE_CODES else FALLBACK
    text = bundle(lang).get(key)
    if text is None:
        if lang != FALLBACK:
            log.warning("i18n: missing %s for %s, falling back", key, lang)
        text = bundle(FALLBACK).get(key, key)
    try:
        return text.format(**params)
    except (KeyError, IndexError):
        return text


def missing_keys() -> dict[str, list[str]]:
    ref = set(bundle(FALLBACK))
    return {lang: sorted(k for k in ref if bundle(lang).get(k) is None) for lang in LANGUAGE_CODES}


def pick_lang(user_lang: str | None, accept_language: str | None) -> str:
    """User's saved language wins; else first supported Accept-Language tag; else Hindi."""
    if user_lang in LANGUAGE_CODES:
        return user_lang
    for part in (accept_language or "").split(","):
        code = part.split(";")[0].strip().lower()[:2]
        if code in LANGUAGE_CODES:
            return code
    return "hi"
