import uuid

from fastapi import APIRouter, Depends
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from app.db.database import get_db
from app.dependencies import get_current_user
from app.exceptions import NotFoundError
from app.models.curriculum import CurriculumTopic, ModuleEnrollment
from app.models.user import User
from app.schemas.curriculum import (
    AssociationDecisionRequest,
    CandidateSourceChunkResponse,
    CandidateSourceResponse,
    CoverageDashboardResponse,
    EnrollmentLearningMetricsResponse,
    EnrollmentResponse,
    ManualAssociationRequest,
    ProposalGenerationRequest,
    ProposalGenerationResponse,
    SyllabusRefinementRequest,
    TopicListUpdate,
    TopicResponse,
    TopicRevisionDecision,
    TopicRevisionResponse,
    TopicSourceAssociationResponse,
)
from app.services.curriculum import (
    propose_syllabus_refinement,
    review_topic_revision,
    save_reviewed_topics,
)
from app.services.curriculum_coverage import (
    add_manual_association,
    association_payload,
    candidate_sources,
    coverage_dashboard,
    decide_association,
    generate_proposals,
    remove_confirmed_association,
    selectable_evidence_chunks,
)
from app.services.learning_metrics import enrollment_learning_metrics

router = APIRouter(prefix="/enrollments", tags=["curriculum"])


async def _owned_enrollment(
    enrollment_id: uuid.UUID,
    user: User,
    db: AsyncSession,
    *,
    for_update: bool = False,
) -> ModuleEnrollment:
    statement = select(ModuleEnrollment).where(
        ModuleEnrollment.id == enrollment_id,
        ModuleEnrollment.user_id == user.id,
    )
    if for_update:
        statement = statement.with_for_update(of=ModuleEnrollment)
    enrollment = (await db.execute(statement)).scalar_one_or_none()
    if enrollment is None:
        raise NotFoundError("Enrollment not found")
    return enrollment


@router.get("", response_model=list[EnrollmentResponse])
async def list_enrollments(
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollments = list(
        (
            await db.execute(
                select(ModuleEnrollment)
                .where(ModuleEnrollment.user_id == user.id)
                .order_by(ModuleEnrollment.created_at, ModuleEnrollment.id)
            )
        ).scalars()
    )
    return [
        EnrollmentResponse(
            id=enrollment.id,
            code=enrollment.offering.catalog_module.canonical_code,
            title=enrollment.offering.provider_snapshot.payload["title"],
            academic_year=enrollment.offering.academic_year,
            semester=enrollment.offering.semester,
            provenance=enrollment.provenance,
            import_method=enrollment.import_method,
            topic_state=enrollment.topic_state,
            evidence_warning=enrollment.evidence_warning,
            lesson_config=enrollment.lesson_config,
            archived=enrollment.archived,
            institution=enrollment.offering.catalog_module.institution,
            provider=enrollment.offering.provider_snapshot.provider,
            provider_version=enrollment.offering.provider_snapshot.provider_version,
            provider_academic_year=enrollment.offering.provider_snapshot.academic_year,
            source_url=enrollment.offering.provider_snapshot.source_url,
            provider_fetched_at=enrollment.offering.provider_snapshot.fetched_at,
            payload_sha256=enrollment.offering.provider_snapshot.payload_sha256,
        )
        for enrollment in enrollments
    ]


@router.get(
    "/{enrollment_id}/learning-metrics",
    response_model=EnrollmentLearningMetricsResponse,
)
async def learning_metrics(
    enrollment_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db)
    return await enrollment_learning_metrics(enrollment, db)


@router.get("/{enrollment_id}/topics", response_model=list[TopicResponse])
async def list_topics(
    enrollment_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db)
    return list(
        (
            await db.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment.id)
                .order_by(CurriculumTopic.position)
            )
        ).scalars()
    )


