from datetime import UTC, datetime
from urllib.parse import quote, urlparse

import httpx
from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings, get_settings
from app.exceptions import NotFoundError, WikiBaseError
from app.models.m3 import ProviderSetting
from app.models.user import User
from app.schemas.m3 import ProviderConfigureRequest, ProviderDescriptor

PROVIDERS = {
    "openai": ProviderDescriptor(
        id="openai",
        name="OpenAI",
        models=["gpt-4o-mini", "gpt-4o"],
        endpoint="https://api.openai.com/v1",
    ),
    "openai_compatible": ProviderDescriptor(
        id="openai_compatible", name="OpenAI-compatible", models=[], endpoint=""
    ),
    "azure_openai": ProviderDescriptor(
        id="azure_openai", name="Azure OpenAI", models=[], endpoint=""
    ),
    "google_gemini": ProviderDescriptor(
        id="google_gemini",
        name="Google Gemini",
        models=["gemini-2.0-flash"],
        endpoint="https://generativelanguage.googleapis.com/v1beta",
    ),
}


def _encryption_keys(settings: Settings) -> dict[str, Fernet]:
    keys = {
        settings.provider_encryption_key_id: Fernet(settings.provider_encryption_secret.encode())
    }
    for entry in settings.provider_encryption_previous_secrets.split(","):
        if entry.strip():
            key_id, key = entry.split(":", 1)
            keys[key_id.strip()] = Fernet(key.strip().encode())
    return keys


def encrypt_provider_key(value: str, settings: Settings) -> tuple[bytes, str]:
    key_id = settings.provider_encryption_key_id
    return _encryption_keys(settings)[key_id].encrypt(value.encode()), key_id


def decrypt_provider_key(value: bytes, key_id: str, settings: Settings) -> str:
    key = _encryption_keys(settings).get(key_id)
    if key is None:
        raise WikiBaseError(
            500, "credential_unavailable", "Provider credential encryption key is unavailable"
        )
    try:
        return key.decrypt(value).decode()
    except InvalidToken as exc:
        raise WikiBaseError(
            500, "credential_unavailable", "Provider credential cannot be decrypted"
        ) from exc


def _safe_custom_endpoint(value: str, settings: Settings) -> str:
    endpoint = value.rstrip("/")
    parsed = urlparse(endpoint)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username
        or parsed.password
        or parsed.port not in (None, 443)
        or endpoint not in settings.provider_endpoint_allowlist
    ):
        raise WikiBaseError(
            422,
            "unsafe_endpoint",
            "Custom provider endpoint must exactly match a configured HTTPS allowlist entry",
        )
    return endpoint


def endpoint_for(payload: ProviderConfigureRequest, settings: Settings | None = None) -> str:
    settings = settings or get_settings()
    if payload.provider in {"openai", "google_gemini"}:
        if payload.endpoint is not None:
            raise WikiBaseError(
                422, "fixed_endpoint", "This provider uses its fixed official endpoint"
            )
        return PROVIDERS[payload.provider].endpoint
    if payload.endpoint is None:
        raise WikiBaseError(422, "endpoint_required", "This provider requires an HTTPS endpoint")
    endpoint = _safe_custom_endpoint(str(payload.endpoint), settings)
    if payload.provider == "azure_openai" and not urlparse(endpoint).hostname.endswith(
        ".openai.azure.com"
    ):
        raise WikiBaseError(422, "unsafe_endpoint", "Azure endpoint must be on openai.azure.com")
    return endpoint


async def list_settings(user: User, db: AsyncSession) -> list[ProviderSetting]:
    result = await db.execute(
        select(ProviderSetting)
        .where(ProviderSetting.user_id == user.id)
        .order_by(ProviderSetting.provider)
        .limit(len(PROVIDERS))
    )
    return list(result.scalars())


