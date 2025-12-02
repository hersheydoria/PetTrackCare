from datetime import datetime
from typing import List, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict


class CommunityUserSummary(BaseModel):
    id: UUID
    name: Optional[str] = None
    role: Optional[str] = None
    profile_picture: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


class CommunityPostSummary(BaseModel):
    id: UUID
    content: str
    image_url: Optional[str] = None
    created_at: datetime
    user: CommunityUserSummary

    model_config = ConfigDict(from_attributes=True)


class BookmarkWithPost(BaseModel):
    id: UUID
    user_id: UUID
    post_id: UUID
    created_at: datetime
    post: CommunityPostSummary

    model_config = ConfigDict(from_attributes=True)


class CommentLikeRead(BaseModel):
    user_id: UUID
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class ReplyRead(BaseModel):
    id: UUID
    comment_id: UUID
    content: str
    created_at: datetime
    user: CommunityUserSummary

    model_config = ConfigDict(from_attributes=True)


class CommentRead(BaseModel):
    id: UUID
    post_id: UUID
    content: str
    created_at: datetime
    user: CommunityUserSummary
    likes: List[CommentLikeRead] = []
    replies: List[ReplyRead] = []

    model_config = ConfigDict(from_attributes=True)


class CommunityLikeRead(BaseModel):
    user_id: UUID
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class BookmarkRead(BaseModel):
    id: UUID
    user_id: UUID
    post_id: UUID
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class CommunityPostBase(BaseModel):
    type: str
    content: str
    image_url: Optional[str] = None
    latitude: Optional[str] = None
    longitude: Optional[str] = None
    address: Optional[str] = None
    reported: Optional[bool] = False


class CommunityPostCreate(CommunityPostBase):
    pass


class CommunityPostUpdate(BaseModel):
    type: Optional[str] = None
    content: Optional[str] = None
    image_url: Optional[str] = None
    latitude: Optional[str] = None
    longitude: Optional[str] = None
    address: Optional[str] = None
    reported: Optional[bool] = None


class CommunityPostRead(CommunityPostBase):
    id: UUID
    user_id: Optional[UUID]
    created_at: datetime
    updated_at: datetime
    user: CommunityUserSummary
    likes: List[CommunityLikeRead] = []
    comments: List[CommentRead] = []
    bookmarks: List[BookmarkRead] = []

    model_config = ConfigDict(from_attributes=True)


class CommentCreate(BaseModel):
    content: str


class CommentUpdate(BaseModel):
    content: str


class ReplyCreate(BaseModel):
    content: str


class ReplyUpdate(BaseModel):
    content: str


class ReportCreate(BaseModel):
    reason: str
