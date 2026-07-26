import json
import uuid
from datetime import UTC, datetime
from decimal import Decimal

import pytest
from pydantic_core import PydanticSerializationError

from app.services.processing import _fingerprint, _json_compatible


def test_coverage_snapshot_normalization_precedes_fingerprinting_and_persistence():
    identifier = uuid.uuid4()
    observed_at = datetime.now(UTC)
    dashboard = {
        "topic_id": identifier,
        "observed_at": observed_at,
        "score": Decimal("1.25"),
        "nested": [identifier],
    }

    snapshot = _json_compatible(dashboard)

    assert snapshot == {
        "topic_id": str(identifier),
        "observed_at": observed_at.isoformat().replace("+00:00", "Z"),
        "score": "1.25",
        "nested": [str(identifier)],
    }
    assert json.loads(json.dumps(snapshot)) == snapshot
    assert _fingerprint(snapshot) == _fingerprint(_json_compatible(snapshot))


def test_coverage_snapshot_normalization_rejects_unknown_types():
    with pytest.raises(PydanticSerializationError):
        _json_compatible({"unsupported": object()})
