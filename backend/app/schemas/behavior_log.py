from datetime import date, datetime
from typing import Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class BehaviorLogBase(BaseModel):
    pet_id: UUID
    user_id: UUID
    log_date: date
    activity_level: Optional[str] = None
    food_intake: Optional[str] = None
    water_intake: Optional[str] = None
    bathroom_habits: Optional[str] = None
    symptoms: Optional[str] = None

    model_config = ConfigDict(
        from_attributes=True,
        json_encoders={
            UUID: lambda value: str(value),
            date: lambda value: value.isoformat(),
            datetime: lambda value: value.isoformat(),
        },
    )


class BehaviorLogCreate(BehaviorLogBase):
    pass


class BehaviorLogUpdate(BaseModel):
    activity_level: Optional[str] = None
    food_intake: Optional[str] = None
    water_intake: Optional[str] = None
    bathroom_habits: Optional[str] = None
    symptoms: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


class BehaviorLogRead(BehaviorLogBase):
    id: UUID
    created_at: datetime
