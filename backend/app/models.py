"""All persistent entities. Money columns are integer PAISE (suffix _paise).

Additions beyond the written spec (each noted inline): OtpCode, ChatMessage, PriceHistory,
audio moderation flags on WorkItem, and rating sub-scores for the worker→customer direction.
"""
import uuid
from datetime import date, datetime

from sqlalchemy import (
    BigInteger, Boolean, Date, DateTime, Enum, Float, ForeignKey, Index, Integer, SmallInteger,
    String, Text, UniqueConstraint, func,
)
from sqlalchemy.dialects.postgresql import ARRAY, JSONB
from sqlalchemy.orm import Mapped, mapped_column, relationship

from .crypto import EncryptedString
from .db import Base
from .enums import (
    AudioUploadState, BidStatus, CustomerType, DisputeStatus, DocStatus, EscrowState, JobStatus,
    RatingDirection, Role, SupportChannel, TicketStatus, Trade,
)


def _pk() -> Mapped[uuid.UUID]:
    return mapped_column(primary_key=True, default=uuid.uuid4)


def _created() -> Mapped[datetime]:
    return mapped_column(DateTime(timezone=True), server_default=func.now(), nullable=False)


def _enum(e):  # store enum *values* as native PG enums with stable names
    return Enum(e, name=e.__name__.lower(), values_callable=lambda x: [m.value for m in x])


class User(Base):
    __tablename__ = "users"
    id: Mapped[uuid.UUID] = _pk()
    phone: Mapped[str] = mapped_column(String(15), unique=True, index=True)
    role: Mapped[Role] = mapped_column(_enum(Role))
    name: Mapped[str | None] = mapped_column(String(120))
    language_code: Mapped[str] = mapped_column(String(5), default="hi")
    kyc_level: Mapped[int] = mapped_column(SmallInteger, default=0)  # 0 phone | 1 name+selfie+UPI | 2 Aadhaar/PAN
    created_at: Mapped[datetime] = _created()

    worker_profile: Mapped["WorkerProfile | None"] = relationship(back_populates="user", uselist=False)
    customer_profile: Mapped["CustomerProfile | None"] = relationship(back_populates="user", uselist=False)


class OtpCode(Base):  # addition: backing store for the OTP stub (hash only, never plaintext)
    __tablename__ = "otp_codes"
    id: Mapped[uuid.UUID] = _pk()
    phone: Mapped[str] = mapped_column(String(15), index=True)
    code_hash: Mapped[str] = mapped_column(String(128))
    expires_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    attempts: Mapped[int] = mapped_column(SmallInteger, default=0)
    consumed: Mapped[bool] = mapped_column(Boolean, default=False)
    created_at: Mapped[datetime] = _created()


class WorkerProfile(Base):
    __tablename__ = "worker_profiles"
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    trades: Mapped[list[str]] = mapped_column(ARRAY(String(20)), default=list)
    selfie_url: Mapped[str | None] = mapped_column(String(500))  # storage KEY, never a public URL
    upi_id: Mapped[str | None] = mapped_column(EncryptedString(400))  # encrypted at rest
    aadhaar_status: Mapped[DocStatus] = mapped_column(_enum(DocStatus), default=DocStatus.not_submitted)
    pan_status: Mapped[DocStatus] = mapped_column(_enum(DocStatus), default=DocStatus.not_submitted)
    eshram_id: Mapped[str | None] = mapped_column(EncryptedString(300))  # encrypted at rest
    # NOTE: Aadhaar/PAN *numbers* are never stored — only verification status (UIDAI rules).
    badges: Mapped[list[str]] = mapped_column(ARRAY(String(40)), default=list)
    overall_rating: Mapped[float] = mapped_column(Float, default=0.0)
    rating_count: Mapped[int] = mapped_column(Integer, default=0)
    is_suspended: Mapped[bool] = mapped_column(Boolean, default=False)
    # additions: feed distance, online KPI, KYC-cap tracking
    home_lat: Mapped[float | None] = mapped_column(Float)
    home_lng: Mapped[float | None] = mapped_column(Float)
    city: Mapped[str | None] = mapped_column(String(60))
    is_online: Mapped[bool] = mapped_column(Boolean, default=False)
    completed_jobs: Mapped[int] = mapped_column(Integer, default=0)
    lifetime_earnings_paise: Mapped[int] = mapped_column(BigInteger, default=0)
    # Level-2 KYC document (image key in private storage; the NUMBER is never stored)
    kyc_doc_type: Mapped[str | None] = mapped_column(String(10))  # aadhaar | pan
    kyc_doc_key: Mapped[str | None] = mapped_column(String(500))
    kyc_note: Mapped[str | None] = mapped_column(String(300))  # rejection reason shown to worker
    strikes: Mapped[int] = mapped_column(SmallInteger, default=0)  # no-shows / penalties

    user: Mapped[User] = relationship(back_populates="worker_profile")


