import asyncio
import ipaddress
import socket
from dataclasses import dataclass
from datetime import UTC, datetime
from urllib.parse import quote, urlparse

import httpx
from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import delete, select, text
from sqlalchemy.ext.asyncio import AsyncSession

from app.config import Settings, get_settings
from app.exceptions import NotFoundError, WikiBaseError
from app.models.m3 import ProviderAuthorizationSession, ProviderSetting
from app.models.user import User
from app.schemas.m3 import (
    ProviderAuthMethodDescriptor,
    ProviderConfigureRequest,
    ProviderDescriptor,
)

PROVIDERS = {
    "openai": ProviderDescriptor(
        id="openai",
        name="OpenAI",
        models=["gpt-4o-mini", "gpt-4o"],
        endpoint="https://api.openai.com/v1",
        description="A straightforward default for cited, source-grounded answers.",
        capabilities=["Cited answers", "Streaming responses"],
        setup_url="https://platform.openai.com/api-keys",
        billing_note=(
            "Uses developer API billing. A consumer subscription does not include API usage."
        ),
        auth_methods=[ProviderAuthMethodDescriptor(kind="api_key", label="OpenAI API key")],
    ),
    "chatgpt": ProviderDescriptor(
        id="chatgpt",
        name="ChatGPT",
        models=[],
        endpoint="",
        description=(
            "Connect an approved ChatGPT account through browser sign-in, or use this machine's "
            "existing Codex CLI login in local development."
        ),
        capabilities=[
            "Cited answers",
            "Browser sign-in",
            "Local Codex CLI",
            "Automatic token refresh",
        ],
        billing_note=(
            "Browser sign-in uses the connected account. The local CLI option uses the Codex "
            "account already signed in on this machine and is never available in deployment."
        ),
        auth_methods=[
            ProviderAuthMethodDescriptor(
                kind="oauth_code",
                label="Sign in through browser",
                recommended=True,
            ),
            ProviderAuthMethodDescriptor(
                kind="local_cli",
                label="Use local Codex CLI login",
            ),
        ],
    ),
    "openai_compatible": ProviderDescriptor(
        id="openai_compatible",
        name="OpenAI-compatible",
        models=[],
        endpoint="",
        description="Connect a trusted OpenAI-compatible endpoint approved by the workspace owner.",
        capabilities=["Cited answers", "Custom models"],
        billing_note="Usage and retention depend on the service behind the endpoint.",
        endpoint_mode="custom",
    ),
    "azure_openai": ProviderDescriptor(
        id="azure_openai",
        name="Azure OpenAI",
        models=[],
        endpoint="",
        description="Use an Azure OpenAI deployment managed in your Azure subscription.",
        capabilities=["Cited answers", "Azure-managed deployment"],
        setup_url="https://portal.azure.com/",
        billing_note=(
            "Requires an Azure OpenAI resource and deployment. Azure usage is billed separately."
        ),
        endpoint_mode="custom",
    ),
    "google_gemini": ProviderDescriptor(
        id="google_gemini",
        name="Google Gemini",
        models=["gemini-2.0-flash"],
        endpoint="https://generativelanguage.googleapis.com/v1beta/openai",
        description="Use a Gemini developer key through Google's OpenAI-compatible endpoint.",
        capabilities=["Cited answers", "Streaming responses"],
        setup_url="https://aistudio.google.com/apikey",
        billing_note=(
            "Uses Gemini API quotas and billing. A Google consumer subscription is separate."
        ),
    ),
}


def provider_descriptors(settings: Settings | None = None) -> list[ProviderDescriptor]:
    settings = settings or get_settings()
    descriptors: list[ProviderDescriptor] = []
    for descriptor in PROVIDERS.values():
        copy = descriptor.model_copy(deep=True)
        if copy.id == "chatgpt":
            enabled = bool(settings.chatgpt_oauth_client_id.strip())
            copy.models = [settings.chatgpt_default_model]
            copy.endpoint = settings.chatgpt_responses_endpoint
            copy.auth_methods[0].enabled = enabled
            copy.auth_methods[0].unavailable_reason = (
                None
                if enabled
                else "An approved OAuth client must be configured by the workspace owner."
            )
            local_cli = copy.auth_methods[1]
            local_cli.enabled = settings.local_codex_cli_enabled
            local_cli.unavailable_reason = (
                None
                if local_cli.enabled
                else (
                    "Local Codex CLI access is available only in an explicitly enabled "
                    "development workspace."
                )
            )
        elif not copy.auth_methods:
            copy.auth_methods = [ProviderAuthMethodDescriptor(kind="api_key", label="API key")]
        descriptors.append(copy)
    return descriptors


