import uuid
from urllib.parse import quote

from fastapi import APIRouter, Body, Depends, Query, Response, status
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.m3 import (
    HealthFindingResponse,
    HistoryEntryResponse,
    MarkedPaperQuestionCreate,
    MarkedPaperQuestionUpdate,
    MarkedPaperResponse,
    MarkedPaperUploadRequest,
    ProviderConfigureRequest,
    ProviderDescriptor,
    ProviderStatusResponse,
    RevisionDiffResponse,
    SourceChangeResponse,
    StudyOutputGenerateRequest,
    StudyOutputResponse,
    TopicMeterResponse,
    WikiRevisionResponse,
    WorkspaceExportRequest,
)
from app.services.exports import export_page, export_workspace
from app.services.marked_papers import (
    create_question,
    delete_marked_paper,
    delete_question,
    get_marked_paper,
    list_marked_papers,
    update_question,
    upload_marked_paper,
)
from app.services.meters import topic_meters
from app.services.providers import (
    PROVIDERS,
    configure_provider,
    disconnect_provider,
    list_settings,
    test_provider,
)
from app.services.study_outputs import (
    generate_study_output,
    get_study_output,
    list_study_outputs,
)
from app.services.workspace_health import (
    get_finding,
    get_revision_diff,
    history_entries,
    list_findings,
    list_revisions,
    list_source_changes,
    run_health_checks,
)

router = APIRouter(tags=["milestone-3"])


@router.post("/outputs", response_model=StudyOutputResponse, status_code=status.HTTP_201_CREATED)
async def generate_output(
    payload: StudyOutputGenerateRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await generate_study_output(user, payload, db)


@router.get("/outputs", response_model=list[StudyOutputResponse])
async def outputs(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await list_study_outputs(user, db)


@router.get("/outputs/{output_id}", response_model=StudyOutputResponse)
async def output_detail(
    output_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_study_output(user, output_id, db)


def _download_response(content: bytes, filename: str, media_type: str) -> Response:
    safe_filename = quote(filename, safe="-_.")
    return Response(
        content=content,
        media_type=media_type,
        headers={
            "Content-Disposition": (
                f"attachment; filename={safe_filename}; filename*=UTF-8''{safe_filename}"
            ),
            "X-Content-Type-Options": "nosniff",
        },
    )


@router.get("/wiki/pages/{slug}/download")
async def download_page(
    slug: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    exported = await export_page(user, slug, db)
    return _download_response(exported.content, exported.filename, exported.media_type)


@router.post("/wiki/download")
async def download_workspace(
    payload: WorkspaceExportRequest | None = Body(default=None),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    exported = await export_workspace(user, db, payload.page_ids if payload else None)
    return _download_response(exported.content, exported.filename, exported.media_type)


@router.get("/wiki/pages/{page_id}/revisions", response_model=list[WikiRevisionResponse])
async def revisions(
    page_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_revisions(user, page_id, db)


@router.get("/wiki/pages/{page_id}/diff", response_model=RevisionDiffResponse)
async def wiki_diff(
    page_id: uuid.UUID,
    from_revision: int = Query(ge=1),
    to_revision: int = Query(ge=1),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    diff = await get_revision_diff(user, page_id, from_revision, to_revision, db)
    return RevisionDiffResponse(
        page_id=page_id,
        from_revision=from_revision,
        to_revision=to_revision,
        diff=diff,
    )


@router.get("/workspace/history", response_model=list[HistoryEntryResponse])
async def workspace_history(
    limit: int = Query(default=50, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await history_entries(user, db, limit)


@router.get("/workspace/source-changes", response_model=list[SourceChangeResponse])
async def source_changes(
    limit: int = Query(default=50, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_source_changes(user, db, limit)


@router.post("/workspace/health", response_model=list[HealthFindingResponse])
async def execute_health_checks(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await run_health_checks(user, db)


@router.get("/workspace/health", response_model=list[HealthFindingResponse])
async def health_findings(
    limit: int = Query(default=50, ge=1, le=100),
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await list_findings(user, db, limit)


@router.get("/workspace/health/{finding_id}", response_model=HealthFindingResponse)
async def health_finding_detail(
    finding_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_finding(user, finding_id, db)


@router.get("/meters/topics", response_model=list[TopicMeterResponse])
async def meters(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await topic_meters(user, db)


@router.post(
    "/marked-papers", response_model=MarkedPaperResponse, status_code=status.HTTP_201_CREATED
)
async def create_marked_paper(
    payload: MarkedPaperUploadRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await upload_marked_paper(user, payload, db)


@router.get("/marked-papers", response_model=list[MarkedPaperResponse])
async def marked_papers(user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)):
    return await list_marked_papers(user, db)


@router.get("/marked-papers/{paper_id}", response_model=MarkedPaperResponse)
async def marked_paper_detail(
    paper_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await get_marked_paper(user, paper_id, db)


@router.post(
    "/marked-papers/{paper_id}/questions",
    response_model=MarkedPaperResponse,
    status_code=status.HTTP_201_CREATED,
)
async def add_marked_question(
    paper_id: uuid.UUID,
    payload: MarkedPaperQuestionCreate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await create_question(user, paper_id, payload, db)


@router.patch(
    "/marked-papers/{paper_id}/questions/{question_id}", response_model=MarkedPaperResponse
)
async def review_marked_question(
    paper_id: uuid.UUID,
    question_id: uuid.UUID,
    payload: MarkedPaperQuestionUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await update_question(user, paper_id, question_id, payload, db)


@router.delete(
    "/marked-papers/{paper_id}/questions/{question_id}",
    response_model=MarkedPaperResponse,
)
async def remove_marked_question(
    paper_id: uuid.UUID,
    question_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await delete_question(user, paper_id, question_id, db)


@router.delete("/marked-papers/{paper_id}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_marked_paper(
    paper_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await delete_marked_paper(user, paper_id, db)


@router.get("/providers", response_model=list[ProviderDescriptor])
async def supported_providers():
    return list(PROVIDERS.values())


@router.get("/providers/settings", response_model=list[ProviderStatusResponse])
async def provider_settings(
    user: User = Depends(get_current_user), db: AsyncSession = Depends(get_db)
):
    return await list_settings(user, db)


@router.put("/providers/settings", response_model=ProviderStatusResponse)
async def save_provider(
    payload: ProviderConfigureRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await configure_provider(user, payload, db)


@router.post("/providers/{provider}/test", response_model=ProviderStatusResponse)
async def validate_provider(
    provider: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    return await test_provider(user, provider, db)


@router.delete("/providers/{provider}", status_code=status.HTTP_204_NO_CONTENT)
async def remove_provider(
    provider: str,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    await disconnect_provider(user, provider, db)
