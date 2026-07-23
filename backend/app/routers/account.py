from urllib.parse import quote

from fastapi import APIRouter, Depends, Request, Response, status
from sqlalchemy import delete
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.routers.auth import (
    BadAuthRequestError,
    _hash_password,
    _validate_password,
    _verify_password,
)
from app.schemas.auth import UserResponse
from app.schemas.settings import (
    AccountDeleteRequest,
    PasswordChangeRequest,
    PasswordConfirmationRequest,
    ProfileUpdateRequest,
)
from app.services.account import export_account

router = APIRouter(prefix="/account", tags=["account"])


def _require_password(user: User, password: str) -> None:
    if not _verify_password(password, user.password_hash):
        raise BadAuthRequestError(
            "invalid_password",
            "Current password is incorrect",
            status.HTTP_401_UNAUTHORIZED,
        )


@router.patch("/profile", response_model=UserResponse)
async def update_profile(
    payload: ProfileUpdateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    user.name = payload.name.strip()
    if not user.name:
        raise BadAuthRequestError("missing_name", "Enter your name")
    await db.commit()
    await db.refresh(user)
    return user


@router.post("/password", status_code=status.HTTP_204_NO_CONTENT)
async def change_password(
    payload: PasswordChangeRequest,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _require_password(user, payload.current_password)
    _validate_password(payload.new_password)
    if _verify_password(payload.new_password, user.password_hash):
        raise BadAuthRequestError("password_unchanged", "Choose a different password")
    user.password_hash = _hash_password(payload.new_password)
    user.auth_version = (user.auth_version or 0) + 1
    await db.commit()
    request.session.clear()
    return Response(status_code=status.HTTP_204_NO_CONTENT)


@router.post("/export")
async def download_account_archive(
    payload: PasswordConfirmationRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _require_password(user, payload.current_password)
    exported = await export_account(user, db)
    filename = quote(exported.filename, safe="-_.")
    return Response(
        content=exported.content,
        media_type=exported.media_type,
        headers={
            "Content-Disposition": f'attachment; filename="{filename}"',
            "X-Content-Type-Options": "nosniff",
            "Cache-Control": "no-store",
        },
    )


@router.delete("", status_code=status.HTTP_204_NO_CONTENT)
async def delete_account(
    payload: AccountDeleteRequest,
    request: Request,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    _require_password(user, payload.current_password)
    await db.execute(delete(User).where(User.id == user.id))
    await db.commit()
    request.session.clear()
    return Response(status_code=status.HTTP_204_NO_CONTENT)
