from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...api.utils.sitter import get_or_create_sitter_profile, resolve_user_by_identifier
from ...core.security import get_password_hash
from ...db import models
from ...db.session import get_db
from ...schemas.user import UserRead, UserUpdate

router = APIRouter(prefix="/users", tags=["users"])


@router.get("/me", response_model=UserRead)
async def read_current_user(current_user: models.User = Depends(get_current_user)) -> models.User:
    return current_user


@router.patch("/me", response_model=UserRead)
async def update_current_user(
    payload: UserUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.User:
    payload_data = payload.model_dump(exclude_unset=True)
    password = payload_data.pop('password', None)
    if password:
        current_user.password_hash = get_password_hash(password)
    for field, value in payload_data.items():
        setattr(current_user, field, value)
    db.add(current_user)
    db.commit()
    db.refresh(current_user)
    get_or_create_sitter_profile(db, str(current_user.id))
    return current_user


@router.get("/{user_id}", response_model=UserRead)
async def read_user(user_id: str, db: Session = Depends(get_db)) -> models.User:
    user = resolve_user_by_identifier(db, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    return user


@router.get("/", response_model=List[UserRead])
async def list_users(
    limit: int = 20,
    offset: int = 0,
    query: Optional[str] = None,
    db: Session = Depends(get_db),
) -> List[models.User]:
    base = db.query(models.User)
    if query:
        base = base.filter(models.User.name.ilike(f"%{query}%"))
    return base.offset(offset).limit(limit).all()


@router.delete("/me")
async def delete_current_user(
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    db.delete(current_user)
    db.commit()
    return {"status": "deleted"}
