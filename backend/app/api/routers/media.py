import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, File, Form, HTTPException, Request, UploadFile

from ...api.deps import get_current_user
from ...db import models
from ...schemas.media import MediaUploadResponse

router = APIRouter(prefix="/media", tags=["media"])

BASE_DIR = Path(__file__).resolve().parents[3]
MEDIA_ROOT = BASE_DIR / "media"
IMAGE_DIR = MEDIA_ROOT / "images"
VOICE_DIR = MEDIA_ROOT / "voice"
COMMUNITY_DIR = MEDIA_ROOT / "community"

for folder in (MEDIA_ROOT, IMAGE_DIR, VOICE_DIR, COMMUNITY_DIR):
    folder.mkdir(parents=True, exist_ok=True)

ALLOWED_TYPES = {
    "images": IMAGE_DIR,
    "voice": VOICE_DIR,
    "community": COMMUNITY_DIR,
}


@router.post("/upload", response_model=MediaUploadResponse)
async def upload_media(
    request: Request,
    file: UploadFile = File(...),
    type: str = Form("images"),
    _user: models.User = Depends(get_current_user),
) -> MediaUploadResponse:
    if type not in ALLOWED_TYPES:
        raise HTTPException(status_code=400, detail="Unsupported media type")

    suffix = Path(file.filename).suffix or ""
    if len(suffix) > 10:
        suffix = suffix[:10]
    filename = f"{uuid.uuid4().hex}{suffix}"
    destination = ALLOWED_TYPES[type] / filename
    content = await file.read()
    destination.write_bytes(content)
    relative_path = f"{type}/{filename}"
    file_url = request.url_for("media", path=relative_path)
    return MediaUploadResponse(path=relative_path, url=str(file_url))