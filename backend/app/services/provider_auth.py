import base64
import hashlib
import secrets
import uuid
from datetime import UTC, datetime, timedelta
from urllib.parse import urlencode

import httpx
import jwt
from sqlalchemy import delete, func, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings, get_settings
from app.exceptions import NotFoundError, WikiBaseError
from app.models.m3 import ProviderAuthorizationSession, ProviderSetting
from app.models.user import User
from app.schemas.m3 import (
    ProviderAuthorizationRequest,
    ProviderAuthorizationSessionResponse,
)

AUTH_SESSION_TTL = timedelta(minutes=10)
REFRESH_MARGIN = timedelta(minutes=5)
MAX_TOKEN_RESPONSE_BYTES = 256 * 1024
MAX_PENDING_SESSIONS = 5
MAX_SESSION_RECORDS = 20
AUTH_SESSION_RETENTION = timedelta(hours=24)
CHATGPT_SCOPES = "openid profile email offline_access"


def browser_auth_enabled(settings: Settings | None = None) -> bool:
    settings = settings or get_settings()
    return bool(settings.chatgpt_oauth_client_id.strip())


def _b64url(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode()


def _state_hash(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _authorization_url(state: str, challenge: str, nonce: str, settings: Settings) -> str:
    query = urlencode(
        {
            "response_type": "code",
            "client_id": settings.chatgpt_oauth_client_id,
            "redirect_uri": settings.chatgpt_oauth_redirect_uri,
            "scope": CHATGPT_SCOPES,
            "code_challenge": challenge,
            "code_challenge_method": "S256",
            "state": state,
            "nonce": nonce,
        }
    )
    return f"{settings.chatgpt_oauth_authorize_url}?{query}"


async def create_authorization_session(
    user: User,
    provider: str,
    payload: ProviderAuthorizationRequest,
    db: AsyncSession,
) -> ProviderAuthorizationSessionResponse:
    settings = get_settings()
    if provider != "chatgpt":
        raise NotFoundError("Provider browser authentication is not available")
    if not browser_auth_enabled(settings):
        raise WikiBaseError(
            409,
            "browser_auth_unavailable",
            "Browser sign-in is unavailable until an approved OAuth client is configured",
        )
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"provider-auth-start:{user.id}:{provider}"},
    )
    now = datetime.now(UTC)
    await db.execute(
        delete(ProviderAuthorizationSession).where(
            ProviderAuthorizationSession.user_id == user.id,
            ProviderAuthorizationSession.provider == provider,
            ProviderAuthorizationSession.created_at < now - AUTH_SESSION_RETENTION,
        )
    )
    await db.execute(
        delete(ProviderAuthorizationSession).where(
            ProviderAuthorizationSession.user_id == user.id,
            ProviderAuthorizationSession.provider == provider,
            ProviderAuthorizationSession.status == "pending",
            ProviderAuthorizationSession.expires_at <= now,
        )
    )
    pending = await db.scalar(
        select(func.count(ProviderAuthorizationSession.id)).where(
            ProviderAuthorizationSession.user_id == user.id,
            ProviderAuthorizationSession.provider == provider,
            ProviderAuthorizationSession.status == "pending",
        )
    )
    total = await db.scalar(
        select(func.count(ProviderAuthorizationSession.id)).where(
            ProviderAuthorizationSession.user_id == user.id,
            ProviderAuthorizationSession.provider == provider,
        )
    )
    if pending is not None and pending >= MAX_PENDING_SESSIONS:
        raise WikiBaseError(
            429,
            "too_many_authorization_sessions",
            "Cancel an earlier browser sign-in or wait for it to expire",
        )
    if total is not None and total >= MAX_SESSION_RECORDS:
        raise WikiBaseError(
            429,
            "authorization_history_full",
            "Browser sign-in history is full. Try again after older records expire.",
        )
    verifier = _b64url(secrets.token_bytes(48))
    challenge = _b64url(hashlib.sha256(verifier.encode()).digest())
    session_id = uuid.uuid4()
    state = f"{session_id}.{_b64url(secrets.token_bytes(32))}"
    nonce = _b64url(secrets.token_bytes(32))
    browser_binding = _b64url(secrets.token_bytes(32))
    from app.services.providers import encrypt_provider_key

    encrypted_verifier, key_id = encrypt_provider_key(verifier, settings)
    expires_at = datetime.now(UTC) + AUTH_SESSION_TTL
    auth_session = ProviderAuthorizationSession(
        id=session_id,
        user_id=user.id,
        provider=provider,
        auth_method="oauth_code",
        state_hash=_state_hash(state),
        encrypted_pkce_verifier=encrypted_verifier,
        encryption_key_id=key_id,
        nonce_hash=_state_hash(nonce),
        browser_binding_hash=_state_hash(browser_binding),
        return_path=payload.return_path,
        status="pending",
        expires_at=expires_at,
    )
    db.add(auth_session)
    await db.commit()
    return ProviderAuthorizationSessionResponse(
        id=session_id,
        provider=provider,
        status="pending",
        authorization_url=_authorization_url(state, challenge, nonce, settings),
        browser_binding=browser_binding,
        expires_at=expires_at,
    )