def _require_local_codex_request(
    user: User,
    settings: Settings,
    client_host: str,
) -> None:
    environment = settings.environment.strip().lower()
    if environment not in {"development", "dev"}:
        raise WikiBaseError(
            409,
            "local_codex_unavailable",
            "Local Codex CLI access is restricted to local development",
        )
    if user.email.strip().lower() != settings.local_codex_cli_allowed_email.strip().lower():
        raise WikiBaseError(
            403,
            "local_codex_forbidden",
            "Local Codex CLI access is restricted to the configured workspace owner",
        )
    try:
        loopback = ipaddress.ip_address(client_host).is_loopback
    except ValueError:
        loopback = client_host == "localhost"
    if not loopback:
        raise WikiBaseError(
            403,
            "local_codex_forbidden",
            "Local Codex CLI access accepts loopback requests only",
        )


@dataclass(frozen=True)
class GenerationProvider:
    provider: str
    model: str
    endpoint: str
    api_key: str
    auth_method: str = "api_key"
    account_id: str = ""
    transport: str = "chat_completions"


async def resolve_generation_provider(
    user: User | None,
    db: AsyncSession | None,
    *,
    client_host: str = "",
) -> GenerationProvider:
    settings = get_settings()
    if user is not None and db is not None:
        result = await db.execute(
            select(ProviderSetting).where(
                ProviderSetting.user_id == user.id,
                ProviderSetting.active_for_generation.is_(True),
                ProviderSetting.status == "connected",
            )
        )
        selected = result.scalar_one_or_none()
        if selected is not None:
            if selected.auth_method == "local_cli":
                _require_local_codex_request(user, settings, client_host)
                if selected.provider != "chatgpt":
                    raise WikiBaseError(
                        409,
                        "local_codex_unavailable",
                        "The active local CLI provider is invalid",
                    )
                return GenerationProvider(
                    provider=selected.provider,
                    model=selected.model,
                    endpoint="local://codex-cli",
                    api_key="",
                    auth_method=selected.auth_method,
                    account_id="",
                    transport="codex_cli",
                )
            if selected.auth_method == "oauth_code":
                if selected.provider != "chatgpt" or selected.encrypted_access_token is None:
                    raise WikiBaseError(
                        409,
                        "reauth_required",
                        "The active provider must be reconnected",
                    )
                from app.services.provider_auth import refresh_browser_credential

                token = await refresh_browser_credential(selected, db)
                return GenerationProvider(
                    provider=selected.provider,
                    model=selected.model,
                    endpoint=settings.chatgpt_responses_endpoint,
                    api_key=token,
                    auth_method=selected.auth_method,
                    account_id=selected.provider_account_id or "",
                    transport="responses",
                )
            if selected.encrypted_api_key is None:
                raise WikiBaseError(
                    409,
                    "credential_unavailable",
                    "The active provider credential is unavailable",
                )
            return GenerationProvider(
                provider=selected.provider,
                model=selected.model,
                endpoint=selected.endpoint,
                api_key=decrypt_provider_key(
                    selected.encrypted_api_key,
                    selected.encryption_key_id,
                    settings,
                ),
            )
        reconnect_required = await db.scalar(
            select(ProviderSetting.id).where(
                ProviderSetting.user_id == user.id,
                ProviderSetting.active_for_generation.is_(True),
                ProviderSetting.status == "reauth_required",
            )
        )
        if reconnect_required is not None:
            raise WikiBaseError(
                409,
                "reauth_required",
                "Reconnect the selected provider before generating another answer",
            )
    return GenerationProvider(
        provider="openai",
        model="gpt-4o",
        endpoint=PROVIDERS["openai"].endpoint,
        api_key=settings.openai_api_key,
    )


