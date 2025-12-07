from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional
from uuid import UUID

from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import JSONResponse
from sqlalchemy import func
from sqlalchemy.orm import Session, selectinload

from ..deps import get_current_admin
from ...core.security import create_access_token, get_password_hash, verify_password
from ...db import models
from ...db.session import get_db
from ...schemas.admin import (
    AdminDashboardStatsResponse,
    AdminFeedbackList,
    AdminFeedbackResponseRequest,
    AdminFeedbackUpdate,
    AdminHealthResponse,
    AdminLoginRequest,
    AdminPasswordUpdate,
    AdminProfileData,
    AdminProfileResponse,
    AdminProfileUpdate,
    AdminReportList,
    AdminUsageResponse,
    AdminUserUpdate,
    AdminUsersResponse,
)
from ...schemas.token import Token

router = APIRouter(prefix="/admin", tags=["admin"])


@router.post("/login", response_model=Token)
async def admin_login(payload: AdminLoginRequest, db: Session = Depends(get_db)) -> Token:
    user = db.query(models.User).filter(models.User.email == payload.email).first()
    if not user or (user.role or "").lower() != "admin" or not verify_password(payload.password, user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid admin credentials",
            headers={"WWW-Authenticate": "Bearer"},
        )
    access_token = create_access_token(subject=str(user.id))
    return {"access_token": access_token, "token_type": "bearer"}


@router.get("/reports", response_model=AdminReportList)
async def list_reports(db: Session = Depends(get_db), admin_user: models.User = Depends(get_current_admin)) -> AdminReportList:
    del admin_user
    reports = (
        db.query(models.Report)
        .options(selectinload(models.Report.post), selectinload(models.Report.user))
        .order_by(models.Report.created_at.desc())
        .all()
    )
    items = []
    for report in reports:
        items.append(
            {
                "id": report.id,
                "post_id": report.post_id,
                "reason": report.reason,
                "created_at": report.created_at,
                "post": report.post,
                "user": report.user,
                "post_deleted": report.post is None,
                "post_content": report.post.content if report.post else None,
                "user_name": (report.user.name or report.user.email) if report.user else None,
            }
        )
    return {"reports": items}


