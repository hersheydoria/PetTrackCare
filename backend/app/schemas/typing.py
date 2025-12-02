from pydantic import BaseModel, ConfigDict


class TypingStatusUpdate(BaseModel):
    chat_with_id: str
    is_typing: bool

    model_config = ConfigDict(from_attributes=True)


class TypingStatusRead(BaseModel):
    chat_with_id: str
    is_typing: bool

    model_config = ConfigDict(from_attributes=True)