async def get_authorization_session(
    user: User, session_id: uuid.UUID, db: AsyncSession
) -> ProviderAuthorizationSessionResponse:
    auth_session = await db.scalar(
        select(ProviderAuthorizationSession).where(
            ProviderAuthorizationSession.id == session_id,
            ProviderAuthorizationSession.user_id == user.id,
        )
    )
    if auth_session is None:
        raise NotFoundError("Provider authorization session not found")
    now = datetime.now(UTC)
    if auth_session.status == "pending" and auth_session.expires_at <= now:
        auth_session.status = "expired"
        auth_session.error_code = "authorization_expired"
        auth_session.error_message = "Browser sign-in expired. Start again."
        auth_session.consumed_at = now
        auth_session.encrypted_pkce_verifier = None
        await db.commit()
    return ProviderAuthorizationSessionResponse(
        id=auth_session.id,
        provider=auth_session.provider,
        status=auth_session.status,
        expires_at=auth_session.expires_at,
        error_code=auth_session.error_code,
        error_message=auth_session.error_message,
    )


async def cancel_authorization_session(user: User, session_id: uuid.UUID, db: AsyncSession) -> None:
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"provider-auth:{session_id}"},
    )
    auth_session = await db.scalar(
        select(ProviderAuthorizationSession).where(
            ProviderAuthorizationSession.id == session_id,
            ProviderAuthorizationSession.user_id == user.id,
        )
    )
    if auth_session is None:
        raise NotFoundError("Provider authorization session not found")
    if auth_session.status == "pending":
        auth_session.status = "cancelled"
        auth_session.consumed_at = datetime.now(UTC)
        auth_session.encrypted_pkce_verifier = None
        await db.flush()


async def _token_request(data: dict[str, str], settings: Settings) -> dict:
    try:
        async with httpx.AsyncClient(
            timeout=15,
            follow_redirects=False,
            limits=httpx.Limits(max_connections=10, max_keepalive_connections=5),
        ) as client:
            response = await client.post(settings.chatgpt_oauth_token_url, data=data)
    except (httpx.TimeoutException, httpx.NetworkError) as exc:
        raise WikiBaseError(
            502, "provider_auth_unavailable", "The provider sign-in service is unavailable"
        ) from exc
    if len(response.content) > MAX_TOKEN_RESPONSE_BYTES:
        raise WikiBaseError(502, "invalid_token_response", "The provider response was too large")
    try:
        payload = response.json()
    except ValueError as exc:
        raise WikiBaseError(
            502, "invalid_token_response", "The provider returned an invalid sign-in response"
        ) from exc
    if not response.is_success:
        code = payload.get("error") if isinstance(payload, dict) else None
        if code == "invalid_grant":
            raise WikiBaseError(409, "reauth_required", "Browser sign-in must be started again")
        raise WikiBaseError(502, "token_exchange_failed", "The provider rejected sign-in")
    if not isinstance(payload, dict) or not isinstance(payload.get("access_token"), str):
        raise WikiBaseError(502, "invalid_token_response", "The provider omitted the access token")
    return payload


