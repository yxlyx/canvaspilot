import base64
import binascii
import os
import subprocess
import sys
import tempfile
from pathlib import Path

from app.models.processing import SourceVersion
from app.models.source import SourceKind
from app.services.resource_admission import RESOURCE_INTENSIVE_PARSER_SLOT

MAX_PREVIEW_INPUT_BYTES = 10 * 1024 * 1024
MAX_PREVIEW_OUTPUT_BYTES = 5 * 1024 * 1024
MAX_PREVIEW_SECONDS = 12
MAX_PREVIEW_BASE64_CHARS = ((MAX_PREVIEW_INPUT_BYTES + 2) // 3) * 4


class SourcePreviewError(ValueError):
    pass


class SourcePreviewUnsupportedError(SourcePreviewError):
    pass


class SourcePreviewUnavailableError(SourcePreviewError):
    pass


def _decode_file_content(payload: dict) -> bytes:
    encoded = payload.get("content_base64")
    if not isinstance(encoded, str) or not encoded:
        raise SourcePreviewUnsupportedError("This source has no file preview")
    if len(encoded) > MAX_PREVIEW_BASE64_CHARS:
        raise SourcePreviewUnsupportedError("This source preview is unavailable")
    try:
        content = base64.b64decode(encoded, validate=True)
    except (ValueError, binascii.Error) as exc:
        raise SourcePreviewUnsupportedError("This source preview is unavailable") from exc
    if not content or len(content) > MAX_PREVIEW_INPUT_BYTES:
        raise SourcePreviewUnsupportedError("This source preview is unavailable")
    return content


def _text_content(payload: dict) -> bytes:
    content = payload.get("content")
    if not isinstance(content, str) or not content.strip():
        raise SourcePreviewUnsupportedError("This source has no text preview")
    encoded = content.encode("utf-8")
    if len(encoded) > MAX_PREVIEW_INPUT_BYTES:
        encoded = encoded[:MAX_PREVIEW_INPUT_BYTES]
    return encoded


def _render_isolated(kind: str, content: bytes) -> bytes:
    backend_root = Path(__file__).resolve().parents[2]
    worker_env = {
        "LANG": "C.UTF-8",
        "PATH": os.defpath,
        "PYTHONHASHSEED": "random",
        "PYTHONPATH": str(backend_root),
    }
    try:
        with (
            RESOURCE_INTENSIVE_PARSER_SLOT,
            tempfile.TemporaryDirectory(prefix="source-preview-") as workdir,
        ):
            result = subprocess.run(
                [sys.executable, "-m", "app.services.source_preview_worker", kind],
                input=content,
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=MAX_PREVIEW_SECONDS,
                check=False,
                cwd=workdir,
                env=worker_env,
            )
    except subprocess.TimeoutExpired as exc:
        raise SourcePreviewUnavailableError(
            "The first-page preview took too long to create"
        ) from exc
    except OSError as exc:
        raise SourcePreviewUnavailableError("The first-page preview could not be created") from exc

    if (
        result.returncode != 0
        or not result.stdout.startswith(b"\x89PNG\r\n\x1a\n")
        or len(result.stdout) > MAX_PREVIEW_OUTPUT_BYTES
    ):
        raise SourcePreviewUnavailableError("The first-page preview could not be created")
    return result.stdout


def render_source_preview(source_type: SourceKind, version: SourceVersion) -> bytes:
    payload = version.payload if isinstance(version.payload, dict) else {}
    if source_type == SourceKind.PDF:
        return _render_isolated("pdf", _decode_file_content(payload))
    if source_type == SourceKind.IMAGE:
        return _render_isolated("image", _decode_file_content(payload))
    if source_type in (SourceKind.MARKDOWN, SourceKind.PLAIN_TEXT):
        return _render_isolated("text", _text_content(payload))
    raise SourcePreviewUnsupportedError("This source format does not have a document preview")