class CustomerProfile(Base):
    __tablename__ = "customer_profiles"
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id", ondelete="CASCADE"), primary_key=True)
    type: Mapped[CustomerType] = mapped_column(_enum(CustomerType), default=CustomerType.homeowner)
    org_name: Mapped[str | None] = mapped_column(String(160))
    overall_rating: Mapped[float] = mapped_column(Float, default=0.0)  # addition: two-way ratings
    rating_count: Mapped[int] = mapped_column(Integer, default=0)

    user: Mapped[User] = relationship(back_populates="customer_profile")


class Job(Base):
    __tablename__ = "jobs"
    id: Mapped[uuid.UUID] = _pk()
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), index=True)
    location_lat: Mapped[float] = mapped_column(Float)
    location_lng: Mapped[float] = mapped_column(Float)
    address_text: Mapped[str] = mapped_column(String(300))
    city: Mapped[str] = mapped_column(String(60), index=True)
    locality: Mapped[str] = mapped_column(String(80), index=True)
    start_date: Mapped[date] = mapped_column(Date)
    status: Mapped[JobStatus] = mapped_column(_enum(JobStatus), default=JobStatus.open, index=True)
    created_at: Mapped[datetime] = _created()

    work_items: Mapped[list["WorkItem"]] = relationship(back_populates="job", order_by="WorkItem.sort_order",
                                                        cascade="all, delete-orphan")
    bids: Mapped[list["Bid"]] = relationship(back_populates="job")


class WorkItem(Base):
    __tablename__ = "work_items"
    id: Mapped[uuid.UUID] = _pk()
    job_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("jobs.id", ondelete="CASCADE"), index=True)
    sort_order: Mapped[int] = mapped_column(SmallInteger, default=0)  # "Work 1, Work 2…"
    trade: Mapped[Trade] = mapped_column(_enum(Trade))
    text_description: Mapped[str | None] = mapped_column(Text)
    transcript: Mapped[str | None] = mapped_column(Text)  # customer-reviewed STT output
    description_language: Mapped[str] = mapped_column(String(5), default="hi")
    # cache of machine translations: {"ta": "...", "bn": "..."} keyed by language
    translations: Mapped[dict] = mapped_column(JSONB, default=dict)
    audio_url: Mapped[str | None] = mapped_column(String(500))  # storage KEY (signed on read)
    audio_duration_sec: Mapped[int | None] = mapped_column(SmallInteger)
    audio_size_bytes: Mapped[int | None] = mapped_column(Integer)  # addition: feed data-size hint
    audio_upload_state: Mapped[AudioUploadState | None] = mapped_column(_enum(AudioUploadState))
    audio_flagged: Mapped[bool] = mapped_column(Boolean, default=False)  # addition: moderation
    audio_muted: Mapped[bool] = mapped_column(Boolean, default=False)    # hidden from worker feed

    job: Mapped[Job] = relationship(back_populates="work_items")
    photos: Mapped[list["WorkItemPhoto"]] = relationship(order_by="WorkItemPhoto.sort_order",
                                                         cascade="all, delete-orphan")


