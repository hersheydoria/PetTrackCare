from datetime import date
from typing import List, Optional

from fastapi import APIRouter, Depends, HTTPException, status
from sqlalchemy.orm import Session, joinedload

from ...api.deps import get_current_user
from ...api.utils.sitter import get_or_create_sitter_profile
from ...db import models
from ...db.session import get_db
from ...schemas.sitting_job import SittingJobCreate, SittingJobDetail, SittingJobUpdate

router = APIRouter(prefix="/sitting_jobs", tags=["sitting_jobs"])


def _resolve_sitter_user(db: Session, identifier: str) -> Optional[models.User]:
    sitter = get_or_create_sitter_profile(db, identifier)
    if not sitter:
        return None
    return sitter.user


def _serialize_job(job: models.SittingJob, db: Session) -> SittingJobDetail:
    pet = job.pet
    owner = pet.owner if pet else None
    return SittingJobDetail(
        id=job.id,
        sitter_id=job.sitter_id,
        pet_id=job.pet_id,
        pet_name=pet.name if pet else None,
        pet_type=pet.type if pet else None,
        pet_profile_picture=pet.profile_picture if pet else None,
        owner_id=owner.id if owner else None,
        owner_name=owner.name if owner else None,
        status=job.status or "Pending",
        start_date=job.start_date,
        end_date=job.end_date,
        created_at=job.created_at,
    )


def _query_owner_jobs(db: Session, owner_id: str, status: Optional[str]) -> List[models.SittingJob]:
    query = (
        db.query(models.SittingJob)
        .options(joinedload(models.SittingJob.pet).joinedload(models.Pet.owner))
        .join(models.Pet)
        .filter(models.Pet.owner_id == owner_id)
    )
    if status:
        query = query.filter(models.SittingJob.status == status)
    return query.order_by(models.SittingJob.created_at.desc()).all()


@router.get("/sitter/{sitter_id}", response_model=List[SittingJobDetail])
async def list_jobs_for_sitter(sitter_id: str, db: Session = Depends(get_db)) -> List[SittingJobDetail]:
    sitter_user = _resolve_sitter_user(db, sitter_id)
    if not sitter_user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sitter profile not found")
    jobs = (
        db.query(models.SittingJob)
        .options(joinedload(models.SittingJob.pet).joinedload(models.Pet.owner))
        .filter(models.SittingJob.sitter_id == sitter_user.id)
        .order_by(models.SittingJob.created_at.desc())
        .all()
    )
    return [_serialize_job(job, db) for job in jobs]


@router.get("/owner/{owner_id}", response_model=List[SittingJobDetail])
async def list_jobs_for_owner(
    owner_id: str, status: Optional[str] = None, db: Session = Depends(get_db)
) -> List[SittingJobDetail]:
    jobs = _query_owner_jobs(db, owner_id, status)
    return [_serialize_job(job, db) for job in jobs]


@router.post("/", response_model=SittingJobDetail, status_code=status.HTTP_201_CREATED)
async def create_sitting_job(
    payload: SittingJobCreate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> SittingJobDetail:
    pet = db.get(models.Pet, payload.pet_id)
    if not pet or str(pet.owner_id) != str(current_user.id):
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Cannot create job for another owner")
    sitter_user = _resolve_sitter_user(db, str(payload.sitter_id))
    if not sitter_user:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Sitter profile not found")
    job = models.SittingJob(
        sitter_id=sitter_user.id,
        pet_id=payload.pet_id,
        start_date=payload.start_date,
        end_date=payload.end_date,
        status=payload.status or "Pending",
    )
    db.add(job)
    db.commit()
    db.refresh(job)
    return _serialize_job(job, db)


@router.patch("/{job_id}", response_model=SittingJobDetail)
async def update_sitting_job(
    job_id: str,
    payload: SittingJobUpdate,
    db: Session = Depends(get_db),
    current_user: models.User = Depends(get_current_user),
) -> SittingJobDetail:
    job = db.get(models.SittingJob, job_id)
    if not job:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail="Job not found")
    pet = db.get(models.Pet, job.pet_id)
    owner_id = pet.owner_id if pet else None
    allowed = owner_id == current_user.id or job.sitter_id == current_user.id
    if not allowed:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail="Not authorized to update job")
    updates = payload.model_dump(exclude_unset=True)
    if payload.status == "Active" and not payload.start_date:
        updates["start_date"] = date.today()
    if payload.status == "Completed" and not payload.end_date:
        updates["end_date"] = date.today()
    for field, value in updates.items():
        setattr(job, field, value)
    db.add(job)
    db.commit()
    db.refresh(job)
    return _serialize_job(job, db)