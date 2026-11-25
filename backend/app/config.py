"""Central configuration. Every business knob lives here and is overridable via env vars.

Money is stored in PAISE (integer) everywhere to avoid float rounding; config is in rupees
for readability and converted at the edge.
"""
from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    env: str = "dev"  # dev | staging | prod
    database_url: str = "postgresql+psycopg://postgres:postgres@localhost:5432/buildcrew"
    jwt_secret: str = "dev-only-change-me-0123456789abcdef0123"
    # Fernet key for field-level encryption of PII (UPI ID, eShram ID). Generate with:
    #   python -c "from cryptography.fernet import Fernet;print(Fernet.generate_key().decode())"
    data_encryption_key: str = "xY3v0J6m1dU6Qm0uVZr1o7mJ0pS9x3c2HkzPqM8nE1Q="  # dev only
    otp_requests_per_hour: int = 5
    jwt_ttl_hours: int = 24 * 30  # workers on shared phones shouldn't re-login often
    public_base_url: str = "http://localhost:8000"
    cors_origins: str = "http://localhost:5173,http://localhost:3000"

    # --- Auth / OTP -------------------------------------------------------------------
    otp_ttl_seconds: int = 300
    otp_resend_after_seconds: int = 30
    otp_max_attempts: int = 5
    dev_fixed_otp: str = "123456"  # only honoured when env == "dev"

    # --- Fees (owner spec: nominal ₹30 per job + optional % take rate) ----------------
    # Assumption: the flat fee is charged to the customer on top of the quote; the take
    # rate (default 0%) is deducted from the worker's quote. Both are config-driven.
    platform_fee_flat_inr: int = 30
    platform_take_rate_pct: float = 0.0

    # --- Progressive KYC ----------------------------------------------------------------
    # Level 2 (Aadhaar/PAN) is demanded only when lifetime earnings approach this cap.
    kyc_l2_earnings_cap_inr: int = 50_000
    kyc_l2_prompt_ratio: float = 0.8  # start nudging at 80% of the cap
    # Progressive KYC: a phone-verified (L0) worker can browse, listen and BID. Level 1
    # (name+selfie+UPI) is asked only once a customer accepts his bid — i.e. when there is money
    # to send him. Level 2 only near the earnings cap.
    kyc_l1_required_before_assignment: bool = True

    # --- Audio ------------------------------------------------------------------------
    audio_max_seconds: int = 120
    audio_soft_prompt_seconds: int = 60
    audio_target_kbps: int = 20  # Opus voice profile, 16–24 kbps band
    signed_url_ttl_seconds: int = 600
    worker_feed_radius_km: float = 15.0

    # --- Adapters (swap "mock" for real providers; see README) -------------------------
    payment_provider: str = "mock"        # mock | razorpay
    translation_provider: str = "mock"    # mock | bhashini | google
    speech_provider: str = "mock"         # mock | bhashini | google
    storage_provider: str = "local"       # local | s3 (MinIO / AWS / GCS-interop)
    sms_provider: str = "dev"             # dev | msg91
    maps_provider: str = "mock"           # mock | google

    razorpay_key_id: str = ""
    razorpay_key_secret: str = ""
    razorpay_webhook_secret: str = ""
    bhashini_user_id: str = ""
    bhashini_api_key: str = ""
    bhashini_pipeline_id: str = ""
    google_api_key: str = ""
    google_maps_api_key: str = ""
    msg91_auth_key: str = ""

    local_storage_dir: str = "./var/storage"
    s3_endpoint: str = "http://minio:9000"
    s3_bucket: str = "buildcrew-media"
    s3_access_key: str = "minioadmin"
    s3_secret_key: str = "minioadmin"

    @property
    def is_dev(self) -> bool:
        return self.env == "dev"

    @property
    def platform_fee_flat_paise(self) -> int:
        return self.platform_fee_flat_inr * 100

    @property
    def kyc_l2_cap_paise(self) -> int:
        return self.kyc_l2_earnings_cap_inr * 100


@lru_cache
def get_settings() -> Settings:
    return Settings()
