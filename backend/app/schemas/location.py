from datetime import datetime
from uuid import UUID

from pydantic import BaseModel


class LocationBase(BaseModel):
    pet_id: UUID | None = None
    latitude: float
    longitude: float
    device_mac: str | None = None
    timestamp: datetime | None = None
    firebase_entry_id: str | None = None


class LocationCreate(LocationBase):
    pass


class LocationRead(LocationBase):
    id: UUID
    timestamp: datetime

    class Config:
        orm_mode = True
