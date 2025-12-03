from fastapi import FastAPI
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
)
from .db.base import Base
from .db.session import engine

app = FastAPI(title="PetTrackCare FastAPI", version="0.1.0")

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
]

for router in router_modules:
    app.include_router(router)


@app.get("/")
async def root() -> dict:
    return {"message": "PetTrackCare FastAPI backend is ready"}


@app.on_event("startup")
async def on_startup() -> None:
    Base.metadata.create_all(bind=engine)


MEDIA_PATH = Path(__file__).resolve().parents[0].parent / "media"
MEDIA_PATH.mkdir(parents=True, exist_ok=True)
app.mount("/media", StaticFiles(directory=MEDIA_PATH), name="media")
