from uuid import UUID

from pydantic import BaseModel


class DevicePetMapRead(BaseModel):
    id: UUID
    device_id: str
    pet_id: UUID

    class Config:
        orm_mode = True


class DevicePetMapCreate(BaseModel):
    pet_id: UUID
    device_id: str
