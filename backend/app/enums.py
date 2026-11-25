import enum


class Role(str, enum.Enum):
    worker = "worker"
    customer = "customer"
    admin = "admin"


class CustomerType(str, enum.Enum):
    homeowner = "homeowner"
    contractor = "contractor"


class Trade(str, enum.Enum):
    mason = "mason"
    plumber = "plumber"
    electrician = "electrician"
    carpenter = "carpenter"
    painter = "painter"
    helper = "helper"


class DocStatus(str, enum.Enum):
    not_submitted = "not_submitted"
    pending = "pending"
    approved = "approved"
    rejected = "rejected"


class JobStatus(str, enum.Enum):
    open = "open"
    bidding = "bidding"
    assigned = "assigned"
    in_progress = "in_progress"
    completed = "completed"
    disputed = "disputed"
    cancelled = "cancelled"


class AudioUploadState(str, enum.Enum):
    pending = "pending"
    uploaded = "uploaded"


class BidStatus(str, enum.Enum):
    pending = "pending"
    accepted = "accepted"
    rejected = "rejected"
    withdrawn = "withdrawn"


class EscrowState(str, enum.Enum):
    created = "created"     # order created, customer not yet paid
    held = "held"           # money captured into escrow (Razorpay Route on_hold transfer)
    released = "released"   # paid out to worker
    refunded = "refunded"   # returned to customer
    split = "split"         # admin dispute resolution: part worker, part customer


class RatingDirection(str, enum.Enum):
    customer_to_worker = "customer_to_worker"
    worker_to_customer = "worker_to_customer"


class DisputeStatus(str, enum.Enum):
    open = "open"
    under_review = "under_review"
    resolved = "resolved"


class SupportChannel(str, enum.Enum):
    app = "app"
    whatsapp = "whatsapp"
    voice = "voice"


class TicketStatus(str, enum.Enum):
    open = "open"
    pending_user = "pending_user"
    closed = "closed"


LANGUAGES: list[dict] = [
    # code, native label, English name. Order = order on the S1 Language Select screen.
    {"code": "hi", "native": "हिन्दी", "english": "Hindi"},
    {"code": "bn", "native": "বাংলা", "english": "Bengali"},
    {"code": "te", "native": "తెలుగు", "english": "Telugu"},
    {"code": "mr", "native": "मराठी", "english": "Marathi"},
    {"code": "ta", "native": "தமிழ்", "english": "Tamil"},
    {"code": "gu", "native": "ગુજરાતી", "english": "Gujarati"},
    {"code": "kn", "native": "ಕನ್ನಡ", "english": "Kannada"},
    {"code": "ml", "native": "മലയാളം", "english": "Malayalam"},
    {"code": "or", "native": "ଓଡ଼ିଆ", "english": "Odia"},
    {"code": "pa", "native": "ਪੰਜਾਬੀ", "english": "Punjabi"},
    {"code": "as", "native": "অসমীয়া", "english": "Assamese"},
    {"code": "en", "native": "English", "english": "English"},
]
LANGUAGE_CODES = [lang["code"] for lang in LANGUAGES]
