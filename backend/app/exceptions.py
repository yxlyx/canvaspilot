from fastapi import Request
from fastapi.responses import JSONResponse


class WikiBaseError(Exception):
    def __init__(self, status_code: int, error: str, detail: str):
        self.status_code = status_code
        self.error = error
        self.detail = detail


class UnauthorizedError(WikiBaseError):
    def __init__(self, detail: str = "Session expired or missing"):
        super().__init__(401, "unauthorized", detail)


class NotFoundError(WikiBaseError):
    def __init__(self, detail: str = "Resource not found"):
        super().__init__(404, "not_found", detail)


class CanvasTokenExpiredError(WikiBaseError):
    def __init__(self, detail: str = "Canvas token expired and refresh failed"):
        super().__init__(401, "canvas_token_expired", detail)


class SyncInProgressError(WikiBaseError):
    def __init__(self, detail: str = "A sync is already in progress"):
        super().__init__(409, "sync_in_progress", detail)


class IngestionJobConflictError(WikiBaseError):
    def __init__(self, job_id: str):
        super().__init__(
            409,
            "ingestion_job_conflict",
            f"An active ingestion job already exists for this source batch: {job_id}",
        )
        self.job_id = job_id


class IngestionJobStateError(WikiBaseError):
    def __init__(self, detail: str = "Ingestion job status cannot be changed"):
        super().__init__(409, "ingestion_job_state_conflict", detail)


class RateLimitedError(WikiBaseError):
    def __init__(self, detail: str = "Too many requests"):
        super().__init__(429, "rate_limited", detail)


async def wikibase_error_handler(request: Request, exc: WikiBaseError) -> JSONResponse:
    return JSONResponse(
        status_code=exc.status_code,
        content={"error": exc.error, "detail": exc.detail},
    )
