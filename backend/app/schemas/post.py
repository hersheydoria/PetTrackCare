from typing import Dict

from pydantic import BaseModel, Field


class PostBase(BaseModel):
    title: str | None = None
    content: str | None = None
    media_url: str | None = None
    metadata: Dict[str, str] = Field(default_factory=dict)


class PostCreate(PostBase):
    owner_id: str


class PostUpdate(BaseModel):
    title: str | None = None
    content: str | None = None
    media_url: str | None = None
    metadata: Dict[str, str] | None = None


class PostRead(PostBase):
    id: str
    owner_id: str
    created_at: str
    updated_at: str

    class Config:
        orm_mode = True
