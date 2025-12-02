from typing import Dict

from datetime import datetime
from pydantic import BaseModel, Field


class LocationBase(BaseModel):
    pet_id: str
    latitude: float
    longitude: float
    device_mac: str | None = None
    address: str | None = None
    timestamp: datetime | None = None
    additional_data: Dict[str, str] = Field(default_factory=dict)


class LocationCreate(LocationBase):
    pass


class LocationRead(LocationBase):
    id: str
    created_at: datetime

    class Config:
        orm_mode = True
