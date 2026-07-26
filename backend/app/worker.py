import argparse
import asyncio
import logging
import socket
import uuid

from app.db.database import async_session_factory
from app.services.processing import work_once

logger = logging.getLogger(__name__)

MAX_ERROR_BACKOFF_SECONDS = 30.0


async def run_worker(*, once: bool = False, poll_seconds: float = 1.0) -> None:
    worker_id = f"{socket.gethostname()}:{uuid.uuid4()}"
    error_backoff = poll_seconds
    while True:
        try:
            async with async_session_factory() as db:
                run = await work_once(db, worker_id)
        except asyncio.CancelledError:
            raise
        except Exception:
            if once:
                raise
            delay = min(error_backoff, MAX_ERROR_BACKOFF_SECONDS)
            error_backoff = min(delay * 2, MAX_ERROR_BACKOFF_SECONDS)
            logger.exception("processing worker iteration failed; retrying in %.2fs", delay)
            await asyncio.sleep(delay)
            continue
        error_backoff = poll_seconds
        if once:
            return
        if run is None:
            await asyncio.sleep(poll_seconds)


def main() -> None:
    parser = argparse.ArgumentParser(description="Run the local durable processing worker")
    parser.add_argument("--once", action="store_true")
    parser.add_argument("--poll-seconds", type=float, default=1.0)
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO)
    asyncio.run(run_worker(once=args.once, poll_seconds=args.poll_seconds))


if __name__ == "__main__":
    main()
