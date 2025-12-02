from datetime import datetime
from typing import Dict
from uuid import UUID

from pydantic import BaseModel, Field


class NotificationBase(BaseModel):
    message: str | None = None
    type: str | None = None
    actor_id: UUID | None = None
    post_id: UUID | None = None
    job_id: UUID | None = None
    comment_id: UUID | None = None
    metadata: Dict[str, str] = Field(default_factory=dict)


class NotificationCreate(NotificationBase):
    user_id: UUID


class NotificationUpdate(BaseModel):
    is_read: bool | None = None
    metadata: Dict[str, str] | None = None


class NotificationRead(NotificationBase):
    id: UUID
    user_id: UUID
    is_read: bool
    created_at: datetime
    updated_at: datetime
    comment_id: UUID | None = None

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            datetime: lambda value: value.isoformat(),
        }
