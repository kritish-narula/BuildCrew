"""Hinglish (en_IN, Hindi in Roman script) server strings."""
import re

from app.i18n import bundle, canon, missing_keys, pick_lang, t

DEVANAGARI = re.compile(r"[ऀ-ॿ]")
PLACEHOLDER = re.compile(r"\{(\w+)\}")


def test_en_in_bundle_complete_and_roman_only():
    en, hing = bundle("en"), bundle("en_IN")
    assert set(hing) == set(en)
    assert all(v for v in hing.values())
    assert not [k for k, v in hing.items() if DEVANAGARI.search(v)]
    assert missing_keys()["en_IN"] == []


def test_en_in_placeholders_match_english():
    en, hing = bundle("en"), bundle("en_IN")
    for k in en:
        assert sorted(PLACEHOLDER.findall(hing[k])) == sorted(PLACEHOLDER.findall(en[k])), k


def test_en_in_error_differs_from_english_and_accepts_both_spellings():
    msg = t("err.unauthorized", "en_IN")
    assert msg != t("err.unauthorized", "en")
    assert msg == t("err.unauthorized", "en-IN") == t("err.unauthorized", "en_in")
    assert not DEVANAGARI.search(msg)


def test_en_in_user_language_is_kept_but_accept_language_stays_english():
    assert canon("en-IN") == "en_IN"
    assert pick_lang("en-IN", None) == "en_IN"
    assert pick_lang(None, "en-IN,en;q=0.9") == "en"
