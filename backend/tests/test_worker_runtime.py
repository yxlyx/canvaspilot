import asyncio

import pytest

from app import main


@pytest.mark.asyncio
async def test_api_lifespan_runs_and_stops_processing_worker(monkeypatch):
    initialized = False
    started = asyncio.Event()
    stopped = asyncio.Event()

    async def fake_init_db():
        nonlocal initialized
        initialized = True

    async def fake_worker(*, poll_seconds: float):
        assert poll_seconds == 0.5
        started.set()
        try:
            await asyncio.Event().wait()
        finally:
            stopped.set()

    monkeypatch.setattr(main, "init_db", fake_init_db)
    monkeypatch.setattr(main, "run_worker", fake_worker)

    async with main.lifespan(main.app):
        await asyncio.wait_for(started.wait(), timeout=1)
        assert initialized is True
        assert main.app.state.processing_worker_task.done() is False

    assert stopped.is_set()
    assert main.app.state.processing_worker_task.cancelled()