class WorkItemPhoto(Base):
    __tablename__ = "work_item_photos"
    id: Mapped[uuid.UUID] = _pk()
    work_item_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("work_items.id", ondelete="CASCADE"), index=True)
    photo_url: Mapped[str] = mapped_column(String(500))
    sort_order: Mapped[int] = mapped_column(SmallInteger, default=0)


class Bid(Base):
    __tablename__ = "bids"
    __table_args__ = (UniqueConstraint("job_id", "worker_id", name="uq_bid_job_worker"),)
    id: Mapped[uuid.UUID] = _pk()
    job_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("jobs.id"), index=True)
    worker_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), index=True)
    quoted_price_paise: Mapped[int] = mapped_column(BigInteger)
    status: Mapped[BidStatus] = mapped_column(_enum(BidStatus), default=BidStatus.pending)
    client_ref: Mapped[str | None] = mapped_column(String(64), unique=True)  # addition: offline idempotency key
    created_at: Mapped[datetime] = _created()

    job: Mapped[Job] = relationship(back_populates="bids")
    worker: Mapped[User] = relationship()


class Assignment(Base):
    __tablename__ = "assignments"
    id: Mapped[uuid.UUID] = _pk()
    job_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("jobs.id"), unique=True)
    worker_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), index=True)
    accepted_bid_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("bids.id"))
    escrow_status: Mapped[EscrowState] = mapped_column(_enum(EscrowState), default=EscrowState.created)
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    # Live tracking: worker taps "I'm on my way" → phone shares location → customer sees ETA.
    journey_started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    worker_lat: Mapped[float | None] = mapped_column(Float)
    worker_lng: Mapped[float | None] = mapped_column(Float)
    worker_loc_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    worker_done_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # worker says "finished"

    job: Mapped[Job] = relationship()
    worker: Mapped[User] = relationship()


class Attendance(Base):
    __tablename__ = "attendance"
    id: Mapped[uuid.UUID] = _pk()
    assignment_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("assignments.id"), index=True)
    checkin_at: Mapped[datetime] = mapped_column(DateTime(timezone=True))
    checkin_lat: Mapped[float] = mapped_column(Float)
    checkin_lng: Mapped[float] = mapped_column(Float)
    checkin_selfie_url: Mapped[str | None] = mapped_column(String(500))
    checkout_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    checkout_lat: Mapped[float | None] = mapped_column(Float)
    checkout_lng: Mapped[float | None] = mapped_column(Float)
    geofence_ok: Mapped[bool] = mapped_column(Boolean, default=True)  # within radius of the job site
    offline_synced: Mapped[bool] = mapped_column(Boolean, default=False)  # True = captured offline, synced later
    client_ref: Mapped[str | None] = mapped_column(String(64), unique=True)  # idempotent offline replay


class Rating(Base):
    __tablename__ = "ratings"
    __table_args__ = (UniqueConstraint("assignment_id", "direction", name="uq_rating_once_per_direction"),)
    id: Mapped[uuid.UUID] = _pk()
    assignment_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("assignments.id"), index=True)
    direction: Mapped[RatingDirection] = mapped_column(_enum(RatingDirection))
    rater_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"))
    ratee_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), index=True)
    # customer → worker
    quality: Mapped[int | None] = mapped_column(SmallInteger)
    timeliness: Mapped[int | None] = mapped_column(SmallInteger)
    behaviour: Mapped[int | None] = mapped_column(SmallInteger)
    value_for_money: Mapped[int | None] = mapped_column(SmallInteger)
    # worker → customer (addition per spec C5 two-way)
    clarity: Mapped[int | None] = mapped_column(SmallInteger)
    timely_payment: Mapped[int | None] = mapped_column(SmallInteger)
    overall: Mapped[float] = mapped_column(Float)  # computed server-side, never trusted from client
    comment: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = _created()


