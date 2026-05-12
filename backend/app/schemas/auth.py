import uuid

from pydantic import BaseModel, ConfigDict


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    email: str
    canvas_user_id: int


class TokenResponse(BaseModel):
    token: str
    user: UserResponse
