from functools import lru_cache

from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_file_encoding="utf-8", extra="ignore")

    database_url: str = "postgresql+asyncpg://postgres:postgres@localhost:5432/canvaspilot"
    canvas_base_url: str = "https://canvas.nus.edu.sg"
    canvas_client_id: str = ""
    canvas_client_secret: str = ""
    canvas_oauth_redirect_uri: str = "http://localhost:8000/api/auth/canvas/callback"
    session_secret: str = "change-me-in-production"
    canvas_token_secret: str = "change-me-in-production"
    openai_api_key: str = ""
    frontend_url: str = "http://localhost:3000"
    backend_url: str = "http://localhost:8000"
    cors_origins: str = "http://localhost:3000"
    log_level: str = "INFO"

    @property
    def canvas_base(self) -> str:
        return self.canvas_base_url.rstrip("/")

    @property
    def cors_origin_list(self) -> list[str]:
        return [o.strip() for o in self.cors_origins.split(",") if o.strip()]


@lru_cache
def get_settings() -> Settings:
    return Settings()
