from typing import Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ...api.deps import get_current_user_optional
from ...db import models
from ...db.session import get_db
from ...schemas.behavior_log import BehaviorLogRead

router = APIRouter(prefix="/behavior_logs", tags=["behavior_logs"])


@router.get("/latest", response_model=BehaviorLogRead)
async def get_latest_behavior_log(
    user_id: Optional[str] = None,
    db: Session = Depends(get_db),
    current_user: models.User | None = Depends(get_current_user_optional),
) -> BehaviorLogRead:
    if not user_id and not current_user:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Authentication required",
        )
    target_user = user_id or str(current_user.id)
    log = (
        db.query(models.BehaviorLog)
        .filter(models.BehaviorLog.user_id == target_user)
        .order_by(models.BehaviorLog.log_date.desc())
        .first()
    )
    if not log:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Behavior log not found")
    return BehaviorLogRead(
        id=log.id,
        pet_id=log.pet_id,
        user_id=log.user_id,
        log_date=log.log_date,
        activity_level=log.activity_level,
        food_intake=log.food_intake,
        water_intake=log.water_intake,
        bathroom_habits=log.bathroom_habits,
        symptoms=log.symptoms,
        created_at=log.created_at,
    )
