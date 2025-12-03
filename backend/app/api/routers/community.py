from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, Query, status
from sqlalchemy.orm import Session, selectinload

from ...api.deps import get_current_user
from ...db import models
from ...db.session import get_db
from ...schemas.community import (
    BookmarkWithPost,
    CommentCreate,
    CommentRead,
    CommentUpdate,
    CommunityPostCreate,
    CommunityPostRead,
    CommunityPostSummary,
    CommunityPostUpdate,
    ReportCreate,
    ReplyCreate,
    ReplyRead,
    ReplyUpdate,
)

router = APIRouter(prefix="/community", tags=["community"])


def _post_query_options():
    return [
        selectinload(models.CommunityPost.user),
        selectinload(models.CommunityPost.likes),
        selectinload(models.CommunityPost.bookmarks),
        selectinload(models.CommunityPost.comments)
        .selectinload(models.Comment.user),
        selectinload(models.CommunityPost.comments)
        .selectinload(models.Comment.likes),
        selectinload(models.CommunityPost.comments)
        .selectinload(models.Comment.replies)
        .selectinload(models.Reply.user),
    ]


def _load_post(db: Session, post_id: str) -> Optional[models.CommunityPost]:
    return (
        db.query(models.CommunityPost)
        .options(*_post_query_options())
        .filter(models.CommunityPost.id == post_id)
        .first()
    )


def _load_comment(db: Session, comment_id: str) -> Optional[models.Comment]:
    return (
        db.query(models.Comment)
        .options(
            selectinload(models.Comment.user),
            selectinload(models.Comment.likes),
            selectinload(models.Comment.replies).selectinload(models.Reply.user),
        )
        .filter(models.Comment.id == comment_id)
        .first()
    )


def _load_reply(db: Session, reply_id: str) -> Optional[models.Reply]:
    return (
        db.query(models.Reply)
        .options(selectinload(models.Reply.user))
        .filter(models.Reply.id == reply_id)
        .first()
    )


@router.get("/posts", response_model=List[CommunityPostRead])
async def list_posts(
    limit: int = 20,
    offset: int = 0,
    post_type: Optional[str] = Query(None, alias="type"),
    user_id: Optional[str] = None,
    db: Session = Depends(get_db),
) -> List[models.CommunityPost]:
    query = (
        db.query(models.CommunityPost)
        .options(*_post_query_options())
        .order_by(models.CommunityPost.created_at.desc())
    )

    if post_type:
        query = query.filter(models.CommunityPost.type == post_type)
    if user_id:
        query = query.filter(models.CommunityPost.user_id == user_id)

    return query.offset(offset).limit(limit).all()


