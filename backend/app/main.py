from contextlib import asynccontextmanager

from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from starlette.middleware.sessions import SessionMiddleware

from app.config import get_settings
from app.db.database import init_db
from app.exceptions import CanvasPilotError, canvaspilot_error_handler
from app.routers import auth, chat, ingestion_jobs, modules, sources, sync, tasks

settings = get_settings()


@asynccontextmanager
async def lifespan(app: FastAPI):
    await init_db()
    yield


app = FastAPI(title="CanvasPilot API", version="0.1.0", lifespan=lifespan)

app.add_middleware(SessionMiddleware, secret_key=settings.session_secret)
app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origin_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.add_exception_handler(CanvasPilotError, canvaspilot_error_handler)

app.include_router(auth.router, prefix="/api")
app.include_router(modules.router, prefix="/api")
app.include_router(sources.router, prefix="/api")
app.include_router(ingestion_jobs.router, prefix="/api")
app.include_router(chat.router, prefix="/api")
app.include_router(tasks.router, prefix="/api")
app.include_router(sync.router, prefix="/api")


@app.get("/api/health")
async def health():
    return {"status": "ok"}