async def _verified_account_details(
    payload: dict,
    nonce_hash: str,
    settings: Settings,
) -> tuple[str, str, str | None]:
    id_token = payload.get("id_token")
    if not isinstance(id_token, str) or not id_token:
        raise WikiBaseError(502, "invalid_id_token", "The provider omitted account identity")
    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=False) as client:
            response = await client.get(settings.chatgpt_oauth_jwks_url)
        if not response.is_success or len(response.content) > MAX_TOKEN_RESPONSE_BYTES:
            raise WikiBaseError(
                502, "identity_verification_failed", "Provider identity keys are unavailable"
            )
        jwk_set = jwt.PyJWKSet.from_dict(response.json())
        key_id = jwt.get_unverified_header(id_token).get("kid")
        signing_key = next((item.key for item in jwk_set.keys if item.key_id == key_id), None)
        if signing_key is None:
            raise WikiBaseError(
                502, "identity_verification_failed", "Provider identity key was not found"
            )
        claims = jwt.decode(
            id_token,
            signing_key,
            algorithms=["RS256"],
            audience=settings.chatgpt_oauth_client_id,
            issuer="https://auth.openai.com",
            options={"require": ["exp", "iat", "iss", "aud", "nonce", "sub"]},
        )
    except WikiBaseError:
        raise
    except (httpx.HTTPError, ValueError, jwt.PyJWTError) as exc:
        raise WikiBaseError(
            502, "identity_verification_failed", "Provider identity could not be verified"
        ) from exc
    nonce = claims.get("nonce")
    if not isinstance(nonce, str) or not secrets.compare_digest(_state_hash(nonce), nonce_hash):
        raise WikiBaseError(400, "invalid_oauth_nonce", "Provider identity nonce did not match")
    subject_id = claims.get("sub")
    if not isinstance(subject_id, str) or not subject_id or len(subject_id) > 255:
        raise WikiBaseError(502, "invalid_id_token", "Provider identity subject is invalid")
    at_hash = claims.get("at_hash")
    if at_hash is not None:
        expected_at_hash = _b64url(hashlib.sha256(payload["access_token"].encode()).digest()[:16])
        if not isinstance(at_hash, str) or not secrets.compare_digest(at_hash, expected_at_hash):
            raise WikiBaseError(
                502,
                "invalid_id_token",
                "Provider identity does not match the access token",
            )
    auth_claim = claims.get("https://api.openai.com/auth", {})
    account_id = auth_claim.get("chatgpt_account_id") if isinstance(auth_claim, dict) else None
    if not isinstance(account_id, str) or not account_id or len(account_id) > 255:
        raise WikiBaseError(
            502, "provider_account_missing", "The provider did not identify a valid ChatGPT account"
        )
    label = claims.get("email") or claims.get("name")
    if label is not None and (not isinstance(label, str) or len(label) > 320):
        raise WikiBaseError(502, "invalid_id_token", "Provider account label is invalid")
    return account_id, subject_id, label if isinstance(label, str) and label else None


def _result_path(return_path: str, result: str) -> str:
    separator = "&" if "?" in return_path else "?"
    return f"{return_path}{separator}auth={result}"


