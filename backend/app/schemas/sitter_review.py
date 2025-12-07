from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class SitterReviewCreate(BaseModel):
    rating: int
    comment: str | None = None
    owner_name: str | None = None


class SitterReviewRead(BaseModel):
    id: UUID
    sitter_id: UUID
    reviewer_id: UUID | None
    rating: int
    comment: str | None = None
    owner_name: str
    reviewer_name: str | None = None
    reviewer_profile_picture: str | None = None
    created_at: datetime

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            datetime: lambda value: value.isoformat(),
        }
