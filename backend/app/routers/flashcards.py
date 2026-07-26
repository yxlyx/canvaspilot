import uuid

from fastapi import APIRouter, Depends, Header, Query, Response
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.flashcards import (
    DraftAction,
    DraftCardAdd,
    DraftCardUpdate,
    DraftDeckUpdate,
    DraftReorder,
    FlashcardAttemptCreate,
    FlashcardAttemptResponse,
    FlashcardDeckResponse,
    FlashcardGenerateRequest,
    FlashcardGenerateResponse,
    FlashcardRevisionResponse,
    LearningEvidenceResponse,
)
from app.schemas.sources import normalize_topic_tags
from app.services.flashcards import (
    add_draft_card,
    generate_flashcard_deck,
    get_flashcard_deck,
    list_draft_revisions,
    list_flashcard_decks,
    list_learning_evidence,
    log_flashcard_attempt,
    mutate_draft_cards,
    transition_flashcard_deck,
    update_draft_card,
    update_draft_title,
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
    lifecycle: str | None = Query(default=None, pattern="^(draft|approved|retired|archived)$"),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_flashcard_decks(user, db, lifecycle)


@router.get("/study/decks", response_model=list[FlashcardDeckResponse])
async def list_study_decks(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_flashcard_decks(user, db, "approved")


@router.get("/decks/{deck_id}", response_model=FlashcardDeckResponse)
async def get_deck(
    deck_id: uuid.UUID,
    response: Response,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    deck = await get_flashcard_deck(user, deck_id, db)
    response.headers["ETag"] = f'"{deck.revision}"'
    return deck


@router.get("/drafts/{deck_id}", response_model=FlashcardDeckResponse)
async def get_draft(
    deck_id: uuid.UUID,
    response: Response,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    deck = await get_flashcard_deck(user, deck_id, db)
    response.headers["ETag"] = f'"{deck.revision}"'
    return deck


@router.get("/drafts/{deck_id}/revisions", response_model=list[FlashcardRevisionResponse])
async def get_draft_revisions(
    deck_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_draft_revisions(user, deck_id, db)


@router.patch("/drafts/{deck_id}", response_model=FlashcardDeckResponse)
async def edit_draft(
    deck_id: uuid.UUID,
    payload: DraftDeckUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_draft_title(user, deck_id, payload.title, payload.expected_revision, db)


@router.patch("/drafts/{deck_id}/cards/{card_id}", response_model=FlashcardDeckResponse)
async def edit_draft_card(
    deck_id: uuid.UUID,
    card_id: uuid.UUID,
    payload: DraftCardUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_draft_card(user, deck_id, card_id, payload, db)


@router.post("/drafts/{deck_id}/cards", response_model=FlashcardDeckResponse)
async def add_card(
    deck_id: uuid.UUID,
    payload: DraftCardAdd,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await add_draft_card(user, deck_id, payload, db)


async def _card_action(
    deck_id: uuid.UUID,
    action: str,
    payload: DraftAction,
    user: User,
    db: AsyncSession,
):
    return await mutate_draft_cards(
        user, deck_id, action, payload.card_ids, payload.expected_revision, db
    )


@router.post("/drafts/{deck_id}/reorder", response_model=FlashcardDeckResponse)
async def reorder_cards(
    deck_id: uuid.UUID,
    payload: DraftReorder,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await mutate_draft_cards(
        user, deck_id, "reorder", payload.card_ids, payload.expected_revision, db
    )


@router.post("/drafts/{deck_id}/discard", response_model=FlashcardDeckResponse)
async def discard_cards(
    deck_id: uuid.UUID,
    payload: DraftAction,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _card_action(deck_id, "discard", payload, user, db)


@router.post("/drafts/{deck_id}/restore", response_model=FlashcardDeckResponse)
async def restore_cards(
    deck_id: uuid.UUID,
    payload: DraftAction,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _card_action(deck_id, "restore", payload, user, db)


@router.post("/drafts/{deck_id}/approve", response_model=FlashcardDeckResponse)
async def approve_cards(
    deck_id: uuid.UUID,
    payload: DraftAction,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await _card_action(deck_id, "approve", payload, user, db)


@router.post("/decks/{deck_id}/publish", response_model=FlashcardDeckResponse)
async def publish_deck(
    deck_id: uuid.UUID,
    payload: DraftAction,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await transition_flashcard_deck(user, deck_id, "approved", db, payload.expected_revision)


@router.post("/decks/{deck_id}/archive", response_model=FlashcardDeckResponse)
async def archive_deck(
    deck_id: uuid.UUID,
    payload: DraftAction,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await transition_flashcard_deck(user, deck_id, "archived", db, payload.expected_revision)


@router.post("/decks/{deck_id}/retire", response_model=FlashcardDeckResponse)
async def retire_deck(
    deck_id: uuid.UUID,
    payload: DraftAction,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await transition_flashcard_deck(user, deck_id, "retired", db, payload.expected_revision)


@router.post("/cards/{card_id}/attempts", response_model=FlashcardAttemptResponse)
async def submit_attempt(
    card_id: uuid.UUID,
    payload: FlashcardAttemptCreate,
    idempotency_key: str | None = Header(default=None, alias="Idempotency-Key"),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await log_flashcard_attempt(user, card_id, payload, idempotency_key, db)


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
