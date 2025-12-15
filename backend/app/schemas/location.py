from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class LocationBase(BaseModel):
    model_config = ConfigDict(extra="forbid", populate_by_name=True)

    pet_id: UUID | None = None
    latitude: float = Field(alias="lat")
    longitude: float = Field(alias="long")
    device_mac: str | None = None
    timestamp: datetime | None = None


class LocationCreate(LocationBase):
    pass


class LocationRead(LocationBase):
    id: UUID
    timestamp: datetime

    class Config:
        orm_mode = True
