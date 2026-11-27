"""Adapter registry: one place that maps config → implementation. Routers depend on the
abstract interfaces only, so swapping mock → real is a config change, not a code change."""
from functools import lru_cache

from ..config import get_settings
from .infra import DevSmsStub, GoogleMaps, MapsService, MockMaps, MockRealtime, Msg91Sms, RealtimeService, SmsProvider
from .language import BhashiniAdapter, GoogleAdapter, MockSpeech, MockTranslation, SpeechService, TranslationService
from .payout import MockPayoutProvider, PayoutProvider, RazorpayXPayoutProvider, build_payout_provider
from .payment import MockPaymentProvider, PaymentProvider, RazorpayProvider, build_payment_provider
from .push import FcmPush, MockPush, PushProvider
from .storage import LocalStorage, S3Storage, StorageService


@lru_cache
def payment() -> PaymentProvider:
    return build_payment_provider(get_settings())


@lru_cache
def translation() -> TranslationService:
    s = get_settings()
    return {"bhashini": lambda: BhashiniAdapter(s.bhashini_user_id, s.bhashini_api_key, s.bhashini_pipeline_id),
            "google": lambda: GoogleAdapter(s.google_api_key)}.get(s.translation_provider, MockTranslation)()


@lru_cache
def speech() -> SpeechService:
    s = get_settings()
    return {"bhashini": lambda: BhashiniAdapter(s.bhashini_user_id, s.bhashini_api_key, s.bhashini_pipeline_id),
            "google": lambda: GoogleAdapter(s.google_api_key)}.get(s.speech_provider, MockSpeech)()


@lru_cache
def storage() -> StorageService:
    s = get_settings()
    if s.storage_provider == "s3":
        return S3Storage(s.s3_endpoint, s.s3_bucket, s.s3_access_key, s.s3_secret_key)
    return LocalStorage(s.local_storage_dir, s.public_base_url, s.jwt_secret + ":media")


@lru_cache
def sms() -> SmsProvider:
    s = get_settings()
    return Msg91Sms(s.msg91_auth_key) if s.sms_provider == "msg91" else DevSmsStub()


@lru_cache
def maps() -> MapsService:
    s = get_settings()
    return GoogleMaps(s.google_maps_api_key) if s.maps_provider == "google" else MockMaps()


@lru_cache
def realtime() -> RealtimeService:
    return MockRealtime()


@lru_cache
def payouts() -> PayoutProvider:
    return build_payout_provider(get_settings())


@lru_cache
def push() -> PushProvider:
    s = get_settings()
    if s.fcm_service_account_json:
        try:
            return FcmPush(s.fcm_service_account_json)
        except Exception:
            import logging
            logging.getLogger("app.push").exception("FCM_SERVICE_ACCOUNT_JSON invalid; using the mock push provider")
    return MockPush()
