import uuid
from datetime import UTC, datetime

from app.schemas.auth import UserResponse
from app.schemas.chat import ChatMessage, ChatRequest, Citation
from app.schemas.modules import AnnouncementResponse, ModuleResponse
from app.schemas.tasks import TaskResponse


class TestSnakeCaseSerialization:
    def test_module_response(self):
        resp = ModuleResponse(
            id=uuid.uuid4(),
            name="CS2103T",
            code="CS2103T",
            term="AY24/25 S2",
            last_synced_at=datetime(2026, 1, 1, tzinfo=UTC),
        )
        data = resp.model_dump()
        assert "last_synced_at" in data
        assert "lastSyncedAt" not in data

    def test_user_response(self):
        resp = UserResponse(
            id=uuid.uuid4(),
            name="Test",
            email="test@nus.edu",
            canvas_user_id=None,
        )
        data = resp.model_dump()
        assert "canvas_user_id" in data
        assert "canvasUserId" not in data

    def test_task_response(self):
        resp = TaskResponse(
            id=uuid.uuid4(),
            module_id=uuid.uuid4(),
            title="Assignment 1",
            task_type="assignment",
            due_at=datetime(2026, 3, 1, tzinfo=UTC),
            completed=False,
            source_url="http://example.com",
        )
        data = resp.model_dump()
        assert "task_type" in data
        assert "module_id" in data
        assert "source_url" in data
        assert "due_at" in data

    def test_announcement_response(self):
        resp = AnnouncementResponse(
            id=uuid.uuid4(),
            module_id=uuid.uuid4(),
            title="Welcome",
            content="Hello students",
            posted_at=datetime(2026, 1, 15, tzinfo=UTC),
            summary=None,
        )
        data = resp.model_dump()
        assert "module_id" in data
        assert "posted_at" in data

    def test_chat_request(self):
        req = ChatRequest(
            module_id=uuid.uuid4(),
            message="What is the deadline?",
            history=[
                ChatMessage(role="user", content="Hello"),
                ChatMessage(role="assistant", content="Hi!", citations=None),
            ],
        )
        data = req.model_dump()
        assert "module_id" in data

    def test_citation(self):
        c = Citation(title="Notes", url="http://x.com", snippet="Some text")
        data = c.model_dump()
        assert data["title"] == "Notes"
