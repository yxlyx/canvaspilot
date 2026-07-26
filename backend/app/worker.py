import argparse
import asyncio
import logging
import socket
import uuid

from app.db.database import async_session_factory
from app.services.processing import work_once

logger = logging.getLogger(__name__)


async def run_worker(*, once: bool = False, poll_seconds: float = 1.0) -> None:
    worker_id = f"{socket.gethostname()}:{uuid.uuid4()}"
    while True:
        try:
            async with async_session_factory() as db:
                run = await work_once(db, worker_id)
        except asyncio.CancelledError:
            raise
        except Exception:
            if once:
                raise
            logger.exception("processing worker iteration failed; retrying")
            await asyncio.sleep(poll_seconds)
            continue
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
