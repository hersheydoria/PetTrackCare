from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...db import models
from ...db.session import get_db
from ...schemas.feedback import FeedbackCreate, FeedbackRead

router = APIRouter(prefix="/feedback", tags=["feedback"])


@router.post("/", response_model=FeedbackRead)
async def create_feedback(
    payload: FeedbackCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Feedback:
    feedback = models.Feedback(user_id=current_user.id, message=payload.message)
    db.add(feedback)
    db.commit()
    db.refresh(feedback)
    return feedback
