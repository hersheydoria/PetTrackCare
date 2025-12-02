from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field


class UserBase(BaseModel):
    email: EmailStr
    name: str | None = None
    role: str = Field(default="Pet Owner", max_length=64)
    profile_picture: str | None = None
    address: str | None = None
    status: str | None = None


class UserCreate(UserBase):
    password: str


class UserUpdate(BaseModel):
    name: str | None = None
    role: str | None = None
    profile_picture: str | None = None
    address: str | None = None
    status: str | None = None
    password: str | None = None


class UserRead(UserBase):
    id: UUID
    created_at: datetime
    updated_at: datetime
    name: str | None = None
    role: str

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            datetime: lambda value: value.isoformat(),
        }