async def configure_provider(
    user: User, payload: ProviderConfigureRequest, db: AsyncSession
) -> ProviderSetting:
    endpoint = endpoint_for(payload)
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"provider:{user.id}:{payload.provider}"},
    )
    result = await db.execute(
        select(ProviderSetting).where(
            ProviderSetting.user_id == user.id,
            ProviderSetting.provider == payload.provider,
        )
    )
    setting = result.scalar_one_or_none()
    encrypted, key_id = encrypt_provider_key(payload.api_key, get_settings())
    if setting is None:
        setting = ProviderSetting(
            user_id=user.id,
            provider=payload.provider,
            model=payload.model,
            endpoint=endpoint,
            encrypted_api_key=encrypted,
            encryption_key_id=key_id,
            status="configured",
        )
        db.add(setting)
    else:
        setting.model = payload.model
        setting.endpoint = endpoint
        setting.encrypted_api_key = encrypted
        setting.encryption_key_id = key_id
        setting.status = "configured"
        setting.last_tested_at = None
    await db.flush()
    await db.refresh(setting)
    return setting


async def _owned_setting(user: User, provider: str, db: AsyncSession) -> ProviderSetting:
    if provider not in PROVIDERS:
        raise NotFoundError("Provider not found")
    result = await db.execute(
        select(ProviderSetting).where(
            ProviderSetting.user_id == user.id, ProviderSetting.provider == provider
        )
    )
    setting = result.scalar_one_or_none()
    if setting is None:
        raise NotFoundError("Provider configuration not found")
    return setting


async def test_provider(user: User, provider: str, db: AsyncSession) -> ProviderSetting:
    setting = await _owned_setting(user, provider, db)
    settings = get_settings()
    if provider in {"openai", "google_gemini"}:
        endpoint = PROVIDERS[provider].endpoint
        if setting.endpoint != endpoint:
            raise WikiBaseError(422, "unsafe_endpoint", "Stored provider endpoint is not allowed")
    else:
        endpoint = _safe_custom_endpoint(setting.endpoint, settings)
        if provider == "azure_openai" and not urlparse(endpoint).hostname.endswith(
            ".openai.azure.com"
        ):
            raise WikiBaseError(422, "unsafe_endpoint", "Azure endpoint is not allowed")
    key = decrypt_provider_key(setting.encrypted_api_key, setting.encryption_key_id, settings)
    headers: dict[str, str]
    method = "GET"
    body = None
    if provider in {"openai", "openai_compatible"}:
        url = f"{endpoint}/models"
        headers = {"Authorization": f"Bearer {key}"}
    elif provider == "azure_openai":
        deployment = quote(setting.model, safe="")
        url = f"{endpoint}/openai/deployments/{deployment}/chat/completions?api-version=2024-10-21"
        headers = {"api-key": key}
        method = "POST"
        body = {"messages": [{"role": "user", "content": "Reply OK"}], "max_tokens": 1}
    else:
        url = f"{endpoint}/models"
        headers = {"x-goog-api-key": key}
    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=False) as client:
            response = await client.request(method, url, headers=headers, json=body)
        valid = 200 <= response.status_code < 300
        if valid and provider != "azure_openai":
            payload = response.json()
            models = payload.get("models" if provider == "google_gemini" else "data", [])
            model_ids = {
                str(item.get("name" if provider == "google_gemini" else "id", "")).removeprefix(
                    "models/"
                )
                for item in models
                if isinstance(item, dict)
            }
            valid = setting.model in model_ids
    except (AttributeError, httpx.HTTPError, ValueError):
        valid = False
    setting.status = "connected" if valid else "invalid"
    setting.last_tested_at = datetime.now(UTC)
    await db.flush()
    await db.refresh(setting)
    if not valid:
        raise WikiBaseError(
            422, "provider_validation_failed", "Provider rejected the configuration"
        )
    return setting


async def disconnect_provider(user: User, provider: str, db: AsyncSession) -> None:
    setting = await _owned_setting(user, provider, db)
    await db.delete(setting)
    await db.flush()
