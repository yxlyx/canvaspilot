import uuid

from pydantic import BaseModel, ConfigDict, Field


class UserResponse(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: uuid.UUID
    name: str
    email: str
    canvas_user_id: int | None = None


class TokenResponse(BaseModel):
    token: str
    user: UserResponse


class RegisterRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    name: str = Field(max_length=255)
    email: str = Field(max_length=320)
    password: str = Field(max_length=4096)


class LoginRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    email: str = Field(max_length=320)
    password: str = Field(max_length=4096)