@router.delete("/reports/{report_id}")
async def delete_report(
    report_id: UUID,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> JSONResponse:
    del admin_user
    report = db.get(models.Report, report_id)
    if not report:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Report not found")
    db.delete(report)
    db.commit()
    return JSONResponse({"status": "deleted"})


@router.delete("/posts/{post_id}")
async def delete_post_admin(
    post_id: UUID,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> JSONResponse:
    del admin_user
    post = db.get(models.CommunityPost, post_id)
    if not post:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Community post not found")
    db.query(models.Notification).filter(models.Notification.post_id == post_id).delete(synchronize_session=False)
    db.delete(post)
    db.commit()
    return JSONResponse({"status": "deleted"})


@router.get("/users", response_model=AdminUsersResponse)
async def list_users(
    exclude_role: Optional[str] = Query(None, alias="exclude_role"),
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> AdminUsersResponse:
    del admin_user
    query = db.query(models.User)
    if exclude_role:
        query = query.filter(models.User.role != exclude_role)
    users = query.order_by(models.User.created_at.desc()).all()
    return {"users": users}


@router.patch("/users/{user_id}")
async def update_user(
    user_id: UUID,
    payload: AdminUserUpdate,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> JSONResponse:
    del admin_user
    user = db.get(models.User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    updates = payload.model_dump(exclude_unset=True)
    for field, value in updates.items():
        setattr(user, field, value)
    db.add(user)
    db.commit()
    return JSONResponse({"status": "updated"})


@router.delete("/users/{user_id}")
async def delete_user(
    user_id: UUID,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> JSONResponse:
    del admin_user
    user = db.get(models.User, user_id)
    if not user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="User not found")
    db.delete(user)
    db.commit()
    return JSONResponse({"status": "deleted"})


@router.get("/feedback", response_model=AdminFeedbackList)
async def list_feedback(
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> AdminFeedbackList:
    del admin_user
    entries = (
        db.query(models.Feedback)
        .options(selectinload(models.Feedback.user))
        .order_by(models.Feedback.created_at.desc())
        .all()
    )
    results = []
    for entry in entries:
        results.append(
            {
                "id": entry.id,
                "user_id": entry.user_id,
                "message": entry.message,
                "is_read": entry.is_read,
                "archived": entry.archived,
                "created_at": entry.created_at,
                "user": entry.user,
                "user_name": entry.user.name if entry.user else None,
            }
        )
    return {"feedback": results}


@router.patch("/feedback/{feedback_id}")
async def update_feedback(
    feedback_id: UUID,
    payload: AdminFeedbackUpdate,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> JSONResponse:
    del admin_user
    entry = db.get(models.Feedback, feedback_id)
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Feedback not found")
    updates = payload.model_dump(exclude_unset=True)
    for field, value in updates.items():
        setattr(entry, field, value)
    db.add(entry)
    db.commit()
    return JSONResponse({"status": "updated"})


@router.post("/feedback/{feedback_id}/response")
async def respond_to_feedback(
    feedback_id: UUID,
    payload: AdminFeedbackResponseRequest,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> JSONResponse:
    entry = db.get(models.Feedback, feedback_id)
    if not entry:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Feedback entry not found")
    notification = models.Notification(
        user_id=payload.user_id,
        actor_id=admin_user.id,
        message=payload.message,
        type="admin_feedback_response",
        metadata_payload={"feedback_id": str(entry.id)},
    )
    db.add(notification)
    db.commit()
    return JSONResponse({"status": "sent"})


@router.get("/profile", response_model=AdminProfileResponse)
async def get_profile(
    admin_user: models.User = Depends(get_current_admin),
) -> AdminProfileResponse:
    return {"profile": AdminProfileData(id=admin_user.id, name=admin_user.name, status=admin_user.status)}


@router.patch("/profile", response_model=AdminProfileResponse)
async def update_profile(
    payload: AdminProfileUpdate,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> AdminProfileResponse:
    if str(payload.id) != str(admin_user.id):
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Cannot update another admin profile",
        )
    updates = payload.model_dump(exclude_unset=True)
    for field, value in updates.items():
        if field == "id":
            continue
        setattr(admin_user, field, value)
    db.add(admin_user)
    db.commit()
    return {"profile": AdminProfileData(id=admin_user.id, name=admin_user.name, status=admin_user.status)}


@router.post("/profile/password")
async def update_profile_password(
    payload: AdminPasswordUpdate,
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> JSONResponse:
    if not verify_password(payload.current_password, admin_user.password_hash):
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="Current password is incorrect",
        )
    admin_user.password_hash = get_password_hash(payload.new_password)
    db.add(admin_user)
    db.commit()
    return JSONResponse({"status": "updated"})


@router.get("/dashboard/stats", response_model=AdminDashboardStatsResponse)
async def dashboard_stats(
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> AdminDashboardStatsResponse:
    del admin_user
    one_week_ago = datetime.utcnow() - timedelta(days=7)
    active_users = db.query(models.User).filter(func.lower(models.User.status) == "active").count()
    posts_this_week = (
        db.query(models.CommunityPost)
        .filter(models.CommunityPost.created_at >= one_week_ago)
        .count()
    )
    lost_pet_alerts = db.query(models.CommunityPost).filter(models.CommunityPost.type == "missing").count()
    return {"stats": {"active_users": active_users, "posts_this_week": posts_this_week, "lost_pet_alerts": lost_pet_alerts}}


@router.get("/health", response_model=AdminHealthResponse)
async def health_check(
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> AdminHealthResponse:
    del admin_user
    database_status = "ok"
    try:
        db.query(models.User).limit(1).all()
    except Exception as exc:
        database_status = f"error: {exc}"
    storage_path = Path(__file__).resolve().parents[2] / "media"
    storage_status = "ok" if storage_path.exists() else "missing"
    return {"api": "ok", "database": database_status, "storage": storage_status}


@router.get("/usage", response_model=AdminUsageResponse)
async def usage_metrics(
    role: Optional[str] = Query(None, alias="role"),
    db: Session = Depends(get_db),
    admin_user: models.User = Depends(get_current_admin),
) -> AdminUsageResponse:
    del admin_user
    user_query = db.query(models.User)
    if role:
        user_query = user_query.filter(models.User.role == role)
    login_count = user_query.count()

    post_query = db.query(models.CommunityPost)
    if role:
        post_query = post_query.join(models.User, models.CommunityPost.user).filter(models.User.role == role)
    post_count = post_query.count()

    gps_query = db.query(models.LocationHistory).join(models.Pet, models.LocationHistory.pet).join(models.User, models.Pet.owner)
    if role:
        gps_query = gps_query.filter(models.User.role == role)
    gps_count = gps_query.count()

    behavior_query = db.query(models.BehaviorLog)
    if role:
        behavior_query = behavior_query.join(models.User, models.BehaviorLog.user).filter(models.User.role == role)
    behavior_count = behavior_query.count()

    return {
        "metrics": {
            "login_count": login_count,
            "post_count": post_count,
            "gps_count": gps_count,
            "behavior_count": behavior_count,
        }
    }