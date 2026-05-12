import uuid
from datetime import UTC, datetime

import jwt
from fastapi import Depends, Request
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import get_settings
from app.db.database import get_db
from app.exceptions import UnauthorizedError
from app.models.user import User

JWT_ALGORITHM = "HS256"


def create_app_token(user_id: uuid.UUID) -> str:
    settings = get_settings()
    payload = {
        "sub": str(user_id),
        "exp": datetime.now(UTC).timestamp() + 7 * 24 * 3600,
    }
    return jwt.encode(payload, settings.session_secret, algorithm=JWT_ALGORITHM)


def _decode_bearer_token(token: str) -> str | None:
    settings = get_settings()
    try:
        payload = jwt.decode(token, settings.session_secret, algorithms=[JWT_ALGORITHM])
        return payload.get("sub")
    except (jwt.InvalidTokenError, jwt.ExpiredSignatureError):
        return None


async def get_current_user(request: Request, db: AsyncSession = Depends(get_db)) -> User:
    user_id: str | None = None

    auth_header = request.headers.get("authorization", "")
    if auth_header.startswith("Bearer "):
        token = auth_header[7:]
        user_id = _decode_bearer_token(token)

    if not user_id:
        user_id = request.session.get("user_id")

    if not user_id:
        raise UnauthorizedError()

    result = await db.execute(select(User).where(User.id == uuid.UUID(user_id)))
    user = result.scalar_one_or_none()
    if not user:
        raise UnauthorizedError()
    return user