async def complete_authorization(
    user: User,
    state: str,
    code: str | None,
    provider_error: str | None,
    browser_binding: str,
    db: AsyncSession,
) -> str:
    try:
        session_id = uuid.UUID(state.split(".", 1)[0])
    except (ValueError, IndexError) as exc:
        raise WikiBaseError(400, "invalid_oauth_state", "Invalid browser sign-in state") from exc
    from app.services.providers import lock_provider_mutation

    await lock_provider_mutation(user.id, "chatgpt", db)
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"provider-auth:{session_id}"},
    )
    auth_session = await db.scalar(
        select(ProviderAuthorizationSession).where(ProviderAuthorizationSession.id == session_id)
    )
    if auth_session is None or not secrets.compare_digest(
        auth_session.state_hash, _state_hash(state)
    ):
        raise WikiBaseError(400, "invalid_oauth_state", "Invalid browser sign-in state")
    if auth_session.user_id != user.id or not secrets.compare_digest(
        auth_session.browser_binding_hash,
        _state_hash(browser_binding),
    ):
        raise WikiBaseError(
            403,
            "oauth_browser_mismatch",
            "Sign-in must finish in the browser that started it",
        )
    if auth_session.status != "pending" or auth_session.consumed_at is not None:
        raise WikiBaseError(409, "oauth_session_consumed", "This browser sign-in was already used")
    now = datetime.now(UTC)
    if auth_session.expires_at <= now:
        auth_session.status = "expired"
        auth_session.consumed_at = now
        auth_session.encrypted_pkce_verifier = None
        await db.commit()
        return _result_path(auth_session.return_path, "expired")
    if provider_error or not code:
        auth_session.status = "failed"
        auth_session.error_code = "authorization_denied"
        auth_session.error_message = "Browser sign-in was cancelled or denied."
        auth_session.consumed_at = now
        auth_session.encrypted_pkce_verifier = None
        await db.commit()
        return _result_path(auth_session.return_path, "denied")

    settings = get_settings()
    from app.services.providers import (
        decrypt_provider_key,
        encrypt_provider_key,
        lock_provider_selection,
    )

    if auth_session.encrypted_pkce_verifier is None:
        raise WikiBaseError(409, "oauth_session_consumed", "Browser sign-in is no longer pending")
    verifier = decrypt_provider_key(
        auth_session.encrypted_pkce_verifier,
        auth_session.encryption_key_id,
        settings,
    )
    data = {
        "grant_type": "authorization_code",
        "client_id": settings.chatgpt_oauth_client_id,
        "code": code,
        "redirect_uri": settings.chatgpt_oauth_redirect_uri,
        "code_verifier": verifier,
    }
    if settings.chatgpt_oauth_client_secret:
        data["client_secret"] = settings.chatgpt_oauth_client_secret
    try:
        tokens = await _token_request(data, settings)
    except WikiBaseError as exc:
        auth_session.status = "failed"
        auth_session.error_code = exc.error
        auth_session.error_message = exc.detail
        auth_session.consumed_at = now
        auth_session.encrypted_pkce_verifier = None
        await db.commit()
        return _result_path(auth_session.return_path, "failed")

    access_token = tokens["access_token"]
    refresh_token = tokens.get("refresh_token")
    expires_in = tokens.get("expires_in")
    scope = tokens.get("scope", CHATGPT_SCOPES)
    invalid_tokens = (
        not access_token
        or len(access_token) > MAX_TOKEN_RESPONSE_BYTES
        or not isinstance(refresh_token, str)
        or not refresh_token
        or len(refresh_token) > MAX_TOKEN_RESPONSE_BYTES
        or not isinstance(expires_in, int)
        or not 60 <= expires_in <= 86_400
        or not isinstance(scope, str)
    )
    if invalid_tokens:
        auth_session.status = "failed"
        auth_session.error_code = "invalid_token_response"
        auth_session.error_message = "The provider returned incomplete durable credentials."
        auth_session.consumed_at = now
        auth_session.encrypted_pkce_verifier = None
        await db.commit()
        return _result_path(auth_session.return_path, "failed")
    try:
        account_id, subject_id, account_label = await _verified_account_details(
            tokens, auth_session.nonce_hash, settings
        )
    except WikiBaseError as exc:
        auth_session.status = "failed"
        auth_session.error_code = exc.error
        auth_session.error_message = exc.detail
        auth_session.consumed_at = now
        auth_session.encrypted_pkce_verifier = None
        await db.commit()
        return _result_path(auth_session.return_path, "failed")
    expires_at = now + timedelta(seconds=expires_in)
    encrypted_access, key_id = encrypt_provider_key(access_token, settings)
    encrypted_refresh, _ = encrypt_provider_key(refresh_token, settings)
    await lock_provider_selection(auth_session.user_id, db)
    setting = await db.scalar(
        select(ProviderSetting).where(
            ProviderSetting.user_id == auth_session.user_id,
            ProviderSetting.provider == "chatgpt",
        )
    )
    if setting is not None and (
        (setting.provider_account_id is not None and setting.provider_account_id != account_id)
        or (setting.provider_subject_id is not None and setting.provider_subject_id != subject_id)
    ):
        auth_session.status = "failed"
        auth_session.error_code = "provider_account_mismatch"
        auth_session.error_message = (
            "Disconnect the existing ChatGPT account before connecting another."
        )
        auth_session.consumed_at = now
        auth_session.encrypted_pkce_verifier = None
        await db.commit()
        return _result_path(auth_session.return_path, "failed")
    if setting is None:
        setting = ProviderSetting(
            user_id=auth_session.user_id,
            provider="chatgpt",
            model=settings.chatgpt_default_model,
            endpoint=settings.chatgpt_responses_endpoint,
            encryption_key_id=key_id,
        )
        db.add(setting)
    setting.model = settings.chatgpt_default_model
    setting.endpoint = settings.chatgpt_responses_endpoint
    setting.auth_method = "oauth_code"
    setting.encrypted_api_key = None
    setting.encrypted_access_token = encrypted_access
    setting.encrypted_refresh_token = encrypted_refresh
    setting.encryption_key_id = key_id
    setting.access_token_expires_at = expires_at
    setting.provider_account_id = account_id
    setting.provider_subject_id = subject_id
    setting.provider_account_label = account_label
    setting.granted_scopes = scope
    setting.status = "connected"
    setting.last_error = None
    setting.last_error_code = None
    setting.last_tested_at = now
    setting.last_refreshed_at = now
    active_id = await db.scalar(
        select(ProviderSetting.id).where(
            ProviderSetting.user_id == auth_session.user_id,
            ProviderSetting.active_for_generation.is_(True),
        )
    )
    if active_id is None:
        setting.active_for_generation = True
    auth_session.status = "completed"
    auth_session.consumed_at = now
    auth_session.encrypted_pkce_verifier = None
    await db.commit()
    return _result_path(auth_session.return_path, "connected")


