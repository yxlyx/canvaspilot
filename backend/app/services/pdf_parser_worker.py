import json
import sys

from app.services import source_parsers

_PYPDF_LIMIT_NAMES = (
    "FLATE_MAX_BUFFER_SIZE",
    "JBIG2_MAX_OUTPUT_LENGTH",
    "LZW_MAX_OUTPUT_LENGTH",
    "MAX_ARRAY_BASED_STREAM_OUTPUT_LENGTH",
    "MAX_DECLARED_STREAM_LENGTH",
    "RUN_LENGTH_MAX_OUTPUT_LENGTH",
    "ZLIB_MAX_OUTPUT_LENGTH",
)


def _apply_pypdf_limits() -> None:
    from pypdf import filters

    for name in _PYPDF_LIMIT_NAMES:
        setattr(filters, name, source_parsers.MAX_PDF_EXPANDED_STREAM_BYTES)


def _apply_resource_limits() -> None:
    _apply_pypdf_limits()
    try:
        import resource
    except ImportError:
        return

    cpu_seconds = source_parsers.MAX_PDF_PARSE_SECONDS
    resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds + 1))
    if sys.platform.startswith("linux"):
        memory_bytes = source_parsers.MAX_PDF_PARSER_MEMORY_BYTES
        resource.setrlimit(resource.RLIMIT_AS, (memory_bytes, memory_bytes))


def _write_result(payload: dict[str, object]) -> None:
    encoded = json.dumps(payload, ensure_ascii=False, separators=(",", ":")).encode()
    if len(encoded) > source_parsers.MAX_PDF_WORKER_OUTPUT_BYTES:
        encoded = b'{"error":"PDF extracted text exceeds the safe output limit"}'
    sys.stdout.buffer.write(encoded)


def main() -> int:
    _apply_resource_limits()
    pdf_bytes = sys.stdin.buffer.read(source_parsers.MAX_PDF_BYTES + 1)
    if len(pdf_bytes) > source_parsers.MAX_PDF_BYTES:
        _write_result({"error": "PDF exceeds the 10 MiB decoded size limit"})
        return 0
    try:
        sections = source_parsers._parse_pdf_bytes(pdf_bytes)
    except source_parsers.SourceParseError as exc:
        _write_result({"error": str(exc)})
        return 0
    except Exception:
        _write_result({"error": "PDF could not be parsed safely"})
        return 0
    _write_result({"sections": [section.model_dump(mode="json") for section in sections]})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
