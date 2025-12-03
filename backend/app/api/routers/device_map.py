from fastapi import APIRouter, Depends, HTTPException, Response, status
from sqlalchemy.orm import Session

from ...db import models
from ...db.session import get_db
from ...schemas.device_map import DevicePetMapCreate, DevicePetMapRead

router = APIRouter(prefix="/device-map", tags=["device_map"])


@router.post("/", response_model=DevicePetMapRead)
async def assign_device_to_pet(
    payload: DevicePetMapCreate,
    db: Session = Depends(get_db),
) -> models.DevicePetMap:
    mapping = (
        db.query(models.DevicePetMap)
        .filter(models.DevicePetMap.pet_id == payload.pet_id)
        .first()
    )
    if mapping:
        mapping.device_id = payload.device_id
    else:
        mapping = models.DevicePetMap(pet_id=payload.pet_id, device_id=payload.device_id)
        db.add(mapping)
    db.commit()
    db.refresh(mapping)
    return mapping


@router.get("/pet/{pet_id}", response_model=DevicePetMapRead)
async def read_device_for_pet(
    pet_id: str,
    db: Session = Depends(get_db),
) -> models.DevicePetMap:
    mapping = (
        db.query(models.DevicePetMap)
        .filter(models.DevicePetMap.pet_id == pet_id)
        .first()
    )
    if not mapping:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Device map not found")
    return mapping


@router.delete("/pet/{pet_id}")
async def remove_device_for_pet(
    pet_id: str,
    db: Session = Depends(get_db),
) -> Response:
    mapping = (
        db.query(models.DevicePetMap)
        .filter(models.DevicePetMap.pet_id == pet_id)
        .first()
    )
    if mapping:
        db.delete(mapping)
        db.commit()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
