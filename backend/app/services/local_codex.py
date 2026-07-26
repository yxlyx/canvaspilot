import asyncio
import os
import signal
import tempfile
from pathlib import Path

from app.config import Settings, get_settings
from app.exceptions import WikiBaseError

_MAX_OUTPUT_BYTES = 64 * 1024
_MAX_ERROR_BYTES = 4 * 1024
_CLI_SEMAPHORE = asyncio.Semaphore(1)
_ALLOWED_ENVIRONMENT_KEYS = {
    "CODEX_HOME",
    "HOME",
    "HTTP_PROXY",
    "HTTPS_PROXY",
    "LANG",
    "LC_ALL",
    "NO_PROXY",
    "PATH",
    "SSL_CERT_DIR",
    "SSL_CERT_FILE",
    "TMPDIR",
}


def _configuration(settings: Settings | None = None) -> tuple[str, int]:
    settings = settings or get_settings()
    environment = settings.environment.strip().lower()
    path = Path(settings.local_codex_cli_path).expanduser()
    if not settings.local_codex_cli_enabled or environment not in {"development", "dev"}:
        raise WikiBaseError(
            409,
            "local_codex_unavailable",
            "Local Codex CLI access is disabled for this workspace",
        )
    if (
        not path.is_absolute()
        or path.name != "codex"
        or not path.is_file()
        or not os.access(path, os.X_OK)
    ):
        raise WikiBaseError(
            409,
            "local_codex_unavailable",
            "The configured local Codex CLI executable is unavailable",
        )
    return str(path), settings.local_codex_cli_timeout_seconds


def _subprocess_environment() -> dict[str, str]:
    return {key: value for key, value in os.environ.items() if key in _ALLOWED_ENVIRONMENT_KEYS}


async def _terminate(process: asyncio.subprocess.Process) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    await process.wait()


async def _run(
    *args: str,
    stdin: bytes | None = None,
    timeout_seconds: int,
    output_path: Path | None = None,
) -> tuple[int, str, str]:
    async with _CLI_SEMAPHORE:
        with tempfile.TemporaryFile() as output_stream, tempfile.TemporaryFile() as errors:
            spawn = asyncio.create_task(
                asyncio.create_subprocess_exec(
                    *args,
                    stdin=(
                        asyncio.subprocess.PIPE if stdin is not None else asyncio.subprocess.DEVNULL
                    ),
                    stdout=output_stream,
                    stderr=errors,
                    env=_subprocess_environment(),
                    start_new_session=True,
                )
            )
            try:
                process = await asyncio.shield(spawn)
            except asyncio.CancelledError:
                process = await spawn
                await _terminate(process)
                raise
            try:
                await asyncio.wait_for(process.communicate(stdin), timeout=timeout_seconds)
            except TimeoutError:
                await _terminate(process)
                raise WikiBaseError(
                    504,
                    "local_codex_timeout",
                    "The local Codex CLI did not finish in time",
                ) from None
            except asyncio.CancelledError:
                await _terminate(process)
                raise
            output_stream.seek(0)
            output_text = (
                output_stream.read(_MAX_ERROR_BYTES).decode("utf-8", errors="replace").strip()
            )
            errors.seek(0)
            error_text = errors.read(_MAX_ERROR_BYTES).decode("utf-8", errors="replace").strip()
    if (
        output_path is not None
        and output_path.exists()
        and output_path.stat().st_size > _MAX_OUTPUT_BYTES
    ):
        raise WikiBaseError(
            502,
            "local_codex_invalid_response",
            "The local Codex CLI returned an oversized response",
        )
    return process.returncode or 0, output_text, error_text


async def validate_local_codex(settings: Settings | None = None) -> None:
    settings = settings or get_settings()
    executable, timeout_seconds = _configuration(settings)
    version_code, version_output, _ = await _run(
        executable,
        "--version",
        timeout_seconds=min(timeout_seconds, 10),
    )
    if version_code != 0 or not version_output.startswith("codex-cli "):
        raise WikiBaseError(
            409,
            "local_codex_unavailable",
            "The configured executable is not a supported Codex CLI",
        )
    code, status_output, status_error = await _run(
        executable,
        "login",
        "status",
        timeout_seconds=min(timeout_seconds, 10),
    )
    status_text = status_output or status_error
    if code != 0 or not status_text.startswith("Logged in using ChatGPT"):
        raise WikiBaseError(
            409,
            "local_codex_login_required",
            "Sign in with the local Codex CLI before connecting it",
        )


async def generate_with_local_codex(
    prompt: str,
    model: str,
    settings: Settings | None = None,
) -> str:
    settings = settings or get_settings()
    executable, timeout_seconds = _configuration(settings)
    if not prompt.strip() or len(prompt) > settings.local_codex_cli_max_prompt_chars:
        raise WikiBaseError(
            422,
            "local_codex_prompt_invalid",
            "The local Codex request is empty or too large",
        )
    with tempfile.TemporaryDirectory(prefix="canvaspilot-codex-") as directory:
        root = Path(directory)
        output = root / "answer.txt"
        args = [
            executable,
            "exec",
            "--ephemeral",
            "--ignore-user-config",
            "--ignore-rules",
            "--strict-config",
            "--disable",
            "shell_tool",
            "--disable",
            "unified_exec",
            "--disable",
            "apps",
            "--disable",
            "browser_use",
            "--disable",
            "computer_use",
            "--disable",
            "multi_agent",
            "--disable",
            "plugins",
            "--disable",
            "image_generation",
            "--disable",
            "in_app_browser",
            "--disable",
            "browser_use_external",
            "--disable",
            "browser_use_full_cdp_access",
            "--disable",
            "remote_plugin",
            "--disable",
            "skill_search",
            "--sandbox",
            "read-only",
            "--skip-git-repo-check",
            "--color",
            "never",
            "--cd",
            str(root),
        ]
        if model and model != "Codex CLI default":
            args.extend(["--model", model])
        args.extend(["--output-last-message", str(output), "-"])
        code, _, error_text = await _run(
            *args,
            stdin=prompt.encode("utf-8"),
            timeout_seconds=timeout_seconds,
            output_path=output,
        )
        if code != 0:
            message = (
                "The local Codex CLI login is no longer valid"
                if "login" in error_text.lower() or "unauthorized" in error_text.lower()
                else "The local Codex CLI could not generate an answer"
            )
            error = (
                "local_codex_login_required"
                if message.endswith("valid")
                else "local_codex_generation_failed"
            )
            raise WikiBaseError(409 if error.endswith("required") else 502, error, message)
        if not output.exists() or output.is_symlink() or not output.is_file():
            raise WikiBaseError(
                502,
                "local_codex_invalid_response",
                "The local Codex CLI returned no final answer",
            )
        answer = output.read_text(encoding="utf-8").strip()
        if not answer:
            raise WikiBaseError(
                502,
                "local_codex_invalid_response",
                "The local Codex CLI returned an empty final answer",
            )
        return answer
