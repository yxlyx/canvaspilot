from functools import lru_cache
from urllib.parse import urlparse

from cryptography.fernet import Fernet
from pydantic import model_validator
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    environment: str = "development"
    allow_insecure_development: bool = False
    secure_cookies: bool = True
    max_request_body_bytes: int = 15 * 1024 * 1024
    database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/wikibase"
    canvas_base_url: str = "https://canvas.nus.edu.sg"
    canvas_client_id: str = ""
    canvas_client_secret: str = ""
    canvas_oauth_redirect_uri: str = "http://localhost:8000/api/auth/canvas/callback"
    session_secret: str = "change-me-in-production"
    canvas_token_secret: str = "change-me-in-production"
    provider_encryption_secret: str = "change-me-in-production"
    provider_encryption_key_id: str = "primary"
    provider_encryption_previous_secrets: str = ""
    provider_allowed_endpoints: str = ""
    openai_api_key: str = ""
    chatgpt_oauth_client_id: str = ""
    chatgpt_oauth_client_secret: str = ""
    chatgpt_oauth_authorize_url: str = "https://auth.openai.com/oauth/authorize"
    chatgpt_oauth_token_url: str = "https://auth.openai.com/oauth/token"
    chatgpt_oauth_jwks_url: str = "https://auth.openai.com/.well-known/jwks.json"
    chatgpt_oauth_redirect_uri: str = "http://localhost:3000/api/providers/chatgpt/oauth/callback"
    chatgpt_responses_endpoint: str = "https://chatgpt.com/backend-api/codex"
    chatgpt_default_model: str = "gpt-5-codex"
    local_codex_cli_enabled: bool = False
    local_codex_cli_path: str = ""
    local_codex_cli_model: str = ""
    local_codex_cli_allowed_email: str = ""
    local_codex_cli_timeout_seconds: int = 120
    local_codex_cli_max_prompt_chars: int = 250_000
    frontend_url: str = "http://localhost:3000"
    backend_url: str = "http://localhost:8000"
    cors_origins: str = "http://localhost:3000"
    log_level: str = "INFO"

    @model_validator(mode="after")
    def reject_unsafe_runtime_configuration(self):
        environment = self.environment.strip().lower()
        if environment != "test" and environment in {"development", "dev"}:
            if not self.allow_insecure_development:
                raise ValueError("Development mode requires ALLOW_INSECURE_DEVELOPMENT=true")
        defaults = {"", "change-me-in-production"}
        if (
            self.session_secret in defaults
            or self.session_secret.lower().startswith("change-me")
            or len(self.session_secret) < 32
        ):
            raise ValueError(
                "SESSION_SECRET must be a non-default secret of at least 32 characters"
            )
        for name in ("canvas_token_secret", "provider_encryption_secret"):
            value = getattr(self, name)
            if value in defaults or value.lower().startswith("change-me"):
                raise ValueError(f"{name.upper()} must not use a public default")
            try:
                Fernet(value.encode())
            except (TypeError, ValueError) as exc:
                raise ValueError(f"{name.upper()} must be a valid Fernet key") from exc
        for entry in self.provider_encryption_previous_secrets.split(","):
            if not entry.strip():
                continue
            try:
                key_id, key = entry.split(":", 1)
                if not key_id.strip() or key_id.strip() == self.provider_encryption_key_id:
                    raise ValueError
                Fernet(key.strip().encode())
            except (TypeError, ValueError) as exc:
                raise ValueError(
                    "PROVIDER_ENCRYPTION_PREVIOUS_SECRETS must contain key-id:Fernet-key entries"
                ) from exc
        if environment not in {"production", "prod", "staging", "test", "development", "dev"}:
            raise ValueError("ENVIRONMENT must be an explicit supported mode")
        if environment in {"production", "prod", "staging"} and not self.secure_cookies:
            raise ValueError("SECURE_COOKIES must be enabled in production and staging")
        oauth_urls = {
            "CHATGPT_OAUTH_AUTHORIZE_URL": (
                self.chatgpt_oauth_authorize_url,
                "auth.openai.com",
                "/oauth/authorize",
            ),
            "CHATGPT_OAUTH_TOKEN_URL": (
                self.chatgpt_oauth_token_url,
                "auth.openai.com",
                "/oauth/token",
            ),
            "CHATGPT_OAUTH_JWKS_URL": (
                self.chatgpt_oauth_jwks_url,
                "auth.openai.com",
                "/.well-known/jwks.json",
            ),
            "CHATGPT_RESPONSES_ENDPOINT": (
                self.chatgpt_responses_endpoint,
                "chatgpt.com",
                "/backend-api/codex",
            ),
        }
        for name, (value, hostname, path) in oauth_urls.items():
            parsed = urlparse(value)
            if (
                parsed.scheme != "https"
                or parsed.hostname != hostname
                or parsed.port not in (None, 443)
                or parsed.username
                or parsed.password
                or parsed.path != path
                or parsed.query
                or parsed.fragment
            ):
                raise ValueError(f"{name} must use its fixed official HTTPS endpoint")
        redirect = urlparse(self.chatgpt_oauth_redirect_uri)
        if (
            redirect.scheme
            not in (
                {"https"} if environment in {"production", "prod", "staging"} else {"http", "https"}
            )
            or not redirect.hostname
            or redirect.username
            or redirect.password
            or redirect.query
            or redirect.fragment
            or redirect.path != "/api/providers/chatgpt/oauth/callback"
        ):
            raise ValueError("CHATGPT_OAUTH_REDIRECT_URI must be the configured callback URL")
        if self.local_codex_cli_enabled:
            if environment not in {"development", "dev"}:
                raise ValueError("LOCAL_CODEX_CLI_ENABLED is restricted to local development")
            if not self.local_codex_cli_path.startswith("/"):
                raise ValueError("LOCAL_CODEX_CLI_PATH must be an absolute executable path")
            allowed_email = self.local_codex_cli_allowed_email.strip().lower()
            if not allowed_email or "@" not in allowed_email or len(allowed_email) > 320:
                raise ValueError(
                    "LOCAL_CODEX_CLI_ALLOWED_EMAIL must identify the local workspace owner"
                )
            local_hosts = {"localhost", "127.0.0.1", "::1"}
            if (
                urlparse(self.frontend_url).hostname not in local_hosts
                or urlparse(self.backend_url).hostname not in local_hosts
            ):
                raise ValueError(
                    "Local Codex CLI access requires loopback frontend and backend URLs"
                )
        if not 10 <= self.local_codex_cli_timeout_seconds <= 600:
            raise ValueError("LOCAL_CODEX_CLI_TIMEOUT_SECONDS must be between 10 and 600")
        if not 10_000 <= self.local_codex_cli_max_prompt_chars <= 1_000_000:
            raise ValueError("LOCAL_CODEX_CLI_MAX_PROMPT_CHARS is outside the supported range")
        return self

    @property
    def provider_endpoint_allowlist(self) -> set[str]:
        return {
            endpoint.strip().rstrip("/")
            for endpoint in self.provider_allowed_endpoints.split(",")
            if endpoint.strip()
        }

    @property
    def canvas_base(self) -> str:
        return self.canvas_base_url.rstrip("/")

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
