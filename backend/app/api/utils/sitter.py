from typing import Optional

from sqlalchemy.orm import Session

from ...db import models


def get_or_create_sitter_profile(db: Session, identifier: str) -> Optional[models.Sitter]:
    """Find a sitter by ID or user ID, creating a row if the user is a sitter."""
    sitter = db.query(models.Sitter).filter(models.Sitter.id == identifier).first()
    if sitter:
        return sitter

    sitter = db.query(models.Sitter).filter(models.Sitter.user_id == identifier).first()
    if sitter:
        return sitter

    user = db.get(models.User, identifier)
    if not user or user.role != "Pet Sitter":
        return None

    sitter = models.Sitter(user_id=user.id)
    db.add(sitter)
    db.commit()
    db.refresh(sitter)
    return sitter


def resolve_user_by_identifier(db: Session, identifier: str) -> Optional[models.User]:
    """Resolve a User either by their own ID or by a linked sitter ID."""
    user = db.get(models.User, identifier)
    if user:
        return user

    sitter = db.get(models.Sitter, identifier)
    if sitter and sitter.user_id:
        return db.get(models.User, sitter.user_id)

    return None
