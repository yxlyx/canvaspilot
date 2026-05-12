import logging

from fastapi import APIRouter, BackgroundTasks, Depends

from app.dependencies import get_current_user
from app.exceptions import SyncInProgressError
from app.models.user import User
from app.services.ingestion import sync_user_modules

logger = logging.getLogger(__name__)

router = APIRouter(prefix="/modules", tags=["sync"])

_active_syncs: set[str] = set()


async def _run_sync(user_id: str, user: User) -> None:
    from app.db.database import async_session_factory

    try:
        async with async_session_factory() as db:
            from sqlalchemy import select

            from app.models.user import User as UserModel

            result = await db.execute(select(UserModel).where(UserModel.id == user.id))
            fresh_user = result.scalar_one()
            await sync_user_modules(fresh_user, db)
    except Exception:
        logger.exception("Sync failed for user %s", user_id)
    finally:
        _active_syncs.discard(user_id)


@router.post("/sync")
async def trigger_sync(
    background_tasks: BackgroundTasks,
    user: User = Depends(get_current_user),
):
    user_id = str(user.id)
    if user_id in _active_syncs:
        raise SyncInProgressError()

    _active_syncs.add(user_id)
    background_tasks.add_task(_run_sync, user_id, user)
    return {"status": "started"}


@router.get("/sync/status")
async def sync_status(user: User = Depends(get_current_user)):
    user_id = str(user.id)
    if user_id in _active_syncs:
        return {"status": "in_progress"}
    return {"status": "idle"}
