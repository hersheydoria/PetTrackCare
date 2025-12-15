import uuid
from datetime import datetime

from sqlalchemy import (
    Boolean,
    CheckConstraint,
    Column,
    Date,
    DateTime,
    Float,
    ForeignKey,
    Integer,
    JSON,
    Numeric,
    String,
    Text,
    func,
)
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import relationship

from .base import Base


class User(Base):
    __tablename__ = "users"
    __table_args__ = (
        CheckConstraint(
            "role IN ('Pet Owner', 'Pet Sitter', 'Admin')",
            name="users_role_check",
        ),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    email = Column(String(255), unique=True, index=True, nullable=False)
    password_hash = Column(String(255), nullable=True)
    role = Column(String(64), nullable=False, server_default="Pet Owner")
    name = Column(String(255))
    profile_picture = Column(String(255))
    status = Column(String(64))
    address = Column(String(255))
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now(), nullable=False)

    pets = relationship("Pet", back_populates="owner", cascade="all, delete-orphan")
    posts = relationship("Post", back_populates="owner")
    notifications = relationship("Notification", back_populates="recipient")
    sitter_profile = relationship("Sitter", back_populates="user", uselist=False)
    behavior_logs = relationship("BehaviorLog", back_populates="user")
    community_posts = relationship("CommunityPost", back_populates="user", cascade="all, delete-orphan")
    community_comments = relationship("Comment", back_populates="user", cascade="all, delete-orphan")
    bookmarks = relationship("Bookmark", back_populates="user", cascade="all, delete-orphan")

    @property
    def display_name(self) -> str:
        return (self.name or self.email or "").strip()


class Pet(Base):
    __tablename__ = "pets"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id = Column(UUID(as_uuid=True), ForeignKey("users.id", ondelete="CASCADE"), nullable=False)
    name = Column(String(128), nullable=False)
    breed = Column(String(64), nullable=False)
    health = Column(Text, nullable=False)
    profile_picture = Column(String(255), nullable=False)
    type = Column(String(64), nullable=False)
    gender = Column(String(16), nullable=False)
    date_of_birth = Column(DateTime(timezone=True), nullable=True)
    weight = Column(Numeric(5, 2), nullable=False)
    is_missing = Column(Boolean)
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=False)
    updated_at = Column(DateTime(timezone=True), server_default=func.now(), onupdate=func.now(), nullable=False)

    owner = relationship("User", back_populates="pets")
    locations = relationship("LocationHistory", back_populates="pet")
    sitting_jobs = relationship("SittingJob", back_populates="pet")
    behavior_logs = relationship("BehaviorLog", back_populates="pet")


class Post(Base):
    __tablename__ = "posts"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    owner_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    title = Column(String(255))
    content = Column(Text)
    media_url = Column(String(255))
    metadata_payload = Column("metadata", JSON, default=dict)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now(), nullable=False)

    owner = relationship("User", back_populates="posts")

class Notification(Base):
    __tablename__ = "notifications"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    actor_id = Column(UUID(as_uuid=True))
    post_id = Column(UUID(as_uuid=True))
    job_id = Column(UUID(as_uuid=True))
    comment_id = Column(UUID(as_uuid=True), ForeignKey("comments.id"))
    message = Column(Text)
    type = Column(String(64))
    is_read = Column(Boolean, default=False)
    metadata_payload = Column("metadata", JSON, default=dict)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now(), nullable=False)

    recipient = relationship("User", back_populates="notifications")
    comment = relationship("Comment", foreign_keys=[comment_id])


class LocationHistory(Base):
    __tablename__ = "location_history"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    pet_id = Column(UUID(as_uuid=True), ForeignKey("pets.id"), nullable=True)
    device_mac = Column(String(64), nullable=True, index=True)
    latitude = Column(Float, nullable=False)
    longitude = Column(Float, nullable=False)
    timestamp = Column(DateTime(timezone=True), nullable=True, server_default=func.now())

    pet = relationship("Pet", back_populates="locations")


class Message(Base):
    __tablename__ = "messages"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    sender_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    receiver_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    content = Column(Text, nullable=False)
    sent_at = Column(DateTime, server_default=func.now(), nullable=False)
    is_seen = Column(Boolean, default=False)
    is_typing = Column(Boolean)
    media_url = Column(String(255))
    metadata_payload = Column("metadata", JSON, default=dict)
    type = Column(String(64))
    call_id = Column(String(255))
    call_mode = Column(String(64))
    reply_to_content = Column(Text)
    reply_to_message_id = Column(UUID(as_uuid=True))
    reply_to_sender_id = Column(UUID(as_uuid=True))

    sender = relationship("User", foreign_keys=[sender_id])
    receiver = relationship("User", foreign_keys=[receiver_id])

    @property
    def recipient_id(self):
        return self.receiver_id

    @recipient_id.setter
    def recipient_id(self, value):
        self.receiver_id = value


class CommunityPost(Base):
    __tablename__ = "community_posts"
    __table_args__ = (
        CheckConstraint(
            "type IN ('general', 'missing', 'found')",
            name="community_posts_type_check",
        ),
    )

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    type = Column(String(32), nullable=False)
    content = Column(Text, nullable=False)
    image_url = Column(String(255))
    reported = Column(Boolean, default=False)
    latitude = Column(String(64))
    longitude = Column(String(64))
    address = Column(String(255))
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now(), nullable=False)

    user = relationship("User", back_populates="community_posts")
    comments = relationship("Comment", back_populates="post", cascade="all, delete-orphan")
    likes = relationship("CommunityLike", back_populates="post", cascade="all, delete-orphan")
    bookmarks = relationship("Bookmark", back_populates="post", cascade="all, delete-orphan")
    reports = relationship("Report", back_populates="post", cascade="all, delete-orphan")