class Payment(Base):
    __tablename__ = "payments"
    id: Mapped[uuid.UUID] = _pk()
    assignment_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("assignments.id"), unique=True)
    amount_paise: Mapped[int] = mapped_column(BigInteger)          # total charged to customer
    platform_fee_paise: Mapped[int] = mapped_column(BigInteger)    # flat fee + take-rate
    worker_payout_paise: Mapped[int] = mapped_column(BigInteger)
    escrow_state: Mapped[EscrowState] = mapped_column(_enum(EscrowState), default=EscrowState.created)
    razorpay_ref: Mapped[str | None] = mapped_column(String(80))       # order id
    transfer_ref: Mapped[str | None] = mapped_column(String(80))       # Route on-hold transfer id
    released_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    method: Mapped[str | None] = mapped_column(String(20))       # upi | card | netbanking
    paid_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    refund_paise: Mapped[int] = mapped_column(BigInteger, default=0)  # used by refund/split


class Payout(Base):  # addition: worker withdrawals of released earnings to UPI
    __tablename__ = "payouts"
    id: Mapped[uuid.UUID] = _pk()
    worker_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), index=True)
    amount_paise: Mapped[int] = mapped_column(BigInteger)
    upi_masked: Mapped[str] = mapped_column(String(120))
    status: Mapped[str] = mapped_column(String(20), default="processed")  # processed | failed
    provider_ref: Mapped[str | None] = mapped_column(String(80))
    created_at: Mapped[datetime] = _created()


class Dispute(Base):
    __tablename__ = "disputes"
    id: Mapped[uuid.UUID] = _pk()
    assignment_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("assignments.id"), index=True)
    raised_by: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"))
    reason: Mapped[str] = mapped_column(Text)
    evidence_refs: Mapped[list[str]] = mapped_column(ARRAY(String(500)), default=list)
    status: Mapped[DisputeStatus] = mapped_column(_enum(DisputeStatus), default=DisputeStatus.open)
    resolution: Mapped[str | None] = mapped_column(Text)
    resolved_by: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id"))
    resolved_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))
    created_at: Mapped[datetime] = _created()


class ChatMessage(Base):  # addition: chat logs are dispute evidence (A4)
    __tablename__ = "chat_messages"
    id: Mapped[uuid.UUID] = _pk()
    job_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("jobs.id"), index=True)
    sender_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"))
    recipient_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"))
    body: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = _created()
    read_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True))  # set when the recipient opens the thread


class SupportTicket(Base):
    __tablename__ = "support_tickets"
    id: Mapped[uuid.UUID] = _pk()
    user_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("users.id"), index=True)
    channel: Mapped[SupportChannel] = mapped_column(_enum(SupportChannel))
    subject: Mapped[str] = mapped_column(String(200))
    status: Mapped[TicketStatus] = mapped_column(_enum(TicketStatus), default=TicketStatus.open)
    transcript: Mapped[str | None] = mapped_column(Text)
    created_at: Mapped[datetime] = _created()


class PriceHistory(Base):  # addition: feeds the C2 Step 4 Fair Price Estimate
    __tablename__ = "price_history"
    __table_args__ = (Index("ix_price_trade_locality", "trade", "city", "locality"),)
    id: Mapped[uuid.UUID] = _pk()
    trade: Mapped[Trade] = mapped_column(_enum(Trade))
    city: Mapped[str] = mapped_column(String(60))
    locality: Mapped[str] = mapped_column(String(80))
    price_paise: Mapped[int] = mapped_column(BigInteger)
    work_summary: Mapped[str | None] = mapped_column(String(200))
    completed_on: Mapped[date] = mapped_column(Date)


class AuditLog(Base):
    __tablename__ = "audit_logs"
    id: Mapped[uuid.UUID] = _pk()
    actor_id: Mapped[uuid.UUID | None] = mapped_column(ForeignKey("users.id"))  # None = system
    action: Mapped[str] = mapped_column(String(80), index=True)
    entity: Mapped[str] = mapped_column(String(40), index=True)
    entity_id: Mapped[str] = mapped_column(String(64), index=True)
    meta: Mapped[dict] = mapped_column("metadata", JSONB, default=dict)  # "metadata" is reserved on Base
    created_at: Mapped[datetime] = _created()
