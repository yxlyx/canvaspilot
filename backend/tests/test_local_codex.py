from pathlib import Path

import pytest

from app.exceptions import WikiBaseError
from app.services import local_codex


def _fake_codex(tmp_path: Path) -> str:
    executable = tmp_path / "codex"
    executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    executable.chmod(0o700)
    return str(executable)


@pytest.mark.asyncio
async def test_local_codex_validation_uses_status_without_exposing_credentials(
    monkeypatch, tmp_path
):
    settings = local_codex.get_settings().model_copy(
        update={
            "environment": "development",
            "local_codex_cli_enabled": True,
            "local_codex_cli_path": _fake_codex(tmp_path),
        }
    )
    observed: list[tuple[str, ...]] = []

    async def run(*args, **kwargs):
        observed.append(args)
        assert kwargs.get("stdin") is None
        if args[1] == "--version":
            return 0, "codex-cli 0.145.0", ""
        return 0, "Logged in using ChatGPT", ""

    monkeypatch.setattr(local_codex, "_run", run)
    await local_codex.validate_local_codex(settings)

    assert [args[1:] for args in observed] == [
        ("--version",),
        ("login", "status"),
    ]


@pytest.mark.asyncio
async def test_local_codex_generation_is_ephemeral_read_only_and_bounded(monkeypatch, tmp_path):
    settings = local_codex.get_settings().model_copy(
        update={
            "environment": "development",
            "local_codex_cli_enabled": True,
            "local_codex_cli_path": _fake_codex(tmp_path),
        }
    )

    async def run(*args, **kwargs):
        output_path: Path = kwargs["output_path"]
        output_path.write_text("Grounded answer [1]", encoding="utf-8")
        assert kwargs["stdin"] == b"Question and source context"
        assert "--ephemeral" in args
        assert "--ignore-user-config" in args
        assert "read-only" in args
        assert "--output-last-message" in args
        disabled_pairs = set(zip(args, args[1:], strict=False))
        for capability in (
            "shell_tool",
            "unified_exec",
            "apps",
            "browser_use",
            "computer_use",
            "multi_agent",
            "plugins",
            "image_generation",
            "in_app_browser",
            "browser_use_external",
            "browser_use_full_cdp_access",
            "remote_plugin",
            "skill_search",
        ):
            assert ("--disable", capability) in disabled_pairs
        return 0, "", ""

    monkeypatch.setattr(local_codex, "_run", run)
    answer = await local_codex.generate_with_local_codex(
        "Question and source context",
        "gpt-5-codex",
        settings,
    )

    assert answer == "Grounded answer [1]"


@pytest.mark.asyncio
async def test_local_codex_is_rejected_when_not_explicitly_enabled():
    settings = local_codex.get_settings().model_copy(
        update={
            "environment": "development",
            "local_codex_cli_enabled": False,
            "local_codex_cli_path": "/bin/echo",
        }
    )

    with pytest.raises(WikiBaseError) as exc_info:
        await local_codex.validate_local_codex(settings)

    assert exc_info.value.error == "local_codex_unavailable"
