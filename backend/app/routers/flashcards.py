import uuid

from fastapi import APIRouter, Depends, Query
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.flashcards import (
    FlashcardAttemptCreate,
    FlashcardAttemptResponse,
    FlashcardDeckResponse,
    FlashcardGenerateRequest,
    FlashcardGenerateResponse,
    LearningEvidenceResponse,
)
from app.schemas.sources import normalize_topic_tags
from app.services.flashcards import (
    generate_flashcard_deck,
    get_flashcard_deck,
    list_flashcard_decks,
    list_learning_evidence,
    log_flashcard_attempt,
)

router = APIRouter(prefix="/flashcards", tags=["flashcards"])


@router.post("/decks/generate", response_model=FlashcardGenerateResponse)
async def generate_deck(
    payload: FlashcardGenerateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    outcome = await generate_flashcard_deck(user, payload, db)
    return FlashcardGenerateResponse(
        deck=outcome.deck,
        generated_count=outcome.generated_count,
        message=outcome.message,
    )


@router.get("/decks", response_model=list[FlashcardDeckResponse])
async def list_decks(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_flashcard_decks(user, db)


@router.get("/decks/{deck_id}", response_model=FlashcardDeckResponse)
async def get_deck(
    deck_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_flashcard_deck(user, deck_id, db)


@router.post("/cards/{card_id}/attempts", response_model=FlashcardAttemptResponse)
async def submit_attempt(
    card_id: uuid.UUID,
    payload: FlashcardAttemptCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await log_flashcard_attempt(user, card_id, payload, db)


@router.get("/evidence", response_model=list[LearningEvidenceResponse])
async def list_evidence(
    topic_tag: str | None = Query(default=None),
    limit: int = Query(default=50, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    normalized_topic = None
    if topic_tag is not None:
        normalized = normalize_topic_tags([topic_tag])
        normalized_topic = normalized[0] if normalized else None
    return await list_learning_evidence(user, db, normalized_topic, limit)
