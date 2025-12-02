from pydantic import BaseModel, ConfigDict


class MediaUploadResponse(BaseModel):
    path: str
    url: str

    model_config = ConfigDict(from_attributes=True)
