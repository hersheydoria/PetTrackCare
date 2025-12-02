from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class FeedbackCreate(BaseModel):
    message: str


class FeedbackRead(BaseModel):
    id: UUID
    user_id: UUID
    message: str
    created_at: datetime

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            datetime: lambda value: value.isoformat(),
        }