@router.put("/{enrollment_id}/topics", response_model=list[TopicResponse])
async def put_topics(
    enrollment_id: uuid.UUID,
    payload: TopicListUpdate,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db, for_update=True)
    topics = await save_reviewed_topics(enrollment, payload, db)
    await db.commit()
    return topics


@router.post("/{enrollment_id}/topic-revisions", response_model=TopicRevisionResponse)
async def preview_syllabus_refinement(
    enrollment_id: uuid.UUID,
    payload: SyllabusRefinementRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db)
    revision = await propose_syllabus_refinement(
        enrollment=enrollment, source_id=payload.source_id, user=user, db=db
    )
    await db.commit()
    await db.refresh(revision)
    return revision


@router.post("/{enrollment_id}/topic-revisions/{revision_id}", response_model=TopicRevisionResponse)
async def review_syllabus_refinement(
    enrollment_id: uuid.UUID,
    revision_id: uuid.UUID,
    payload: TopicRevisionDecision,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db)
    revision = await review_topic_revision(
        enrollment=enrollment,
        revision_id=revision_id,
        decision=payload.decision,
        user=user,
        db=db,
    )
    await db.commit()
    await db.refresh(revision)
    return revision


@router.get("/{enrollment_id}/coverage", response_model=CoverageDashboardResponse)
async def get_coverage(
    enrollment_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db)
    return await coverage_dashboard(enrollment, db)


@router.post("/{enrollment_id}/coverage/proposals", response_model=ProposalGenerationResponse)
async def post_coverage_proposals(
    enrollment_id: uuid.UUID,
    payload: ProposalGenerationRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db, for_update=True)
    result = await generate_proposals(enrollment, payload.source_ids, user, db)
    result["associations"] = [
        await association_payload(row, enrollment, db) for row in result["associations"]
    ]
    await db.commit()
    return result


@router.post(
    "/{enrollment_id}/source-associations",
    response_model=TopicSourceAssociationResponse,
)
async def post_source_association(
    enrollment_id: uuid.UUID,
    payload: ManualAssociationRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db, for_update=True)
    association = await add_manual_association(
        enrollment,
        payload.topic_id,
        payload.source_id,
        payload.chunk_ids,
        payload.reason_code,
        user,
        db,
    )
    response = await association_payload(association, enrollment, db)
    await db.commit()
    return response


@router.post(
    "/{enrollment_id}/source-associations/{association_id}/decision",
    response_model=TopicSourceAssociationResponse,
)
async def post_association_decision(
    enrollment_id: uuid.UUID,
    association_id: uuid.UUID,
    payload: AssociationDecisionRequest,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db, for_update=True)
    association = await decide_association(enrollment, association_id, payload.decision, user, db)
    response = await association_payload(association, enrollment, db)
    await db.commit()
    return response


@router.delete(
    "/{enrollment_id}/source-associations/{association_id}",
    response_model=TopicSourceAssociationResponse,
)
async def delete_source_association(
    enrollment_id: uuid.UUID,
    association_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db, for_update=True)
    association = await remove_confirmed_association(enrollment, association_id, user, db)
    response = await association_payload(association, enrollment, db)
    await db.commit()
    return response


@router.get(
    "/{enrollment_id}/candidate-sources/{source_id}/chunks",
    response_model=list[CandidateSourceChunkResponse],
)
async def get_candidate_source_chunks(
    enrollment_id: uuid.UUID,
    source_id: uuid.UUID,
    topic_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db)
    return await selectable_evidence_chunks(enrollment, topic_id, source_id, db)


@router.get("/{enrollment_id}/candidate-sources", response_model=list[CandidateSourceResponse])
async def get_candidate_sources(
    enrollment_id: uuid.UUID,
    user: User = Depends(get_current_user),
    db: AsyncSession = Depends(get_db),
):
    enrollment = await _owned_enrollment(enrollment_id, user, db)
    return await candidate_sources(enrollment, db)
