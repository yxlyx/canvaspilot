from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.sessions import SessionMiddleware
from starlette.responses import JSONResponse

from app.config import get_settings
from app.db.database import init_db
from app.exceptions import WikiBaseError, wikibase_error_handler
from app.routers import (
    account,
    activity,
    auth,
    chat,
    flashcards,
    ingestion_jobs,
    m3,
    modules,
    notifications,
    search,
    sources,
    sync,
    tasks,
    wiki,
)
from app.routers import (
    settings as settings_router,
)

settings = get_settings()


class RequestBodyLimitMiddleware:
    def __init__(self, app, max_bytes: int):
        self.app = app
        self.max_bytes = max_bytes

    async def __call__(self, scope, receive, send):
        if scope["type"] != "http":
            await self.app(scope, receive, send)
            return
        body = bytearray()
        more_body = True
        while more_body:
            message = await receive()
            if message["type"] == "http.disconnect":
                return
            body.extend(message.get("body", b""))
            if len(body) > self.max_bytes:
                response = JSONResponse(
                    status_code=413,
                    content={"detail": "Request body exceeds the configured transport limit"},
                )
                await response(scope, receive, send)
                return
            more_body = message.get("more_body", False)
        delivered = False

        async def replay_body():
            nonlocal delivered
            if delivered:
                return await receive()
            delivered = True
            return {"type": "http.request", "body": bytes(body), "more_body": False}

        await self.app(scope, replay_body, send)


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(title="WikiBase API", version="0.1.0", lifespan=lifespan)

app.add_middleware(RequestBodyLimitMiddleware, max_bytes=settings.max_request_body_bytes)
app.add_middleware(
    SessionMiddleware,
    secret_key=settings.session_secret,
    https_only=settings.secure_cookies,
    same_site="lax",
)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_exception_handler(WikiBaseError, wikibase_error_handler)

app.include_router(auth.router, prefix="/api")
app.include_router(account.router, prefix="/api")
app.include_router(settings_router.router, prefix="/api")
app.include_router(notifications.router, prefix="/api")
app.include_router(activity.router, prefix="/api")
app.include_router(modules.router, prefix="/api")
app.include_router(sources.router, prefix="/api")
app.include_router(search.router, prefix="/api")
app.include_router(ingestion_jobs.router, prefix="/api")
app.include_router(chat.router, prefix="/api")
app.include_router(flashcards.router, prefix="/api")
app.include_router(tasks.router, prefix="/api")
app.include_router(sync.router, prefix="/api")
app.include_router(wiki.router, prefix="/api")
app.include_router(m3.router, prefix="/api")


@app.get("/api/health")
async def health():
    return {"status": "ok"}
