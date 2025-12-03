from datetime import date
from typing import Optional, List

from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy.orm import Session

from ...api.deps import get_current_user, get_current_user_optional
from ...db import models
from ...db.session import get_db
from ...schemas.behavior_log import (
    BehaviorLogCreate,
    BehaviorLogRead,
    BehaviorLogUpdate,
)

router = APIRouter(prefix="/behavior_logs", tags=["behavior_logs"])


@router.post("/", response_model=BehaviorLogRead, status_code=status.HTTP_201_CREATED)
async def create_behavior_log(
    payload: BehaviorLogCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> BehaviorLogRead:
    if str(payload.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot create log for another user")
    log = models.BehaviorLog(**payload.model_dump())
    db.add(log)
    db.commit()
    db.refresh(log)
    return log


@router.patch("/{log_id}", response_model=BehaviorLogRead)
async def update_behavior_log(
    log_id: str,
    payload: BehaviorLogUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> BehaviorLogRead:
    log = db.get(models.BehaviorLog, log_id)
    if not log:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Behavior log not found")
    if str(log.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot update another user's log")
    updates = payload.model_dump(exclude_unset=True)
    for field, value in updates.items():
        setattr(log, field, value)
    db.add(log)
    db.commit()
    db.refresh(log)
    return log


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


@router.get("/", response_model=List[BehaviorLogRead])
async def list_behavior_logs(
    pet_id: Optional[str] = None,
    user_id: Optional[str] = None,
    start_date: date | None = None,
    end_date: date | None = None,
    limit: int = 100,
    db: Session = Depends(get_db),
) -> List[BehaviorLogRead]:
    query = db.query(models.BehaviorLog)
    if pet_id:
        query = query.filter(models.BehaviorLog.pet_id == pet_id)
    if user_id:
        query = query.filter(models.BehaviorLog.user_id == user_id)
    if start_date:
        query = query.filter(models.BehaviorLog.log_date >= start_date)
    if end_date:
        query = query.filter(models.BehaviorLog.log_date <= end_date)
    query = query.order_by(models.BehaviorLog.log_date.desc())
    if limit and limit > 0:
        query = query.limit(limit)
    return query.all()


@router.delete("/{log_id}", status_code=status.HTTP_204_NO_CONTENT)
async def delete_behavior_log(
    log_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> Response:
    log = db.get(models.BehaviorLog, log_id)
    if not log:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Behavior log not found")
    if str(log.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not authorized to delete this log")
    db.delete(log)
    db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