class Comment(Base):
    __tablename__ = "comments"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    post_id = Column(UUID(as_uuid=True), ForeignKey("community_posts.id"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    content = Column(Text, nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    post = relationship("CommunityPost", back_populates="comments")
    user = relationship("User", back_populates="community_comments")
    likes = relationship("CommentLike", back_populates="comment", cascade="all, delete-orphan")
    replies = relationship("Reply", back_populates="comment", cascade="all, delete-orphan")


class CommentLike(Base):
    __tablename__ = "comment_likes"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    comment_id = Column(UUID(as_uuid=True), ForeignKey("comments.id"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    comment = relationship("Comment", back_populates="likes")
    user = relationship("User")


class Reply(Base):
    __tablename__ = "replies"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    comment_id = Column(UUID(as_uuid=True), ForeignKey("comments.id"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    content = Column(Text, nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    comment = relationship("Comment", back_populates="replies")
    user = relationship("User")


class CommunityLike(Base):
    __tablename__ = "likes"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    post_id = Column(UUID(as_uuid=True), ForeignKey("community_posts.id"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    post = relationship("CommunityPost", back_populates="likes")
    user = relationship("User")


class Bookmark(Base):
    __tablename__ = "bookmarks"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    post_id = Column(UUID(as_uuid=True), ForeignKey("community_posts.id"), nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    user = relationship("User", back_populates="bookmarks")
    post = relationship("CommunityPost", back_populates="bookmarks")


class Report(Base):
    __tablename__ = "reports"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    post_id = Column(UUID(as_uuid=True), ForeignKey("community_posts.id"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    reason = Column(Text, nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    post = relationship("CommunityPost", back_populates="reports")
    user = relationship("User")


class Sitter(Base):
    __tablename__ = "sitters"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False, unique=True)
    bio = Column(Text)
    experience = Column(Integer, default=0)
    is_available = Column(Boolean, default=True)
    hourly_rate = Column(Float)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    user = relationship("User", back_populates="sitter_profile")
    reviews = relationship("SitterReview", back_populates="sitter", cascade="all, delete-orphan")


class SitterReview(Base):
    __tablename__ = "sitter_reviews"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    sitter_id = Column(UUID(as_uuid=True), ForeignKey("sitters.id"), nullable=False)
    reviewer_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    rating = Column(Integer)
    comment = Column(Text)
    owner_name = Column(String(255))
    created_at = Column(DateTime, server_default=func.now(), nullable=False)

    sitter = relationship("Sitter", back_populates="reviews")
    reviewer = relationship("User", foreign_keys=[reviewer_id])


class SittingJob(Base):
    __tablename__ = "sitting_jobs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    __table_args__ = (
        CheckConstraint(
            "status IN ('Pending', 'Active', 'Completed', 'Cancelled')",
            name="sitting_jobs_status_check",
        ),
    )

    sitter_id = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    pet_id = Column(UUID(as_uuid=True), ForeignKey("pets.id"), nullable=False)
    start_date = Column(Date, nullable=False)
    end_date = Column(Date)
    status = Column(String(64), server_default="Pending")
    created_at = Column(DateTime(timezone=True), server_default=func.now(), nullable=True)

    sitter = relationship("User", foreign_keys=[sitter_id])
    pet = relationship("Pet", back_populates="sitting_jobs")


class BehaviorLog(Base):
    __tablename__ = "behavior_logs"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    pet_id = Column(UUID(as_uuid=True), ForeignKey("pets.id"), nullable=False)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), nullable=False)
    log_date = Column(Date, nullable=False)
    activity_level = Column(String(64))
    food_intake = Column(String(64))
    water_intake = Column(String(64))
    bathroom_habits = Column(String(64))
    symptoms = Column(Text)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    updated_at = Column(DateTime, server_default=func.now(), onupdate=func.now(), nullable=False)

    pet = relationship("Pet", back_populates="behavior_logs")
    user = relationship("User", back_populates="behavior_logs")


class DevicePetMap(Base):
    __tablename__ = "device_pet_map"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    device_id = Column(String(255), nullable=False, unique=True)
    pet_id = Column(UUID(as_uuid=True), ForeignKey("pets.id"), unique=True)

    pet = relationship("Pet")


class Feedback(Base):
    __tablename__ = "feedback"

    id = Column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"))
    message = Column(Text, nullable=False)
    created_at = Column(DateTime, server_default=func.now(), nullable=False)
    archived = Column(Boolean, default=False)
    is_read = Column(Boolean, default=False)

    user = relationship("User")


class TypingStatus(Base):
    __tablename__ = "typing_status"

    user_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), primary_key=True)
    chat_with_id = Column(UUID(as_uuid=True), ForeignKey("users.id"), primary_key=True)
    is_typing = Column(Boolean, default=False, nullable=False)

    user = relationship("User", foreign_keys=[user_id])
    chat_with = relationship("User", foreign_keys=[chat_with_id])

def _attach_metadata_property(cls, attr_name: str) -> None:
    def getter(self):
        return getattr(self, attr_name)

    def setter(self, value):
        setattr(self, attr_name, value)

    setattr(cls, "metadata", property(getter, setter))


for _cls in (Post, Notification, Message):
    _attach_metadata_property(_cls, "metadata_payload")
