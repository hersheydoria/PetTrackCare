from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...db import models
from ...db.session import get_db
from ...schemas.post import PostCreate, PostRead, PostUpdate

router = APIRouter(prefix="/posts", tags=["posts"])


@router.post("/", response_model=PostRead)
async def create_post(
    payload: PostCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Post:
    post = models.Post(owner_id=str(current_user.id), **payload.model_dump(exclude={"owner_id"}))
    db.add(post)
    db.commit()
    db.refresh(post)
    return post


@router.get("/", response_model=List[PostRead])
async def list_posts(limit: int = 20, offset: int = 0, db: Session = Depends(get_db)) -> List[models.Post]:
    return db.query(models.Post).offset(offset).limit(limit).all()


@router.get("/{post_id}", response_model=PostRead)
async def read_post(post_id: str, db: Session = Depends(get_db)) -> models.Post:
    post = db.get(models.Post, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    return post


@router.patch("/{post_id}", response_model=PostRead)
async def update_post(
    post_id: str,
    payload: PostUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Post:
    post = db.get(models.Post, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    if str(post.owner_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the post")
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(post, field, value)
    db.add(post)
    db.commit()
    db.refresh(post)
    return post


@router.delete("/{post_id}")
async def delete_post(
    post_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    post = db.get(models.Post, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    if str(post.owner_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the post")
    db.delete(post)
    db.commit()
    return {"status": "deleted"}
