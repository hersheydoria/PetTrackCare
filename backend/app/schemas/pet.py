from datetime import datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


class PetBase(BaseModel):
    name: str
    breed: str
    health: str
    profile_picture: str = Field(default='')
    type: str
    gender: str
    weight: float
    is_missing: Optional[bool] = None
    date_of_birth: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


class PetCreate(PetBase):
    owner_id: str


class PetUpdate(BaseModel):
    name: Optional[str] = None
    breed: Optional[str] = None
    health: Optional[str] = None
    profile_picture: Optional[str] = None
    type: Optional[str] = None
    gender: Optional[str] = None
    weight: Optional[float] = None
    is_missing: Optional[bool] = None
    date_of_birth: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)


class PetRead(PetBase):
    id: UUID
    owner_id: UUID
    created_at: datetime
    updated_at: Optional[datetime] = None

    model_config = ConfigDict(from_attributes=True)
