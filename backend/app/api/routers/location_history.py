from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy import func
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...db import models
from ...db.session import get_db
from ...schemas.location import LocationCreate, LocationRead

router = APIRouter(prefix="/location", tags=["location_history"])


@router.post("", response_model=LocationRead)
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


@router.post("/device", response_model=LocationRead)
async def create_device_location(
    payload: LocationCreate,
    db: Session = Depends(get_db),
) -> models.LocationHistory:
    device_mac = (payload.device_mac or "").strip()
    if not device_mac:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="device_mac is required for device uploads",
        )
    normalized = device_mac.lower()
    mapping = (
        db.query(models.DevicePetMap)
        .filter(func.lower(models.DevicePetMap.device_id) == normalized)
        .first()
    )
    if not mapping:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Device not registered",
        )
    location_data = payload.model_dump()
    location_data["pet_id"] = mapping.pet_id
    location_data["device_mac"] = device_mac
    location = models.LocationHistory(**location_data)
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


