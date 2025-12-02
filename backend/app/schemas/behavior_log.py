from datetime import date, datetime
from uuid import UUID

from pydantic import BaseModel


class BehaviorLogRead(BaseModel):
    id: UUID
    pet_id: UUID
    user_id: UUID
    log_date: date
    activity_level: str | None = None
    food_intake: str | None = None
    water_intake: str | None = None
    bathroom_habits: str | None = None
    symptoms: str | None = None
    created_at: datetime

    class Config:
        orm_mode = True
        json_encoders = {
            UUID: lambda value: str(value),
            date: lambda value: value.isoformat(),
            datetime: lambda value: value.isoformat(),
        }
