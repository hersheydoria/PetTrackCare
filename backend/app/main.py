from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.staticfiles import StaticFiles
from pathlib import Path

from .api.routers import (
    auth,
    users,
    feedback,
    pets,
    posts,
    notifications,
    location_history,
    messages,
    sitters,
    sitting_jobs,
    behavior_logs,
    community,
    media,
    device_map,
    admin,
)
from .core.config import settings
from .core.security import get_password_hash
from .db import models
from .db.base import Base
from .db.session import SessionLocal, engine

app = FastAPI(title="PetTrackCare FastAPI", version="0.1.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["http://localhost:5173", "http://localhost:5174", "https://pettrackcare.local"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

router_modules = [
    auth.router,
    users.router,
    feedback.router,
    pets.router,
    posts.router,
    notifications.router,
    location_history.router,
    messages.router,
    sitters.router,
    sitting_jobs.router,
    behavior_logs.router,
    community.router,
    media.router,
    device_map.router,
    admin.router,
]

def ensure_default_admin() -> None:
    email = (settings.default_admin_email or "").strip()
    password = settings.default_admin_password
    if not email or not password:
        return
    db = SessionLocal()
    try:
        user = db.query(models.User).filter(models.User.email == email).first()
        if user:
            if (user.role or "").lower() != "admin":
                user.role = "Admin"
                user.status = user.status or "Active"
                db.add(user)
                db.commit()
            return
        admin = models.User(
            email=email,
            password_hash=get_password_hash(password),
            name=settings.default_admin_name,
            role="Admin",
            status="Active",
        )
        db.add(admin)
        db.commit()
    except Exception as exc:
        db.rollback()
        print(f"[STARTUP] Failed to ensure default admin: {exc}")
    finally:
        db.close()

for router in router_modules:
    app.include_router(router)


@app.get("/")
async def root() -> dict:
    return {"message": "PetTrackCare FastAPI backend is ready"}


@app.on_event("startup")
async def on_startup() -> None:
    Base.metadata.create_all(bind=engine)
    ensure_default_admin()


MEDIA_PATH = Path(__file__).resolve().parents[0].parent / "media"
MEDIA_PATH.mkdir(parents=True, exist_ok=True)
app.mount("/media", StaticFiles(directory=MEDIA_PATH), name="media")
