from datetime import datetime
from typing import List, Optional
from uuid import UUID

from pydantic import BaseModel, ConfigDict, EmailStr


class AdminLoginRequest(BaseModel):
    email: str
    password: str


class AdminUserSummary(BaseModel):
    id: UUID
    name: Optional[str] = None
    email: Optional[EmailStr] = None
    role: str
    status: Optional[str] = None
    profile_picture: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


class AdminReportPostSummary(BaseModel):
    id: UUID
    content: str
    image_url: Optional[str] = None
    type: Optional[str] = None
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class AdminReportItem(BaseModel):
    id: UUID
    post_id: UUID
    reason: str
    created_at: datetime
    post_deleted: bool
    post_content: Optional[str] = None
    user_name: Optional[str] = None
    post: Optional[AdminReportPostSummary] = None
    user: Optional[AdminUserSummary] = None

    model_config = ConfigDict(from_attributes=True)


class AdminReportList(BaseModel):
    reports: List[AdminReportItem]


class AdminUsersResponse(BaseModel):
    users: List[AdminUserSummary]


class AdminUserUpdate(BaseModel):
    name: Optional[str] = None
    role: Optional[str] = None
    status: Optional[str] = None


class AdminFeedbackItem(BaseModel):
    id: UUID
    user_id: UUID
    user_name: Optional[str] = None
    user: Optional[AdminUserSummary] = None
    message: str
    is_read: bool
    archived: bool
    created_at: datetime

    model_config = ConfigDict(from_attributes=True)


class AdminFeedbackList(BaseModel):
    feedback: List[AdminFeedbackItem]


class AdminFeedbackUpdate(BaseModel):
    is_read: Optional[bool] = None
    archived: Optional[bool] = None


class AdminFeedbackResponseRequest(BaseModel):
    user_id: UUID
    message: str


class AdminProfileData(BaseModel):
    id: UUID
    name: Optional[str] = None
    status: Optional[str] = None

    model_config = ConfigDict(from_attributes=True)


class AdminProfileResponse(BaseModel):
    profile: AdminProfileData


class AdminProfileUpdate(BaseModel):
    id: UUID
    name: Optional[str] = None
    status: Optional[str] = None


class AdminPasswordUpdate(BaseModel):
    current_password: str
    new_password: str


class AdminDashboardStats(BaseModel):
    active_users: int
    posts_this_week: int
    lost_pet_alerts: int


class AdminDashboardStatsResponse(BaseModel):
    stats: AdminDashboardStats


class AdminHealthResponse(BaseModel):
    api: str
    database: str
    storage: str


class AdminUsageMetrics(BaseModel):
    login_count: int
    post_count: int
    gps_count: int
    behavior_count: int


class AdminUsageResponse(BaseModel):
    metrics: AdminUsageMetrics
