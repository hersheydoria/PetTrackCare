from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class SitterReviewBase(BaseModel):
    sitter_id: UUID
    reviewer_id: UUID
    rating: int | None = None
    comment: str | None = None
    owner_name: str | None = None


class SitterReviewRead(SitterReviewBase):
    id: UUID
    reviewer_name: str | None = None
    created_at: datetime

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            datetime: lambda value: value.isoformat(),
        }