async def mark_local_codex_unavailable(
    user: User | None,
    db: AsyncSession | None,
    error_code: str,
    detail: str,
) -> None:
    if user is None or db is None:
        return
    await lock_provider_mutation(user.id, "chatgpt", db)
    setting = await db.scalar(
        select(ProviderSetting).where(
            ProviderSetting.user_id == user.id,
            ProviderSetting.provider == "chatgpt",
            ProviderSetting.auth_method == "local_cli",
            ProviderSetting.active_for_generation.is_(True),
        )
    )
    if setting is None:
        return
    setting.status = "reauth_required"
    setting.last_error_code = error_code[:100]
    setting.last_error = detail[:1000]
    setting.last_tested_at = datetime.now(UTC)
    await db.commit()


async def force_refresh_generation_provider(
    user: User | None,
    db: AsyncSession | None,
) -> GenerationProvider:
    if user is None or db is None:
        raise WikiBaseError(401, "reauth_required", "Reconnect the active provider")
    selected = await db.scalar(
        select(ProviderSetting).where(
            ProviderSetting.user_id == user.id,
            ProviderSetting.active_for_generation.is_(True),
            ProviderSetting.provider == "chatgpt",
            ProviderSetting.auth_method == "oauth_code",
        )
    )
    if selected is None:
        raise WikiBaseError(401, "reauth_required", "Reconnect the active provider")
    from app.services.provider_auth import refresh_browser_credential

    settings = get_settings()
    token = await refresh_browser_credential(selected, db, force=True)
    return GenerationProvider(
        provider=selected.provider,
        model=selected.model,
        endpoint=settings.chatgpt_responses_endpoint,
        api_key=token,
        auth_method=selected.auth_method,
        account_id=selected.provider_account_id or "",
        transport="responses",
    )


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


async def lock_provider_mutation(user_id, provider: str, db: AsyncSession) -> None:
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"provider:{user_id}:{provider}"},
    )


async def lock_provider_selection(user_id, db: AsyncSession) -> None:
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtext(:lock_key))"),
        {"lock_key": f"provider-selection:{user_id}"},
    )


async def list_settings(user: User, db: AsyncSession) -> list[ProviderSetting]:
    result = await db.execute(
        select(ProviderSetting)
        .where(ProviderSetting.user_id == user.id)
        .order_by(ProviderSetting.provider)
        .limit(len(PROVIDERS))
    )
    return list(result.scalars())


async def connect_local_codex(
    user: User,
    db: AsyncSession,
    *,
    client_host: str,
) -> ProviderSetting:
    from app.services.local_codex import validate_local_codex

    settings = get_settings()
    _require_local_codex_request(user, settings, client_host)
    await validate_local_codex(settings)
    await lock_provider_mutation(user.id, "chatgpt", db)
    await lock_provider_selection(user.id, db)
    setting = await db.scalar(
        select(ProviderSetting).where(
            ProviderSetting.user_id == user.id,
            ProviderSetting.provider == "chatgpt",
        )
    )
    local_model = settings.local_codex_cli_model or "Codex CLI default"
    if setting is not None and setting.auth_method != "local_cli":
        raise WikiBaseError(
            409,
            "disconnect_required",
            "Disconnect the existing ChatGPT connection before using the local Codex CLI",
        )
    if setting is None:
        setting = ProviderSetting(
            user_id=user.id,
            provider="chatgpt",
            model=local_model,
            endpoint="local://codex-cli",
            auth_method="local_cli",
            encryption_key_id=settings.provider_encryption_key_id,
            status="connected",
            active_for_generation=False,
        )
        db.add(setting)
    else:
        setting.model = local_model
        setting.endpoint = "local://codex-cli"
        setting.auth_method = "local_cli"
        setting.status = "connected"
        setting.active_for_generation = False
    setting.encrypted_api_key = None
    setting.encrypted_access_token = None
    setting.encrypted_refresh_token = None
    setting.access_token_expires_at = None
    setting.provider_account_id = None
    setting.provider_subject_id = None
    setting.provider_account_label = "Local Codex CLI"
    setting.granted_scopes = None
    setting.last_error = None
    setting.last_error_code = None
    setting.last_tested_at = datetime.now(UTC)
    setting.last_refreshed_at = None
    active = await db.scalar(
        select(ProviderSetting.id).where(
            ProviderSetting.user_id == user.id,
            ProviderSetting.active_for_generation.is_(True),
        )
    )
    if active is None:
        setting.active_for_generation = True
    await db.flush()
    await db.refresh(setting)
    return setting


