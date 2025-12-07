from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...db import models
from ...db.session import get_db
from ...schemas.location import LocationCreate, LocationRead

router = APIRouter(prefix="/location", tags=["location_history"])


@router.post("/", response_model=LocationRead)
async def create_location(
    payload: LocationCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.LocationHistory:
    location = models.LocationHistory(**payload.model_dump())
    db.add(location)
    db.commit()
    db.refresh(location)
    return location


@router.get("/pet/{pet_id}", response_model=List[LocationRead])
async def get_pet_locations(
    pet_id: str,
    limit: int | None = 100,
    db: Session = Depends(get_db),
) -> List[models.LocationHistory]:
    limit_count = limit if (limit and limit > 0) else 100
    return (
        db.query(models.LocationHistory)
        .filter(models.LocationHistory.pet_id == pet_id)
        .order_by(models.LocationHistory.timestamp.desc())
        .limit(limit_count)
        .all()
    )


@router.get("/pet/{pet_id}/latest", response_model=LocationRead)
async def get_latest_pet_location(pet_id: str, db: Session = Depends(get_db)) -> models.LocationHistory:
    location = (
        db.query(models.LocationHistory)
        .filter(models.LocationHistory.pet_id == pet_id)
        .order_by(models.LocationHistory.timestamp.desc())
        .first()
    )
    if not location:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")
    return location


@router.get("/firebase/{entry_id}", response_model=LocationRead)
async def get_location_by_firebase_entry(entry_id: str, db: Session = Depends(get_db)) -> models.LocationHistory:
    location = (
        db.query(models.LocationHistory)
        .filter(models.LocationHistory.firebase_entry_id == entry_id)
        .first()
    )
    if not location:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Location not found")
    return location
