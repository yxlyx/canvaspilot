import secrets
from urllib.parse import urlencode

import httpx
from cryptography.fernet import Fernet
from fastapi import APIRouter, Depends, Request
from fastapi.responses import RedirectResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings, get_settings
from app.db.database import get_db
from app.dependencies import create_app_token, get_current_user
from app.models.user import User
from app.schemas.auth import UserResponse

router = APIRouter(prefix="/auth", tags=["auth"])


def _get_fernet(settings: Settings) -> Fernet:
    return Fernet(settings.canvas_token_secret.encode())


@router.get("/canvas/start")
async def oauth_start(request: Request, settings: Settings = Depends(get_settings)):
    state = secrets.token_urlsafe(32)
    request.session["oauth_state"] = state

    params = urlencode(
        {
            "client_id": settings.canvas_client_id,
            "response_type": "code",
            "redirect_uri": settings.canvas_oauth_redirect_uri,
            "state": state,
            "scope": "url:GET|/api/v1/users/:user_id/profile "
            "url:GET|/api/v1/courses "
            "url:GET|/api/v1/courses/:course_id/discussion_topics "
            "url:GET|/api/v1/courses/:course_id/assignments "
            "url:GET|/api/v1/courses/:course_id/files "
            "url:GET|/api/v1/calendar_events",
        }
    )
    return RedirectResponse(f"{settings.canvas_base}/login/oauth2/auth?{params}")


@router.get("/canvas/callback")
async def oauth_callback(
    request: Request,
    code: str,
    state: str,
    settings: Settings = Depends(get_settings),
    db: AsyncSession = Depends(get_db),
):
    expected_state = request.session.pop("oauth_state", None)
    if not expected_state or state != expected_state:
        return RedirectResponse(f"{settings.frontend_url}/login?error=oauth_failed")

    async with httpx.AsyncClient() as client:
        token_resp = await client.post(
            f"{settings.canvas_base}/login/oauth2/token",
            data={
                "grant_type": "authorization_code",
                "client_id": settings.canvas_client_id,
                "client_secret": settings.canvas_client_secret,
                "redirect_uri": settings.canvas_oauth_redirect_uri,
                "code": code,
            },
        )
        if token_resp.status_code != 200:
            return RedirectResponse(f"{settings.frontend_url}/login?error=oauth_failed")

        token_data = token_resp.json()
        access_token = token_data["access_token"]
        refresh_token = token_data.get("refresh_token", "")

        profile_resp = await client.get(
            f"{settings.canvas_base}/api/v1/users/self/profile",
            headers={"Authorization": f"Bearer {access_token}"},
        )
        if profile_resp.status_code != 200:
            return RedirectResponse(f"{settings.frontend_url}/login?error=oauth_failed")

        profile = profile_resp.json()

    fernet = _get_fernet(settings)
    encrypted_access = fernet.encrypt(access_token.encode()).decode()
    encrypted_refresh = fernet.encrypt(refresh_token.encode()).decode()

    canvas_user_id = profile["id"]
    result = await db.execute(select(User).where(User.canvas_user_id == canvas_user_id))
    user = result.scalar_one_or_none()

    if user:
        user.name = profile.get("name", user.name)
        user.email = profile.get("primary_email", user.email)
        user.encrypted_access_token = encrypted_access
        user.encrypted_refresh_token = encrypted_refresh
    else:
        user = User(
            canvas_user_id=canvas_user_id,
            name=profile.get("name", ""),
            email=profile.get("primary_email", ""),
            encrypted_access_token=encrypted_access,
            encrypted_refresh_token=encrypted_refresh,
        )
        db.add(user)

    await db.commit()
    await db.refresh(user)

    request.session["user_id"] = str(user.id)
    app_token = create_app_token(user.id)
    return RedirectResponse(f"{settings.frontend_url}/dashboard?token={app_token}")


@router.get("/me", response_model=UserResponse)
async def get_me(user: User = Depends(get_current_user)):
    return user


@router.post("/logout")
async def logout(request: Request):
    request.session.clear()
    return {"ok": True}
