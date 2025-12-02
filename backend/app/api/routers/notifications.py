from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...db import models
from ...db.session import get_db
from ...schemas.notification import (
    NotificationCreate,
    NotificationRead,
    NotificationUpdate,
)

router = APIRouter(prefix="/notifications", tags=["notifications"])


@router.post("/", response_model=NotificationRead)
async def create_notification(
    payload: NotificationCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Notification:
    notification = models.Notification(**payload.model_dump())
    db.add(notification)
    db.commit()
    db.refresh(notification)
    return notification


@router.get("/me", response_model=List[NotificationRead])
async def list_my_notifications(
    db: Session = Depends(get_db), current_user: models.User = Depends(get_current_user)
) -> List[models.Notification]:
    return (
        db.query(models.Notification)
        .filter(models.Notification.user_id == current_user.id)
        .order_by(models.Notification.created_at.desc())
        .limit(50)
        .all()
    )


@router.patch("/{notification_id}", response_model=NotificationRead)
async def update_notification(
    notification_id: str,
    payload: NotificationUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Notification:
    notification = db.get(models.Notification, notification_id)
    if not notification or notification.user_id != current_user.id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Notification not found")
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(notification, field, value)
    db.add(notification)
    db.commit()
    db.refresh(notification)
    return notification
