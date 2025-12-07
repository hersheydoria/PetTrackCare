from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func
from sqlalchemy.orm import Session, joinedload

from ...api.deps import get_current_user
from ...api.utils.sitter import get_or_create_sitter_profile
from ...db import models
from ...db.session import get_db
from ...schemas.sitter import SitterRead, SitterUpdate
from ...schemas.sitter_review import SitterReviewCreate, SitterReviewRead

router = APIRouter(prefix="/sitters", tags=["sitters"])


def _build_sitter_payload(sitter: models.Sitter, db: Session) -> SitterRead:
    avg_rating = (
        db.query(func.avg(models.SitterReview.rating))
        .filter(models.SitterReview.sitter_id == sitter.id)
        .scalar()
    )
    avg_rating = float(avg_rating) if avg_rating is not None else None
    name = sitter.user.name if sitter.user else None
    profile_picture = sitter.user.profile_picture if sitter.user else None
    address = sitter.user.address if sitter.user else None
    status = sitter.user.status if sitter.user else None
    return SitterRead(
        id=sitter.id,
        user_id=sitter.user_id,
        bio=sitter.bio,
        experience=sitter.experience,
        hourly_rate=sitter.hourly_rate,
        is_available=sitter.is_available,
        name=name,
        profile_picture=profile_picture,
        address=address,
        status=status,
        rating=avg_rating,
        created_at=sitter.created_at,
    )


@router.get("/", response_model=List[SitterRead])
async def list_sitters(
    limit: int = 20,
    offset: int = 0,
    location: str | None = None,
    db: Session = Depends(get_db),
) -> List[SitterRead]:
    query = db.query(models.Sitter).options(joinedload(models.Sitter.user))
    if location:
        query = query.join(models.User).filter(models.User.address.ilike(f"%{location}%"))
    sitters = query.offset(offset).limit(limit).all()
    return [_build_sitter_payload(sitter, db) for sitter in sitters]


@router.get("/{user_id}", response_model=SitterRead)
async def read_sitter(user_id: str, db: Session = Depends(get_db)) -> SitterRead:
    sitter = get_or_create_sitter_profile(db, user_id)
    if not sitter:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sitter profile not found")
    return _build_sitter_payload(sitter, db)


@router.patch("/{user_id}", response_model=SitterRead)
async def update_sitter_profile(
    user_id: str,
    payload: SitterUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> SitterRead:
    if str(current_user.id) != user_id:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot edit another sitter")
    sitter = get_or_create_sitter_profile(db, user_id)
    if not sitter:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sitter profile not found")
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(sitter, field, value)
    db.add(sitter)
    db.commit()
    db.refresh(sitter)
    return _build_sitter_payload(sitter, db)


@router.get("/{user_id}/reviews", response_model=List[SitterReviewRead])
async def list_sitter_reviews(user_id: str, db: Session = Depends(get_db)) -> List[SitterReviewRead]:
    sitter = get_or_create_sitter_profile(db, user_id)
    if not sitter:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sitter profile not found")
    reviews = (
        db.query(models.SitterReview)
        .options(joinedload(models.SitterReview.reviewer))
        .filter(models.SitterReview.sitter_id == sitter.id)
        .order_by(models.SitterReview.created_at.desc())
        .all()
    )
    result: List[SitterReviewRead] = []
    for review in reviews:
        reviewer_name = review.reviewer.name if review.reviewer else None
        result.append(
            SitterReviewRead(
                id=review.id,
                sitter_id=review.sitter_id,
                reviewer_id=review.reviewer_id,
                rating=review.rating,
                comment=review.comment,
                owner_name=review.owner_name,
                reviewer_name=reviewer_name,
                reviewer_profile_picture=review.reviewer.profile_picture if review.reviewer else None,
                created_at=review.created_at,
            )
        )
    return result


@router.post("/{user_id}/reviews", response_model=SitterReviewRead, status_code=status.HTTP_201_CREATED)
async def create_sitter_review(
    user_id: str,
    payload: SitterReviewCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> SitterReviewRead:
    sitter = get_or_create_sitter_profile(db, user_id)
    if not sitter:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sitter profile not found")
    reviewer_name = current_user.name
    review = models.SitterReview(
        sitter_id=sitter.id,
        reviewer_id=current_user.id,
        rating=payload.rating,
        comment=payload.comment,
        owner_name=payload.owner_name or reviewer_name,
    )
    db.add(review)
    db.commit()
    db.refresh(review)
    return SitterReviewRead(
        id=review.id,
        sitter_id=review.sitter_id,
        reviewer_id=review.reviewer_id,
        rating=review.rating,
        comment=review.comment,
        owner_name=review.owner_name,
        reviewer_name=reviewer_name,
        reviewer_profile_picture=current_user.profile_picture,
        created_at=review.created_at,
    )
