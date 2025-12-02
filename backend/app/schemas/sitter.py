from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel


class SitterBase(BaseModel):
    user_id: UUID
    bio: Optional[str] = None
    experience: Optional[int] = None
    hourly_rate: Optional[float] = None
    is_available: Optional[bool] = True


class SitterUpdate(BaseModel):
    bio: Optional[str] = None
    experience: Optional[int] = None
    hourly_rate: Optional[float] = None
    is_available: Optional[bool] = None


class SitterRead(SitterBase):
    id: UUID
    name: Optional[str] = None
    profile_picture: Optional[str] = None
    address: Optional[str] = None
    status: Optional[str] = None
    rating: Optional[float] = None
    created_at: datetime

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            datetime: lambda value: value.isoformat(),
        }
