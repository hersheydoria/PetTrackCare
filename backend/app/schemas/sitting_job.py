from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel


class SittingJobCreate(BaseModel):
    sitter_id: UUID
    pet_id: UUID
    start_date: date
    end_date: date | None = None
    status: str | None = None


class SittingJobUpdate(BaseModel):
    status: str | None = None
    start_date: date | None = None
    end_date: date | None = None


class SittingJobDetail(BaseModel):
    id: UUID
    sitter_id: UUID | None
    pet_id: UUID
    pet_name: str | None
    pet_type: str | None
    pet_profile_picture: str | None
    owner_id: UUID | None
    owner_name: str | None
    status: str
    start_date: date
    end_date: date | None
    created_at: datetime

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            date: lambda value: value.isoformat() if value else None,
            datetime: lambda value: value.isoformat(),
        }