async def configure_provider(
    user: User, payload: ProviderConfigureRequest, db: AsyncSession
) -> ProviderSetting:
    endpoint = endpoint_for(payload)
    await lock_provider_mutation(user.id, payload.provider, db)
    await lock_provider_selection(user.id, db)
    result = await db.execute(
        select(ProviderSetting).where(
            ProviderSetting.user_id == user.id,
            ProviderSetting.provider == payload.provider,
        )
    )
    setting = result.scalar_one_or_none()
    if setting is None:
        if payload.api_key is None:
            raise WikiBaseError(422, "credential_required", "An API key is required to connect")
        encrypted, key_id = encrypt_provider_key(payload.api_key, get_settings())
        setting = ProviderSetting(
            user_id=user.id,
            provider=payload.provider,
            model=payload.model,
            endpoint=endpoint,
            auth_method="api_key",
            encrypted_api_key=encrypted,
            encryption_key_id=key_id,
            status="configured",
            active_for_generation=False,
            last_error=None,
        )
        db.add(setting)
    else:
        setting.model = payload.model
        setting.endpoint = endpoint
        setting.auth_method = "api_key"
        if payload.api_key is not None:
            encrypted, key_id = encrypt_provider_key(payload.api_key, get_settings())
            setting.encrypted_api_key = encrypted
            setting.encryption_key_id = key_id
        if setting.encrypted_api_key is None:
            raise WikiBaseError(422, "credential_required", "An API key is required to connect")
        setting.encrypted_access_token = None
        setting.encrypted_refresh_token = None
        setting.access_token_expires_at = None
        setting.provider_account_id = None
        setting.provider_subject_id = None
        setting.provider_account_label = None
        setting.granted_scopes = None
        setting.status = "configured"
        setting.active_for_generation = False
        setting.last_error = None
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


async def test_provider(
    user: User,
    provider: str,
    db: AsyncSession,
    *,
    client_host: str = "",
) -> ProviderSetting:
    await lock_provider_mutation(user.id, provider, db)
    setting = await _owned_setting(user, provider, db)
    settings = get_settings()
    if provider == "chatgpt":
        if setting.auth_method == "local_cli":
            from app.services.local_codex import validate_local_codex

            _require_local_codex_request(user, settings, client_host)
            try:
                await validate_local_codex(settings)
            except WikiBaseError as exc:
                setting.status = "reauth_required"
                setting.last_error = exc.detail
                setting.last_error_code = exc.error
                setting.last_tested_at = datetime.now(UTC)
                await db.flush()
                await db.refresh(setting)
                return setting
            setting.status = "connected"
            setting.last_error = None
            setting.last_error_code = None
            setting.last_tested_at = datetime.now(UTC)
            await db.flush()
            await db.refresh(setting)
            return setting
        if setting.auth_method != "oauth_code" or setting.encrypted_access_token is None:
            raise WikiBaseError(409, "reauth_required", "Reconnect ChatGPT through the browser")
        from app.services.provider_auth import refresh_browser_credential

        try:
            await refresh_browser_credential(setting, db, commit=False)
        except WikiBaseError as exc:
            if exc.error != "reauth_required":
                raise
            setting.last_tested_at = datetime.now(UTC)
            await db.flush()
            await db.refresh(setting)
            return setting
        setting.status = "connected"
        setting.last_error = None
        setting.last_error_code = None
        setting.last_tested_at = datetime.now(UTC)
        await db.flush()
        await db.refresh(setting)
        return setting
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
        await _ensure_public_endpoint(endpoint)
    key = decrypt_provider_key(setting.encrypted_api_key, setting.encryption_key_id, settings)
    headers: dict[str, str]
    method = "GET"
    body = None
    if provider in {"openai", "openai_compatible", "google_gemini"}:
        url = f"{endpoint}/models"
        headers = {"Authorization": f"Bearer {key}"}
    elif provider == "azure_openai":
        deployment = quote(setting.model, safe="")
        url = f"{endpoint}/openai/deployments/{deployment}/chat/completions?api-version=2024-10-21"
        headers = {"api-key": key}
        method = "POST"
        body = {"messages": [{"role": "user", "content": "Reply OK"}], "max_tokens": 1}
    failure: str | None = None
    try:
        async with httpx.AsyncClient(timeout=10, follow_redirects=False) as client:
            response = await client.request(method, url, headers=headers, json=body)
        valid = 200 <= response.status_code < 300
        if response.status_code in {401, 403}:
            failure = "The provider rejected the credential. Check the key and its permissions."
        elif response.status_code == 404:
            failure = "The configured endpoint or model was not found."
        elif response.status_code == 429:
            failure = "The provider rate limit was reached. Try again after checking its quota."
        elif response.status_code >= 500:
            failure = "The provider is temporarily unavailable. Try again later."
        elif not valid:
            failure = "The provider rejected the endpoint or model."
        if valid and provider != "azure_openai":
            payload = response.json()
            models = payload.get("data", [])
            model_ids = {
                str(item.get("id", "")).removeprefix("models/")
                for item in models
                if isinstance(item, dict)
            }
            valid = setting.model in model_ids
            if not valid:
                failure = "The configured model is not available for this credential."
    except httpx.TimeoutException:
        valid = False
        failure = "The connection timed out. Check the endpoint and try again."
    except (httpx.ConnectError, httpx.NetworkError):
        valid = False
        failure = "A network or TLS connection could not be established."
    except (AttributeError, httpx.HTTPError, ValueError):
        valid = False
        failure = "The provider returned an unexpected response."
    await lock_provider_selection(user.id, db)
    setting.status = "connected" if valid else "invalid"
    setting.last_error = None if valid else failure
    if not valid:
        setting.active_for_generation = False
    setting.last_tested_at = datetime.now(UTC)
    if valid:
        active = await db.scalar(
            select(ProviderSetting.id).where(
                ProviderSetting.user_id == user.id,
                ProviderSetting.active_for_generation.is_(True),
            )
        )
        if active is None:
            setting.active_for_generation = True
    await db.flush()
    await db.refresh(setting)
    return setting


