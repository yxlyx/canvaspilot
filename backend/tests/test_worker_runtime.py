import asyncio
from contextlib import asynccontextmanager

import pytest

from app import worker


@pytest.mark.asyncio
async def test_continuous_worker_replaces_failed_session_after_backoff(monkeypatch):
    sessions = [object(), object()]
    opened: list[object] = []
    closed: list[object] = []
    sleeps: list[float] = []

    @asynccontextmanager
    async def session_factory():
        session = sessions[len(opened)]
        opened.append(session)
        try:
            yield session
        finally:
            closed.append(session)

    async def work_once(session, worker_id):
        assert worker_id
        if session is sessions[0]:
            raise RuntimeError("iteration failed")
        raise asyncio.CancelledError

    async def sleep(seconds):
        sleeps.append(seconds)

    monkeypatch.setattr(worker, "async_session_factory", session_factory)
    monkeypatch.setattr(worker, "work_once", work_once)
    monkeypatch.setattr(worker.asyncio, "sleep", sleep)

    with pytest.raises(asyncio.CancelledError):
        await worker.run_worker(poll_seconds=0.25)

    assert opened == sessions
    assert closed == sessions
    assert sleeps == [0.25]


@pytest.mark.asyncio
async def test_unexpected_error_backoff_is_capped_and_resets_after_success(monkeypatch):
    calls = 0
    sleeps: list[float] = []

    @asynccontextmanager
    async def session_factory():
        yield object()

    async def work_once(session, worker_id):
        nonlocal calls
        calls += 1
        if calls in {1, 2, 4}:
            raise RuntimeError("iteration failed")
        if calls == 3:
            return object()
        raise asyncio.CancelledError

    async def sleep(seconds):
        sleeps.append(seconds)

    monkeypatch.setattr(worker, "async_session_factory", session_factory)
    monkeypatch.setattr(worker, "work_once", work_once)
    monkeypatch.setattr(worker.asyncio, "sleep", sleep)
    monkeypatch.setattr(worker, "MAX_ERROR_BACKOFF_SECONDS", 0.5)

    with pytest.raises(asyncio.CancelledError):
        await worker.run_worker(poll_seconds=0.25)

    assert sleeps == [0.25, 0.5, 0.25]


@pytest.mark.asyncio
async def test_worker_propagates_cancellation(monkeypatch):
    @asynccontextmanager
    async def session_factory():
        yield object()

    async def work_once(session, worker_id):
        raise asyncio.CancelledError

    monkeypatch.setattr(worker, "async_session_factory", session_factory)
    monkeypatch.setattr(worker, "work_once", work_once)

    with pytest.raises(asyncio.CancelledError):
        await worker.run_worker()


@pytest.mark.asyncio
async def test_once_worker_reraises_iteration_failure(monkeypatch):
    @asynccontextmanager
    async def session_factory():
        yield object()

    async def work_once(session, worker_id):
        raise RuntimeError("iteration failed")

    monkeypatch.setattr(worker, "async_session_factory", session_factory)
    monkeypatch.setattr(worker, "work_once", work_once)

    with pytest.raises(RuntimeError, match="iteration failed"):
        await worker.run_worker(once=True)