@router.get("/posts/{post_id}", response_model=CommunityPostRead)
async def get_post(
    post_id: str,
    db: Session = Depends(get_db),
) -> models.CommunityPost:
    post = _load_post(db, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    return post


@router.post("/posts", response_model=CommunityPostRead)
async def create_post(
    payload: CommunityPostCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.CommunityPost:
    post = models.CommunityPost(user_id=current_user.id, **payload.model_dump())
    db.add(post)
    db.commit()
    db.refresh(post)
    loaded = _load_post(db, post.id)
    if not loaded:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to load post")
    return loaded


@router.patch("/posts/{post_id}", response_model=CommunityPostRead)
async def update_post(
    post_id: str,
    payload: CommunityPostUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.CommunityPost:
    post = db.get(models.CommunityPost, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    if str(post.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the post")

    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(post, field, value)
    db.add(post)
    db.commit()
    db.refresh(post)
    loaded = _load_post(db, post_id)
    if not loaded:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to load post")
    return loaded


@router.delete("/posts/{post_id}")
async def delete_post(
    post_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    post = db.get(models.CommunityPost, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    if str(post.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the post")
    db.delete(post)
    db.commit()
    return {"status": "deleted"}


@router.post("/posts/{post_id}/comments", response_model=CommentRead)
async def add_comment(
    post_id: str,
    payload: CommentCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Comment:
    post = db.get(models.CommunityPost, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    comment = models.Comment(post_id=post_id, user_id=current_user.id, content=payload.content)
    db.add(comment)
    db.commit()
    db.refresh(comment)
    loaded = _load_comment(db, comment.id)
    if not loaded:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to load comment")
    return loaded


@router.patch("/comments/{comment_id}", response_model=CommentRead)
async def update_comment(
    comment_id: str,
    payload: CommentUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Comment:
    comment = db.get(models.Comment, comment_id)
    if not comment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Comment not found")
    if str(comment.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the comment")
    comment.content = payload.content
    db.add(comment)
    db.commit()
    db.refresh(comment)
    loaded = _load_comment(db, comment_id)
    if not loaded:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to load comment")
    return loaded


@router.delete("/comments/{comment_id}")
async def delete_comment(
    comment_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    comment = db.get(models.Comment, comment_id)
    if not comment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Comment not found")
    if str(comment.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the comment")
    db.delete(comment)
    db.commit()
    return {"status": "deleted"}


@router.post("/comments/{comment_id}/replies", response_model=ReplyRead)
async def add_reply(
    comment_id: str,
    payload: ReplyCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Reply:
    comment = db.get(models.Comment, comment_id)
    if not comment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Comment not found")
    reply = models.Reply(comment_id=comment_id, user_id=current_user.id, content=payload.content)
    db.add(reply)
    db.commit()
    db.refresh(reply)
    loaded = _load_reply(db, reply.id)
    if not loaded:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to load reply")
    return loaded


@router.post("/posts/{post_id}/likes")
async def like_post(
    post_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    post = db.get(models.CommunityPost, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    existing = (
        db.query(models.CommunityLike)
        .filter(models.CommunityLike.post_id == post_id, models.CommunityLike.user_id == current_user.id)
        .first()
    )
    if existing:
        return {"status": "already liked"}
    like = models.CommunityLike(post_id=post_id, user_id=current_user.id)
    db.add(like)
    db.commit()
    return {"status": "liked"}


@router.delete("/posts/{post_id}/likes")
async def unlike_post(
    post_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    like = (
        db.query(models.CommunityLike)
        .filter(models.CommunityLike.post_id == post_id, models.CommunityLike.user_id == current_user.id)
        .first()
    )
    if like:
        db.delete(like)
        db.commit()
    return {"status": "unliked"}


@router.post("/comments/{comment_id}/likes")
async def like_comment(
    comment_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    comment = db.get(models.Comment, comment_id)
    if not comment:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Comment not found")
    existing = (
        db.query(models.CommentLike)
        .filter(models.CommentLike.comment_id == comment_id, models.CommentLike.user_id == current_user.id)
        .first()
    )
    if existing:
        return {"status": "already liked"}
    like = models.CommentLike(comment_id=comment_id, user_id=current_user.id)
    db.add(like)
    db.commit()
    return {"status": "liked"}


@router.delete("/comments/{comment_id}/likes")
async def unlike_comment(
    comment_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    like = (
        db.query(models.CommentLike)
        .filter(models.CommentLike.comment_id == comment_id, models.CommentLike.user_id == current_user.id)
        .first()
    )
    if like:
        db.delete(like)
        db.commit()
    return {"status": "unliked"}


@router.get("/comments/{comment_id}/replies", response_model=List[ReplyRead])
async def list_replies(
    comment_id: str,
    limit: int = 10,
    offset: int = 0,
    db: Session = Depends(get_db),
) -> List[models.Reply]:
    return (
        db.query(models.Reply)
        .options(selectinload(models.Reply.user))
        .filter(models.Reply.comment_id == comment_id)
        .order_by(models.Reply.created_at.desc())
        .offset(offset)
        .limit(limit)
        .all()
    )


@router.patch("/comments/{comment_id}/replies/{reply_id}", response_model=ReplyRead)
async def update_reply(
    comment_id: str,
    reply_id: str,
    payload: ReplyUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Reply:
    reply = db.get(models.Reply, reply_id)
    if not reply or str(reply.comment_id) != comment_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Reply not found")
    if str(reply.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the reply")
    reply.content = payload.content
    db.add(reply)
    db.commit()
    db.refresh(reply)
    loaded = _load_reply(db, reply_id)
    if not loaded:
        raise HTTPException(status_code=status.HTTP_500_INTERNAL_SERVER_ERROR, detail="Failed to load reply")
    return loaded


@router.delete("/comments/{comment_id}/replies/{reply_id}")
async def delete_reply(
    comment_id: str,
    reply_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    reply = db.get(models.Reply, reply_id)
    if not reply or str(reply.comment_id) != comment_id:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Reply not found")
    if str(reply.user_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the owner of the reply")
    db.delete(reply)
    db.commit()
    return {"status": "deleted"}


@router.get("/bookmarks/me", response_model=List[BookmarkWithPost])
async def list_my_bookmarks(
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> List[BookmarkWithPost]:
    bookmarks = (
        db.query(models.Bookmark)
        .options(
            selectinload(models.Bookmark.post)
            .selectinload(models.CommunityPost.user),
        )
        .filter(models.Bookmark.user_id == current_user.id)
        .order_by(models.Bookmark.created_at.desc())
        .all()
    )

    return [
        BookmarkWithPost(
            id=bookmark.id,
            user_id=bookmark.user_id,
            post_id=bookmark.post_id,
            created_at=bookmark.created_at,
            post=CommunityPostSummary.from_orm(bookmark.post),
        )
        for bookmark in bookmarks
        if bookmark.post is not None
    ]


@router.post("/posts/{post_id}/bookmarks")
async def add_bookmark(
    post_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    existing = (
        db.query(models.Bookmark)
        .filter(models.Bookmark.post_id == post_id, models.Bookmark.user_id == current_user.id)
        .first()
    )
    if existing:
        return {"status": "already saved"}
    bookmark = models.Bookmark(post_id=post_id, user_id=current_user.id)
    db.add(bookmark)
    db.commit()
    return {"status": "saved"}


@router.delete("/posts/{post_id}/bookmarks")
async def remove_bookmark(
    post_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    bookmark = (
        db.query(models.Bookmark)
        .filter(models.Bookmark.post_id == post_id, models.Bookmark.user_id == current_user.id)
        .first()
    )
    if bookmark:
        db.delete(bookmark)
        db.commit()
    return {"status": "removed"}


@router.post("/posts/{post_id}/reports")
async def report_post(
    post_id: str,
    payload: ReportCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    post = db.get(models.CommunityPost, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Post not found")
    report = models.Report(post_id=post_id, user_id=current_user.id, reason=payload.reason)
    post.reported = True
    db.add(report)
    db.add(post)
    db.commit()
    return {"status": "reported"}