async def _ensure_public_endpoint(endpoint: str) -> None:
    hostname = urlparse(endpoint).hostname
    if not hostname:
        raise WikiBaseError(422, "unsafe_endpoint", "Provider endpoint has no hostname")

    def resolve() -> list[str]:
        return list(
            {item[4][0] for item in socket.getaddrinfo(hostname, 443, type=socket.SOCK_STREAM)}
        )

    try:
        addresses = await asyncio.wait_for(asyncio.to_thread(resolve), timeout=3)
    except (OSError, TimeoutError) as exc:
        raise WikiBaseError(
            422,
            "unsafe_endpoint",
            "Custom provider endpoint could not be resolved safely",
        ) from exc
    if not addresses or any(not ipaddress.ip_address(address).is_global for address in addresses):
        raise WikiBaseError(
            422,
            "unsafe_endpoint",
            "Custom provider endpoint resolves to a private or reserved network",
        )


async def activate_provider(user: User, provider: str, db: AsyncSession) -> ProviderSetting:
    await lock_provider_mutation(user.id, provider, db)
    setting = await _owned_setting(user, provider, db)
    if setting.status != "connected":
        raise WikiBaseError(
            409,
            "provider_not_connected",
            "Test this provider successfully before making it active",
        )
    await lock_provider_selection(user.id, db)
    await db.refresh(setting)
    if setting.status != "connected":
        raise WikiBaseError(
            409,
            "provider_not_connected",
            "Test this provider successfully before making it active",
        )
    await db.execute(
        ProviderSetting.__table__.update()
        .where(ProviderSetting.user_id == user.id)
        .values(active_for_generation=False)
    )
    setting.active_for_generation = True
    await db.flush()
    await db.refresh(setting)
    return setting


async def disconnect_provider(user: User, provider: str, db: AsyncSession) -> None:
    await lock_provider_mutation(user.id, provider, db)
    setting = await _owned_setting(user, provider, db)
    await lock_provider_selection(user.id, db)
    await db.execute(
        delete(ProviderAuthorizationSession).where(
            ProviderAuthorizationSession.user_id == user.id,
            ProviderAuthorizationSession.provider == provider,
        )
    )
    await db.delete(setting)
    await db.flush()
