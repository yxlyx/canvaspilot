import base64
import json
import uuid
from datetime import datetime

from app.exceptions import WikiBaseError


def encode_cursor(created_at: datetime, resource_id: uuid.UUID) -> str:
    payload = json.dumps([created_at.isoformat(), str(resource_id)], separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(payload).rstrip(b"=").decode()


def decode_cursor(cursor: str) -> tuple[datetime, uuid.UUID]:
    try:
        padded = cursor + "=" * (-len(cursor) % 4)
        created_raw, id_raw = json.loads(base64.b64decode(padded, altchars=b"-_", validate=True))
        created_at = datetime.fromisoformat(created_raw)
        if created_at.tzinfo is None:
            raise ValueError
        return created_at, uuid.UUID(id_raw)
    except (ValueError, TypeError, json.JSONDecodeError) as exc:
        raise WikiBaseError(400, "invalid_cursor", "Invalid pagination cursor") from exc
