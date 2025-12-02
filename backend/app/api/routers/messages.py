from typing import List

import uuid
from fastapi import APIRouter, Depends, HTTPException, Query
from sqlalchemy import and_, func, or_
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...api.utils.sitter import resolve_user_by_identifier
from ...db import models
from ...db.session import get_db
from ...schemas.message import ConversationSummary, MessageCreate, MessageRead
from ...schemas.typing import TypingStatusRead, TypingStatusUpdate

router = APIRouter(prefix="/messages", tags=["messages"])


def _parse_uuid(value: str, name: str) -> uuid.UUID:
    try:
        return uuid.UUID(value)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=f"Invalid {name}") from exc


def _resolve_user_or_404(db: Session, identifier: str) -> models.User:
    user = resolve_user_by_identifier(db, identifier)
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    return user


def _serialize_message(message: models.Message) -> dict:
    return {
        "id": str(message.id),
        "sender_id": str(message.sender_id),
        "receiver_id": str(message.receiver_id),
        "content": message.content,
        "metadata": message.metadata_payload or {},
        "is_seen": bool(message.is_seen),
        "sent_at": message.sent_at.isoformat(),
        "type": message.type,
        "media_url": message.media_url,
        "call_id": message.call_id,
        "call_mode": message.call_mode,
        "reply_to_message_id": str(message.reply_to_message_id) if message.reply_to_message_id else None,
        "reply_to_sender_id": str(message.reply_to_sender_id) if message.reply_to_sender_id else None,
        "reply_to_content": message.reply_to_content,
    }


@router.get("/conversations", response_model=List[ConversationSummary])
async def list_conversations(
    limit: int = Query(24, ge=5, le=100),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> List[ConversationSummary]:
    target_id = current_user.id
    messages = (
        db.query(models.Message)
        .filter(or_(models.Message.sender_id == target_id, models.Message.receiver_id == target_id))
        .order_by(models.Message.sent_at.desc())
        .limit(limit * 4)
        .all()
    )

    conversations: dict[str, dict] = {}
    ordered: list[str] = []
    contact_ids: set[uuid.UUID] = set()

    for message in messages:
        other_id = message.receiver_id if message.sender_id == target_id else message.sender_id
        if other_id == target_id:
            continue
        contact_key = str(other_id)
        if contact_key in conversations:
            continue
        conversations[contact_key] = {
            "contact_id": contact_key,
            "last_message": message.content,
            "last_sent_at": message.sent_at.isoformat(),
            "last_message_type": message.type,
            "is_sender_last_message": message.sender_id == target_id,
        }
        ordered.append(contact_key)
        contact_ids.add(other_id)

    if contact_ids:
        users = db.query(models.User).filter(models.User.id.in_(contact_ids)).all()
        user_map = {str(user.id): user for user in users}
    else:
        user_map = {}

    unread_counts = (
        db.query(models.Message.sender_id, func.count(models.Message.id))
        .filter(models.Message.receiver_id == target_id, models.Message.is_seen.is_(False))
        .group_by(models.Message.sender_id)
        .all()
    )
    unread_map = {str(entry[0]): entry[1] for entry in unread_counts}

    result: list[ConversationSummary] = []
    for contact_id in ordered:
        summary = conversations[contact_id]
        user = user_map.get(contact_id)
        summary["contact_name"] = user.display_name if user else None
        summary["contact_profile_picture"] = user.profile_picture if user else None
        summary["unread_count"] = unread_map.get(contact_id, 0)
        result.append(ConversationSummary(**summary))

    return result


@router.get("/thread/{peer_id}", response_model=List[MessageRead])
async def get_thread(
    peer_id: str,
    limit: int = Query(150, ge=10, le=500),
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> List[models.Message]:
    peer_uuid = _parse_uuid(peer_id, "peer_id")
    peer_user = _resolve_user_or_404(db, str(peer_uuid))
    records = (
        db.query(models.Message)
        .filter(
            or_(
                and_(models.Message.sender_id == current_user.id, models.Message.receiver_id == peer_user.id),
                and_(models.Message.receiver_id == current_user.id, models.Message.sender_id == peer_user.id),
            )
        )
        .order_by(models.Message.sent_at.asc())
        .limit(limit)
        .all()
    )
    return [MessageRead(**_serialize_message(msg)) for msg in records]


@router.post("/", response_model=MessageRead)
async def send_message(
    payload: MessageCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Message:
    receiver_uuid = _parse_uuid(payload.receiver_id, "receiver_id")
    receiver = _resolve_user_or_404(db, str(receiver_uuid))
    reply_to_message_id = (
        _parse_uuid(payload.reply_to_message_id, "reply_to_message_id") if payload.reply_to_message_id else None
    )
    reply_to_sender_id = (
        _parse_uuid(payload.reply_to_sender_id, "reply_to_sender_id") if payload.reply_to_sender_id else None
    )
    message = models.Message(
        sender_id=current_user.id,
        receiver_id=receiver.id,
        content=payload.content,
        metadata=payload.metadata,
        type=payload.type,
        media_url=payload.media_url,
        call_id=payload.call_id,
        call_mode=payload.call_mode,
        reply_to_message_id=reply_to_message_id,
        reply_to_sender_id=reply_to_sender_id,
        reply_to_content=payload.reply_to_content,
    )
    db.add(message)
    db.commit()
    db.refresh(message)
    return MessageRead(**_serialize_message(message))


@router.post("/seen")
async def mark_as_seen(
    peer_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict[str, int]:
    peer_uuid = _parse_uuid(peer_id, "peer_id")
    peer_user = _resolve_user_or_404(db, str(peer_uuid))
    updated = (
        db.query(models.Message)
        .filter(models.Message.sender_id == peer_user.id, models.Message.receiver_id == current_user.id, models.Message.is_seen.is_(False))
        .update({"is_seen": True}, synchronize_session=False)
    )
    db.commit()
    return {"updated": updated}


@router.post("/typing-status", response_model=TypingStatusRead)
async def update_typing_status(
    payload: TypingStatusUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.TypingStatus:
    chat_uuid = _parse_uuid(payload.chat_with_id, "chat_with_id")
    chat_user = _resolve_user_or_404(db, str(chat_uuid))
    status = (
        db.query(models.TypingStatus)
        .filter(models.TypingStatus.user_id == current_user.id, models.TypingStatus.chat_with_id == chat_user.id)
        .one_or_none()
    )
    if status is None:
        status = models.TypingStatus(user_id=current_user.id, chat_with_id=chat_user.id, is_typing=payload.is_typing)
    else:
        status.is_typing = payload.is_typing
    db.add(status)
    db.commit()
    db.refresh(status)
    return TypingStatusRead(chat_with_id=str(chat_user.id), is_typing=status.is_typing)


@router.get("/typing-status/{peer_id}", response_model=TypingStatusRead)
async def get_typing_status(
    peer_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> TypingStatusRead:
    peer_uuid = _parse_uuid(peer_id, "peer_id")
    peer_user = _resolve_user_or_404(db, str(peer_uuid))
    status = (
        db.query(models.TypingStatus)
        .filter(models.TypingStatus.user_id == peer_user.id, models.TypingStatus.chat_with_id == current_user.id)
        .one_or_none()
    )
    return TypingStatusRead(chat_with_id=str(peer_user.id), is_typing=bool(status and status.is_typing))
