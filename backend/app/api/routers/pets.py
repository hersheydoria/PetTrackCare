from typing import List

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session

from ...api.deps import get_current_user
from ...db import models
from ...db.session import get_db
from ...schemas.pet import PetCreate, PetRead, PetUpdate

router = APIRouter(prefix="/pets", tags=["pets"])


def _is_user_sitter_for_pet(db: Session, pet: models.Pet, sitter: models.User) -> bool:
    if sitter.role != "Pet Sitter":
        return False
    job = (
        db.query(models.SittingJob)
        .filter(models.SittingJob.pet_id == pet.id)
        .filter(models.SittingJob.sitter_id == sitter.id)
        .filter(models.SittingJob.status != "Cancelled")
        .first()
    )
    return job is not None


@router.post("/", response_model=PetRead)
async def create_pet(
    payload: PetCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Pet:
    owner_id = payload.owner_id or str(current_user.id)
    pet = models.Pet(owner_id=owner_id, **payload.model_dump(exclude={"owner_id"}))
    db.add(pet)
    db.commit()
    db.refresh(pet)
    return pet


@router.get("/", response_model=List[PetRead])
async def list_pets(
    owner_id: str | None = None,
    pet_ids: str | None = None,
    db: Session = Depends(get_db),
) -> List[models.Pet]:
    query = db.query(models.Pet)
    if owner_id:
        query = query.filter(models.Pet.owner_id == owner_id)
    if pet_ids:
        parsed_ids = [pet_id.strip() for pet_id in pet_ids.split(",") if pet_id.strip()]
        if parsed_ids:
            query = query.filter(models.Pet.id.in_(parsed_ids))
    return query.all()


@router.get("/{pet_id}", response_model=PetRead)
async def read_pet(pet_id: str, db: Session = Depends(get_db)) -> models.Pet:
    pet = db.get(models.Pet, pet_id)
    if not pet:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pet not found")
    return pet


@router.patch("/{pet_id}", response_model=PetRead)
async def update_pet(
    pet_id: str,
    payload: PetUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> models.Pet:
    pet = db.get(models.Pet, pet_id)
    if not pet:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pet not found")
    allowed_owner = str(pet.owner_id) == str(current_user.id)
    allowed_sitter = _is_user_sitter_for_pet(db, pet, current_user)
    if not allowed_owner and not allowed_sitter:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not authorized to modify this pet")
    for field, value in payload.model_dump(exclude_unset=True).items():
        setattr(pet, field, value)
    db.add(pet)
    db.commit()
    db.refresh(pet)
    return pet


@router.delete("/{pet_id}")
async def delete_pet(
    pet_id: str,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> dict:
    pet = db.get(models.Pet, pet_id)
    if not pet:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Pet not found")
    if str(pet.owner_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not the pet owner")
    db.delete(pet)
    db.commit()
    return {"status": "deleted"}