async def refresh_browser_credential(
    setting: ProviderSetting,
    db: AsyncSession,
    *,
    force: bool = False,
    commit: bool = True,
) -> str:
    settings = get_settings()
    from app.services.providers import lock_provider_mutation

    setting_id = setting.id
    user_id = setting.user_id
    provider = setting.provider
    await lock_provider_mutation(user_id, provider, db)
    setting = await db.scalar(
        select(ProviderSetting)
        .where(
            ProviderSetting.id == setting_id,
            ProviderSetting.user_id == user_id,
            ProviderSetting.provider == provider,
        )
        .execution_options(populate_existing=True)
    )
    if setting is None:
        raise WikiBaseError(409, "reauth_required", "The active provider was disconnected")
    now = datetime.now(UTC)
    if (
        not force
        and setting.access_token_expires_at is not None
        and setting.access_token_expires_at > now + REFRESH_MARGIN
    ):
        from app.services.providers import decrypt_provider_key

        access_token = decrypt_provider_key(
            setting.encrypted_access_token, setting.encryption_key_id, settings
        )
        if commit:
            await db.commit()
        return access_token
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"provider-refresh:{setting.id}"},
    )
    await db.refresh(setting)
    now = datetime.now(UTC)
    if (
        not force
        and setting.access_token_expires_at is not None
        and setting.access_token_expires_at > now + REFRESH_MARGIN
    ):
        from app.services.providers import decrypt_provider_key

        access_token = decrypt_provider_key(
            setting.encrypted_access_token, setting.encryption_key_id, settings
        )
        if commit:
            await db.commit()
        return access_token
    from app.services.providers import (
        decrypt_provider_key,
        encrypt_provider_key,
        lock_provider_selection,
    )

    if setting.encrypted_refresh_token is None:
        await lock_provider_selection(setting.user_id, db)
        setting.status = "reauth_required"
        setting.last_error_code = "refresh_token_missing"
        setting.last_error = "Browser sign-in must be completed again."
        if commit:
            await db.commit()
        else:
            await db.flush()
        raise WikiBaseError(409, "reauth_required", setting.last_error)
    refresh_token = decrypt_provider_key(
        setting.encrypted_refresh_token, setting.encryption_key_id, settings
    )
    data = {
        "grant_type": "refresh_token",
        "client_id": settings.chatgpt_oauth_client_id,
        "refresh_token": refresh_token,
        "scope": CHATGPT_SCOPES,
    }
    if settings.chatgpt_oauth_client_secret:
        data["client_secret"] = settings.chatgpt_oauth_client_secret
    try:
        tokens = await _token_request(data, settings)
    except WikiBaseError as exc:
        if exc.error == "reauth_required":
            await lock_provider_selection(setting.user_id, db)
            setting.status = "reauth_required"
            setting.last_error_code = exc.error
            setting.last_error = "Browser sign-in expired. Reconnect this provider."
            if commit:
                await db.commit()
            else:
                await db.flush()
        raise
    access_token = tokens["access_token"]
    response_refresh = tokens.get("refresh_token")
    rotated_refresh = refresh_token if response_refresh is None else response_refresh
    expires_in = tokens.get("expires_in")
    if (
        not access_token
        or len(access_token) > MAX_TOKEN_RESPONSE_BYTES
        or not isinstance(rotated_refresh, str)
        or not rotated_refresh
        or len(rotated_refresh) > MAX_TOKEN_RESPONSE_BYTES
        or not isinstance(expires_in, int)
        or not 60 <= expires_in <= 86_400
    ):
        raise WikiBaseError(
            502,
            "invalid_token_response",
            "The provider returned invalid refreshed credentials",
        )
    encrypted_access, key_id = encrypt_provider_key(access_token, settings)
    encrypted_refresh, _ = encrypt_provider_key(rotated_refresh, settings)
    setting.encrypted_access_token = encrypted_access
    setting.encrypted_refresh_token = encrypted_refresh
    setting.encryption_key_id = key_id
    setting.access_token_expires_at = now + timedelta(seconds=expires_in)
    setting.status = "connected"
    setting.last_error = None
    setting.last_error_code = None
    setting.last_refreshed_at = now
    if commit:
        await db.commit()
    else:
        await db.flush()
    return access_token
