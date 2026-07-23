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


def create_app_token(user_id: uuid.UUID, auth_version: int = 0) -> str:
    settings = get_settings()
    payload = {
        "sub": str(user_id),
        "ver": auth_version,
        "exp": datetime.now(UTC).timestamp() + 7 * 24 * 3600,
    }
    return jwt.encode(payload, settings.session_secret, algorithm=JWT_ALGORITHM)


def _decode_bearer_token(token: str) -> tuple[str, int] | None:
    settings = get_settings()
    try:
        payload = jwt.decode(token, settings.session_secret, algorithms=[JWT_ALGORITHM])
        subject = payload.get("sub")
        if not subject:
            return None
        return subject, int(payload.get("ver", 0))
    except (jwt.InvalidTokenError, jwt.ExpiredSignatureError, TypeError, ValueError):
        return None


async def get_current_user(request: Request, db: AsyncSession = Depends(get_db)) -> User:
    user_id: str | None = None
    supplied_version = 0

    auth_header = request.headers.get("authorization", "")
    if auth_header.startswith("Bearer "):
        token = auth_header[7:]
        decoded = _decode_bearer_token(token)
        if decoded:
            user_id, supplied_version = decoded

    if not user_id:
        user_id = request.session.get("user_id")
        try:
            supplied_version = int(request.session.get("auth_version", 0))
        except (TypeError, ValueError):
            raise UnauthorizedError() from None

    if not user_id:
        raise UnauthorizedError()

    try:
        parsed_user_id = uuid.UUID(user_id)
    except (AttributeError, TypeError, ValueError):
        raise UnauthorizedError() from None

    result = await db.execute(select(User).where(User.id == parsed_user_id))
    user = result.scalar_one_or_none()
    if not user or int(user.auth_version or 0) != supplied_version:
        raise UnauthorizedError()
    return user
