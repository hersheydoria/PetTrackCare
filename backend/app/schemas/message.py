from typing import Dict, Optional

from pydantic import BaseModel, ConfigDict, Field


class MessageBase(BaseModel):
    receiver_id: str
    content: str
    metadata: Dict[str, str] = Field(default_factory=dict)


class MessageCreate(MessageBase):
    type: Optional[str] = None
    media_url: Optional[str] = None
    call_id: Optional[str] = None
    call_mode: Optional[str] = None
    reply_to_message_id: Optional[str] = None
    reply_to_sender_id: Optional[str] = None
    reply_to_content: Optional[str] = None


class MessageRead(MessageBase):
    id: str
    sender_id: str
    is_seen: bool
    sent_at: str
    type: Optional[str] = None
    media_url: Optional[str] = None
    call_id: Optional[str] = None
    call_mode: Optional[str] = None
    reply_to_message_id: Optional[str] = None
    reply_to_sender_id: Optional[str] = None
    reply_to_content: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


class ConversationSummary(BaseModel):
    contact_id: str
    contact_name: Optional[str]
    contact_profile_picture: Optional[str]
    last_message: str
    last_sent_at: str
    last_message_type: Optional[str]
    unread_count: int = 0
    is_sender_last_message: bool

    model_config = ConfigDict(from_attributes=True)
