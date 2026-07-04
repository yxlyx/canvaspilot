import base64
import hashlib
import hmac
import secrets

from fastapi import APIRouter, Depends, Request, status
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import create_app_token, get_current_user
from app.exceptions import WikiBaseError
from app.models.user import User
from app.schemas.auth import LoginRequest, RegisterRequest, TokenResponse, UserResponse

router = APIRouter(prefix="/auth", tags=["auth"])

PASSWORD_SCHEME = "pbkdf2_sha256"
PASSWORD_ITERATIONS = 210_000


class BadAuthRequestError(WikiBaseError):
    def __init__(self, error: str, detail: str, status_code: int = status.HTTP_400_BAD_REQUEST):
        super().__init__(status_code, error, detail)


def _normalize_email(email: str) -> str:
    return email.strip().lower()


def _validate_email(email: str) -> None:
    if "@" not in email or email.startswith("@") or email.endswith("@"):
        raise BadAuthRequestError("invalid_email", "Enter a valid email address")
    local, domain = email.rsplit("@", 1)
    if not local or "." not in domain or domain.endswith("."):
        raise BadAuthRequestError("invalid_email", "Enter a valid email address")


def _validate_password(password: str) -> None:
    if len(password) < 8:
        raise BadAuthRequestError("weak_password", "Password must be at least 8 characters")


def _hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, PASSWORD_ITERATIONS)
    salt_b64 = base64.urlsafe_b64encode(salt).decode()
    digest_b64 = base64.urlsafe_b64encode(digest).decode()
    return f"{PASSWORD_SCHEME}${PASSWORD_ITERATIONS}${salt_b64}${digest_b64}"


def _verify_password(password: str, encoded: str | None) -> bool:
    if not encoded:
        return False
    try:
        scheme, iterations_raw, salt_b64, digest_b64 = encoded.split("$", 3)
        if scheme != PASSWORD_SCHEME:
            return False
        iterations = int(iterations_raw)
        salt = base64.urlsafe_b64decode(salt_b64.encode())
        expected = base64.urlsafe_b64decode(digest_b64.encode())
    except (ValueError, TypeError):
        return False

    actual = hashlib.pbkdf2_hmac("sha256", password.encode(), salt, iterations)
    return hmac.compare_digest(actual, expected)


def _token_response(user: User) -> TokenResponse:
    return TokenResponse(token=create_app_token(user.id), user=UserResponse.model_validate(user))


@router.post("/register", response_model=TokenResponse, status_code=status.HTTP_201_CREATED)
async def register(payload: RegisterRequest, request: Request, db: AsyncSession = Depends(get_db)):
    name = payload.name.strip()
    email = _normalize_email(payload.email)

    if not name:
        raise BadAuthRequestError("missing_name", "Enter your name")
    _validate_email(email)
    _validate_password(payload.password)

    result = await db.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    if user:
        raise BadAuthRequestError(
            "email_taken",
            "An account already exists for that email",
            status.HTTP_409_CONFLICT,
        )

    user = User(name=name, email=email, password_hash=_hash_password(payload.password))
    db.add(user)
    await db.commit()
    await db.refresh(user)

    request.session["user_id"] = str(user.id)
    return _token_response(user)


@router.post("/login", response_model=TokenResponse)
async def login(payload: LoginRequest, request: Request, db: AsyncSession = Depends(get_db)):
    email = _normalize_email(payload.email)
    result = await db.execute(select(User).where(User.email == email))
    user = result.scalar_one_or_none()
    if not user or not _verify_password(payload.password, user.password_hash):
        raise BadAuthRequestError(
            "invalid_credentials",
            "Email or password is incorrect",
            status.HTTP_401_UNAUTHORIZED,
        )

    request.session["user_id"] = str(user.id)
    return _token_response(user)


@router.get("/me", response_model=UserResponse)
async def get_me(user: User = Depends(get_current_user)):
    return user


@router.post("/logout")
async def logout(request: Request):
    request.session.clear()
    return {"ok": True}
