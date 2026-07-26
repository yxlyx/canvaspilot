import hashlib
import json
from collections.abc import Awaitable, Callable
from datetime import UTC, datetime, timedelta
from typing import Any

from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse, Response
from pydantic import TypeAdapter
from sqlalchemy import delete, func, select, text
from sqlalchemy.exc import IntegrityError
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import WikiBaseError
from app.models.m3 import IdempotencyRecord
from app.models.user import User

IDEMPOTENCY_TTL = timedelta(hours=24)
MAX_IDEMPOTENCY_RECORDS_PER_USER = 1000
MAX_STORED_RESPONSE_BYTES = 64 * 1024
CLEANUP_BATCH_SIZE = 100


def request_hash(operation: str, payload: Any) -> str:
    encoded = json.dumps(
        {"operation": operation, "payload": jsonable_encoder(payload)},
        sort_keys=True,
        separators=(",", ":"),
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


async def cleanup_idempotency_records(
    db: AsyncSession, user: User, key: str, now: datetime
) -> None:
    """Bound cleanup without making unrelated keys wait on cleanup row locks.

    Concurrent mutations may temporarily overshoot the per-user cap by the number
    of in-flight keys. Later mutations remove the overshoot in bounded batches.
    """
    expired_ids = (
        select(IdempotencyRecord.id)
        .where(IdempotencyRecord.expires_at <= now)
        .order_by(IdempotencyRecord.expires_at.asc())
        .limit(CLEANUP_BATCH_SIZE)
        .with_for_update(skip_locked=True)
    )
    await db.execute(delete(IdempotencyRecord).where(IdempotencyRecord.id.in_(expired_ids)))

    count = await db.scalar(
        select(func.count(IdempotencyRecord.id)).where(
            IdempotencyRecord.user_id == user.id,
            IdempotencyRecord.idempotency_key != key,
        )
    )
    excess = max(0, (count or 0) - MAX_IDEMPOTENCY_RECORDS_PER_USER + 1)
    if excess:
        oldest_ids = (
            select(IdempotencyRecord.id)
            .where(
                IdempotencyRecord.user_id == user.id,
                IdempotencyRecord.idempotency_key != key,
            )
            .order_by(IdempotencyRecord.created_at.asc(), IdempotencyRecord.id.asc())
            .limit(min(excess, CLEANUP_BATCH_SIZE))
            .with_for_update(skip_locked=True)
        )
        await db.execute(delete(IdempotencyRecord).where(IdempotencyRecord.id.in_(oldest_ids)))


async def execute_idempotent(
    *,
    db: AsyncSession,
    user: User,
    key: str,
    operation: str,
    payload: Any,
    status_code: int,
    response_type: Any,
    execute: Callable[[], Awaitable[Any]],
    response_value: Callable[[Any], Any] | None = None,
    stored_response_value: Callable[[Any], Any] | None = None,
    replay_response_value: Callable[[Any], Awaitable[Any]] | None = None,
) -> Response:
    if (stored_response_value is None) != (replay_response_value is None):
        raise ValueError("Stored and replay response transforms must be configured together")
    if not 16 <= len(key) <= 128 or not all(char.isalnum() or char in "-_" for char in key):
        raise WikiBaseError(400, "invalid_idempotency_key", "Invalid Idempotency-Key header")

    now = datetime.now(UTC)
    # The key is unique per user across operations, so conflicting reuse must share this lock.
    await db.execute(
        text("SELECT pg_advisory_xact_lock(hashtextextended(:lock_key, 0))"),
        {"lock_key": f"idempotency:{user.id}:{key}"},
    )
    await db.execute(
        delete(IdempotencyRecord).where(
            IdempotencyRecord.user_id == user.id,
            IdempotencyRecord.idempotency_key == key,
            IdempotencyRecord.expires_at <= now,
        )
    )
    await cleanup_idempotency_records(db, user, key, now)

    digest = request_hash(operation, payload)
    record = IdempotencyRecord(
        user_id=user.id,
        idempotency_key=key,
        operation=operation,
        request_hash=digest,
        expires_at=now + IDEMPOTENCY_TTL,
    )
    try:
        async with db.begin_nested():
            db.add(record)
            await db.flush()
    except IntegrityError:
        existing = (
            await db.execute(
                select(IdempotencyRecord).where(
                    IdempotencyRecord.user_id == user.id,
                    IdempotencyRecord.idempotency_key == key,
                )
            )
        ).scalar_one()
        if existing.operation != operation or existing.request_hash != digest:
            raise WikiBaseError(
                409,
                "idempotency_key_reused",
                "Idempotency key was already used for a different request",
            )
        if existing.response_status is None:
            raise WikiBaseError(409, "idempotency_in_progress", "Idempotent request is in progress")
        if existing.response_status == 204:
            return Response(status_code=204)
        response_body = existing.response_body
        if replay_response_value is not None:
            replayed = await replay_response_value(response_body)
            response_body = jsonable_encoder(
                TypeAdapter(response_type).validate_python(replayed, from_attributes=True)
            )
        return JSONResponse(status_code=existing.response_status, content=response_body)

    try:
        result = await execute()
        response_result = response_value(result) if response_value is not None else result
        response_body = jsonable_encoder(
            TypeAdapter(response_type).validate_python(response_result, from_attributes=True)
        )
        stored_response_body = (
            stored_response_value(response_body)
            if stored_response_value is not None
            else response_body
        )
        encoded_response = json.dumps(stored_response_body, separators=(",", ":")).encode()
        if len(encoded_response) > MAX_STORED_RESPONSE_BYTES:
            raise WikiBaseError(
                500, "idempotency_response_too_large", "Mutation response cannot be stored safely"
            )
        record.response_status = status_code
        record.response_body = stored_response_body
        await db.commit()
    except Exception:
        await db.rollback()
        raise
    if status_code == 204:
        return Response(status_code=204)
    return JSONResponse(status_code=status_code, content=response_body)
