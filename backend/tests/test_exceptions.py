from app.exceptions import (
    CanvasPilotError,
    CanvasTokenExpiredError,
    NotFoundError,
    RateLimitedError,
    SyncInProgressError,
    UnauthorizedError,
)


class TestExceptions:
    def test_unauthorized_defaults(self):
        err = UnauthorizedError()
        assert err.status_code == 401
        assert err.error == "unauthorized"

    def test_unauthorized_custom_detail(self):
        err = UnauthorizedError("Custom message")
        assert err.detail == "Custom message"

    def test_not_found(self):
        err = NotFoundError("Module not found")
        assert err.status_code == 404
        assert err.error == "not_found"

    def test_canvas_token_expired(self):
        err = CanvasTokenExpiredError()
        assert err.status_code == 401
        assert err.error == "canvas_token_expired"

    def test_sync_in_progress(self):
        err = SyncInProgressError()
        assert err.status_code == 409
        assert err.error == "sync_in_progress"

    def test_rate_limited(self):
        err = RateLimitedError()
        assert err.status_code == 429

    def test_base_error(self):
        err = CanvasPilotError(500, "internal", "Something broke")
        assert err.status_code == 500
        assert err.error == "internal"
        assert err.detail == "Something broke"
