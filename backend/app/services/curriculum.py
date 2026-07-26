import hashlib
import json
import re
import uuid
from datetime import UTC, datetime, timedelta
from typing import Any

from sqlalchemy import func, select, text, update
from sqlalchemy.dialects.postgresql import insert as postgresql_insert
from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.ext.asyncio import AsyncSession

from app.exceptions import NotFoundError, WikiBaseError
from app.models.curriculum import (
    CatalogModule,
    CurriculumTopic,
    ModuleEnrollment,
    ModuleImportItem,
    ModuleImportPreview,
    ProviderModuleSnapshot,
    SemesterOffering,
    TopicRevision,
)
from app.models.settings import UserPreference
from app.models.source import Source, SourceStatus
from app.models.source_chunk import SourceChunk, active_source_chunk_predicate
from app.models.user import User
from app.schemas.curriculum import ImportCommitResponse, ImportCommitResponseItem, TopicListUpdate
from app.schemas.source_imports import MAX_SOURCE_CHUNKS
from app.services.nusmods import (
    MAX_MODULES,
    NUSModsClient,
    ProviderSnapshot,
    ShareModule,
    canonical_payload_sha256,
    parse_share_url,
)

TOPIC_EXTRACTION_RULE = "catalog-phrases-v2"
SYLLABUS_REFINEMENT_RULE = "parser-locations-v2"
MANUAL_REVIEW_RULE = "manual-review-v1"
PROVISIONAL_WARNING = (
    "Provisional topics were extracted deterministically from the catalog description; "
    "review before using them as learning evidence."
)
INSTITUTION = "National University of Singapore"
CATALOG_NAMESPACE = uuid.UUID("95e70e84-627a-45ba-96df-c7828f58d8df")
OFFERING_NAMESPACE = uuid.UUID("764ad0f2-c0ad-48e5-8d39-5ab03227c9a7")
PROVIDER_SNAPSHOT_NAMESPACE = uuid.UUID("436455ee-7e90-45ae-968a-8122f25f6465")
ENROLLMENT_NAMESPACE = uuid.UUID("231028b5-1d2c-4a81-b228-36f51a2a5524")
TOPIC_NAMESPACE = uuid.UUID("5decd177-0991-424c-b6a1-07f569ea3bec")
RULE_DEFINITION = (
    "normalize-whitespace;strip-course-prefix;split-sentence-semicolon-colon-comma;"
    "strip-leading-topic-verb;deduplicate-casefold;length-3-300;limit-12"
)
RULE_HASH = hashlib.sha256(f"{TOPIC_EXTRACTION_RULE}:{RULE_DEFINITION}".encode()).hexdigest()
MANUAL_RULE_HASH = hashlib.sha256(MANUAL_REVIEW_RULE.encode()).hexdigest()
SYLLABUS_RULE_HASH = hashlib.sha256(SYLLABUS_REFINEMENT_RULE.encode()).hexdigest()


def _normalize_source(value: str) -> str:
    return re.sub(r"\s+", " ", value).strip()


def _sha256(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def _source_chunk_snapshot(chunk: Any) -> dict[str, Any]:
    return {
        "id": str(chunk.id),
        "chunk_index": chunk.chunk_index,
        "citation_ref": chunk.citation_ref,
        "location_label": chunk.location_label,
        "content_sha256": _sha256(chunk.content),
    }


async def _source_chunks_fingerprint(
    db: AsyncSession, source_id: uuid.UUID
) -> tuple[list[Any], list[dict[str, Any]], str, int]:
    statement = (
        select(
            SourceChunk.id,
            SourceChunk.chunk_index,
            SourceChunk.citation_ref,
            SourceChunk.location_label,
            SourceChunk.content,
        )
        .join(Source, Source.id == SourceChunk.source_id)
        .where(
            SourceChunk.source_id == source_id,
            active_source_chunk_predicate(SourceChunk, Source),
        )
        .order_by(SourceChunk.chunk_index)
        .with_for_update()
        .execution_options(yield_per=500)
    )
    chunks = await db.stream(statement)
    extraction_chunks: list[Any] = []
    snapshot: list[dict[str, Any]] = []
    digest = hashlib.sha256()
    digest.update(b"[")
    chunk_count = 0
    async for chunk in chunks:
        chunk_count += 1
        if chunk_count > MAX_SOURCE_CHUNKS:
            raise ValueError("Source exceeds the maximum supported chunk count")
        detail = _source_chunk_snapshot(chunk)
        if chunk_count <= 500:
            extraction_chunks.append(chunk)
            snapshot.append(detail)
        if chunk_count > 1:
            digest.update(b",")
        digest.update(json.dumps(detail, sort_keys=True, separators=(",", ":")).encode())
    digest.update(b"]")
    return extraction_chunks, snapshot, digest.hexdigest(), chunk_count


def extract_provisional_topics(description: str, *, limit: int = 12) -> list[str]:
    """Extract bounded topic phrases using the stable v2 rule definition."""
    normalized = _normalize_source(description)
    if not normalized:
        return []
    normalized = re.sub(
        r"^(?:this|the) (?:module|course) (?:introduces|covers|examines|focuses on)\s+",
        "",
        normalized,
        flags=re.IGNORECASE,
    )
    candidates = re.split(r"(?:[.!?;:]\s+|,\s+(?=[A-Z]))", normalized)
    topics: list[str] = []
    seen: set[str] = set()
    for candidate in candidates:
        title = re.sub(
            r"^(?:topics include|including|students learn|an introduction to)\s+",
            "",
            candidate.strip(" -.;:"),
            flags=re.IGNORECASE,
        )
        key = title.casefold()
        if 3 <= len(title) <= 300 and key not in seen:
            topics.append(title)
            seen.add(key)
        if len(topics) == limit:
            break
    return topics


def extract_syllabus_topics(chunks: list[Any], *, limit: int = 100) -> list[str]:
    """Extract headings from parser-produced location labels and normalized content."""
    topics: list[str] = []
    seen: set[str] = set()
    for chunk in chunks:
        location_label = getattr(chunk, "location_label", "")
        content = getattr(chunk, "content", str(chunk) if isinstance(chunk, str) else "")
        candidates = [part.strip() for part in location_label.split(" > ") if part.strip()]
        for line in content.splitlines():
            match = re.match(r"^\s*(?:#{1,6}|[-*•]|\d+[.)])\s+(.+?)\s*$", line)
            if match:
                candidates.append(match.group(1).strip())
        for candidate in candidates:
            key = candidate.casefold()
            if 2 <= len(candidate) <= 300 and key not in seen:
                topics.append(candidate)
                seen.add(key)
            if len(topics) == limit:
                return topics
    return topics


def _catalog_id(code: str) -> uuid.UUID:
    return uuid.uuid5(CATALOG_NAMESPACE, f"{INSTITUTION}:{code}")


def _offering_id(code: str, academic_year: str, semester: int) -> uuid.UUID:
    return uuid.uuid5(OFFERING_NAMESPACE, f"{INSTITUTION}:{code}:{academic_year}:{semester}")


def _provider_snapshot_id(
    provider: str,
    academic_year: str,
    code: str,
    provider_version: str,
    source_url: str,
    fetched_at: datetime,
    payload_sha256: str,
) -> uuid.UUID:
    identity = ":".join(
        [
            provider,
            academic_year,
            code,
            provider_version,
            source_url,
            fetched_at.isoformat(),
            payload_sha256,
        ]
    )
    return uuid.uuid5(PROVIDER_SNAPSHOT_NAMESPACE, identity)


def _enrollment_id(user_id: uuid.UUID, offering_id: uuid.UUID) -> uuid.UUID:
    return uuid.uuid5(ENROLLMENT_NAMESPACE, f"{user_id}:{offering_id}")


def _topic_id(enrollment_id: uuid.UUID, position: int, title: str) -> uuid.UUID:
    return uuid.uuid5(
        TOPIC_NAMESPACE, f"{enrollment_id}:{TOPIC_EXTRACTION_RULE}:{position}:{title}"
    )


def _manual_topic_id(enrollment_id: uuid.UUID, position: int, title: str) -> uuid.UUID:
    return uuid.uuid5(TOPIC_NAMESPACE, f"{enrollment_id}:{MANUAL_REVIEW_RULE}:{position}:{title}")


def _insert(db: AsyncSession, model):
    dialect = db.bind.dialect.name
    if dialect == "postgresql":
        return postgresql_insert(model)
    if dialect == "sqlite":
        return sqlite_insert(model)
    raise RuntimeError(f"curriculum upserts do not support {dialect}")


async def _detail_snapshot(
    client: NUSModsClient, academic_year: str, code: str
) -> ProviderSnapshot | None:
    if hasattr(client, "module_snapshot"):
        return await client.module_snapshot(academic_year, code)
    detail = await client.module(academic_year, code)
    if detail is None:
        return None
    return ProviderSnapshot(
        payload=detail,
        provider_version="v2",
        source_url=f"https://api.nusmods.com/v2/{academic_year}/modules/{code}.json",
        fetched_at=datetime.now(UTC),
        payload_sha256=canonical_payload_sha256(detail),
    )


async def create_import_preview(
    *,
    user: User,
    academic_year: str,
    semester: int | None,
    share_url: str | None,
    manual_codes: list[str],
    db: AsyncSession,
    client: NUSModsClient,
) -> ModuleImportPreview:
    if share_url:
        parsed = parse_share_url(share_url)
        semester = parsed.semester
        requested = list(parsed.modules)
        import_method = "share_url"
    else:
        requested = [ShareModule(code=code) for code in manual_codes]
        import_method = "manual_codes"
    if semester is None or not requested or len(requested) > MAX_MODULES:
        raise WikiBaseError(400, "invalid_import", "A semester and 1 to 30 modules are required")

    existing_rows = list(
        (
            await db.execute(
                select(CatalogModule.code, ModuleEnrollment.archived)
                .join(SemesterOffering, SemesterOffering.catalog_module_id == CatalogModule.id)
                .join(ModuleEnrollment, ModuleEnrollment.offering_id == SemesterOffering.id)
                .where(
                    ModuleEnrollment.user_id == user.id,
                    SemesterOffering.academic_year == academic_year,
                    SemesterOffering.semester == semester,
                )
            )
        ).all()
    )
    existing = {code: archived for code, archived in existing_rows}
    requested_codes = {item.code for item in requested}
    preview = ModuleImportPreview(
        user_id=user.id,
        import_method=import_method,
        academic_year=academic_year,
        semester=semester,
        expires_at=datetime.now(UTC) + timedelta(minutes=30),
    )
    added: list[str] = []
    unchanged: list[str] = []
    ambiguous: list[str] = []
    for position, requested_item in enumerate(requested):
        snapshot = await _detail_snapshot(client, academic_year, requested_item.code)
        detail = None if snapshot is None else snapshot.payload
        semester_data = (
            next((item for item in detail["semesterData"] if item["semester"] == semester), None)
            if detail
            else None
        )
        available = semester_data is not None
        if snapshot is None:
            disposition = "not_found"
            ambiguous.append(requested_item.code)
        elif not available:
            disposition = "unavailable"
            ambiguous.append(requested_item.code)
        elif requested_item.code in existing and existing[requested_item.code]:
            disposition = "restore"
            added.append(requested_item.code)
        elif requested_item.code in existing:
            disposition = "already_enrolled"
            unchanged.append(requested_item.code)
        else:
            disposition = "import"
            added.append(requested_item.code)
        preview.items.append(
            ModuleImportItem(
                position=position,
                code=requested_item.code,
                title=detail["title"] if detail else "",
                available=available,
                disposition=disposition,
                lesson_config=requested_item.lesson_config,
                detail_snapshot=detail,
                provider_version=snapshot.provider_version if snapshot else None,
                source_url=snapshot.source_url if snapshot else None,
                fetched_at=snapshot.fetched_at if snapshot else None,
                payload_sha256=snapshot.payload_sha256 if snapshot else None,
            )
        )
    preview.reconciliation = {
        "added": added,
        "unchanged": unchanged,
        "removed": sorted(
            code
            for code, archived in existing.items()
            if not archived and code not in requested_codes
        ),
        "ambiguous": ambiguous,
    }
    db.add(preview)
    await db.commit()
    await db.refresh(preview)
    return preview


async def commit_import_preview(
    *,
    preview_id: uuid.UUID,
    selected_codes: list[str],
    archive_codes: list[str] | None = None,
    user: User,
    db: AsyncSession,
    client: NUSModsClient | None = None,
) -> ImportCommitResponse:
    del client
    archive_codes = archive_codes or []
    request_snapshot = {"selected_codes": selected_codes, "archive_codes": archive_codes}
    preview = (
        await db.execute(
            select(ModuleImportPreview)
            .where(
                ModuleImportPreview.id == preview_id,
                ModuleImportPreview.user_id == user.id,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if not preview:
        raise NotFoundError("Import preview not found")
    if preview.committed_at is not None:
        if preview.commit_request != request_snapshot:
            raise WikiBaseError(
                409, "preview_already_committed", "Preview was committed with other decisions"
            )
        return ImportCommitResponse.model_validate(preview.commit_result)
    if preview.expires_at < datetime.now(UTC):
        raise WikiBaseError(409, "preview_expired", "Import preview has expired")

    items = {item.code: item for item in preview.items}
    if (
        len(selected_codes) != len(set(selected_codes))
        or len(archive_codes) != len(set(archive_codes))
        or len(selected_codes) + len(archive_codes) > MAX_MODULES
    ):
        raise WikiBaseError(
            400, "invalid_selection", "Module decisions must be unique and limited to 30"
        )
    invalid_selected = [
        code
        for code in selected_codes
        if code not in items
        or items[code].disposition not in {"import", "already_enrolled", "restore"}
    ]
    removable = set(preview.reconciliation["removed"])
    invalid_archives = [code for code in archive_codes if code not in removable]
    if invalid_selected or invalid_archives or set(selected_codes) & set(archive_codes):
        raise WikiBaseError(
            400,
            "invalid_selection",
            "Selected modules are not importable decisions in this preview",
        )
    for code in selected_codes:
        item = items[code]
        if (
            not item.detail_snapshot
            or not all(
                [item.provider_version, item.source_url, item.fetched_at, item.payload_sha256]
            )
            or canonical_payload_sha256(item.detail_snapshot) != item.payload_sha256
        ):
            raise WikiBaseError(
                409,
                "invalid_preview_snapshot",
                "Preview detail snapshot failed integrity verification",
            )

    enrollment_ids = {
        code: _enrollment_id(user.id, _offering_id(code, preview.academic_year, preview.semester))
        for code in selected_codes
    }
    if db.bind.dialect.name == "postgresql":
        lock_identities = sorted(
            (INSTITUTION, code) for code in set(selected_codes) | set(archive_codes)
        )
        for lock_identity in lock_identities:
            lock_key = int.from_bytes(
                hashlib.sha256("\x1f".join(lock_identity).encode()).digest()[:8],
                byteorder="big",
                signed=True,
            )
            await db.execute(text("SELECT pg_advisory_xact_lock(:key)"), {"key": lock_key})

    # Locks are global-order; response and processing remain selected request order, then archives.
    results: list[ImportCommitResponseItem] = []
    for code in selected_codes:
        item = items[code]
        detail = item.detail_snapshot
        catalog_id = _catalog_id(code)
        offering_id = _offering_id(code, preview.academic_year, preview.semester)
        enrollment_id = enrollment_ids[code]
        provider_snapshot_id = _provider_snapshot_id(
            preview.provider,
            preview.academic_year,
            code,
            item.provider_version,
            item.source_url,
            item.fetched_at,
            item.payload_sha256,
        )
        catalog_values = {
            "id": catalog_id,
            "institution": INSTITUTION,
            "canonical_code": code,
            "code": code,
            "title": detail["title"],
            "description": detail["description"],
            "metadata_json": {},
        }
        catalog_insert = _insert(db, CatalogModule).values(**catalog_values)
        await db.execute(
            catalog_insert.on_conflict_do_nothing(
                index_elements=[CatalogModule.institution, CatalogModule.canonical_code]
            )
        )
        snapshot_insert = _insert(db, ProviderModuleSnapshot).values(
            id=provider_snapshot_id,
            provider=preview.provider,
            academic_year=preview.academic_year,
            module_code=code,
            provider_version=item.provider_version,
            source_url=item.source_url,
            fetched_at=item.fetched_at,
            payload_sha256=item.payload_sha256,
            payload=detail,
        )
        await db.execute(
            snapshot_insert.on_conflict_do_nothing(index_elements=[ProviderModuleSnapshot.id])
        )
        offering_insert = _insert(db, SemesterOffering).values(
            id=offering_id,
            catalog_module_id=catalog_id,
            provider_snapshot_id=provider_snapshot_id,
            academic_year=preview.academic_year,
            semester=preview.semester,
            available=True,
            metadata_json={},
        )
        await db.execute(
            offering_insert.on_conflict_do_update(
                index_elements=[
                    SemesterOffering.catalog_module_id,
                    SemesterOffering.academic_year,
                    SemesterOffering.semester,
                ],
                set_={"available": True},
            )
        )
        offering = await db.scalar(
            select(SemesterOffering).where(SemesterOffering.id == offering_id)
        )
        seeded_detail = offering.provider_snapshot.payload
        enrollment_insert = _insert(db, ModuleEnrollment).values(
            id=enrollment_id,
            user_id=user.id,
            offering_id=offering_id,
            provenance="nusmods",
            import_method=preview.import_method,
            topic_state="provisional",
            evidence_warning=PROVISIONAL_WARNING,
            lesson_config=item.lesson_config,
            archived=False,
        )
        inserted_id = (
            await db.execute(
                enrollment_insert.on_conflict_do_nothing(
                    index_elements=[ModuleEnrollment.user_id, ModuleEnrollment.offering_id]
                ).returning(ModuleEnrollment.id)
            )
        ).scalar_one_or_none()
        created = inserted_id is not None
        existing = None
        was_archived = False
        if not created:
            existing = (
                await db.execute(
                    select(ModuleEnrollment)
                    .where(
                        ModuleEnrollment.user_id == user.id,
                        ModuleEnrollment.offering_id == offering_id,
                    )
                    .with_for_update(of=ModuleEnrollment)
                )
            ).scalar_one()
            was_archived = existing.archived
            existing.archived = False
            existing.lesson_config = item.lesson_config
        if created:
            normalized_source = _normalize_source(seeded_detail["description"])
            for position, title in enumerate(extract_provisional_topics(normalized_source)):
                topic_insert = _insert(db, CurriculumTopic).values(
                    id=_topic_id(enrollment_id, position, title),
                    enrollment_id=enrollment_id,
                    position=position,
                    title=title,
                    archived=False,
                    state="provisional",
                    provenance="catalog_description",
                    extraction_rule=TOPIC_EXTRACTION_RULE,
                    extraction_rule_hash=RULE_HASH,
                    source_text=normalized_source,
                    source_sha256=_sha256(normalized_source),
                )
                await db.execute(
                    topic_insert.on_conflict_do_nothing(index_elements=[CurriculumTopic.id])
                )
        status = "imported" if created else "restored" if was_archived else "already_enrolled"
        results.append(
            ImportCommitResponseItem(
                code=code,
                status=status,
                enrollment_id=enrollment_id,
                warning=PROVISIONAL_WARNING
                if created
                else existing.evidence_warning
                if existing
                else None,
            )
        )

    for code in archive_codes:
        enrollment = (
            await db.execute(
                select(ModuleEnrollment)
                .join(SemesterOffering, ModuleEnrollment.offering_id == SemesterOffering.id)
                .join(CatalogModule, SemesterOffering.catalog_module_id == CatalogModule.id)
                .where(
                    ModuleEnrollment.user_id == user.id,
                    SemesterOffering.academic_year == preview.academic_year,
                    SemesterOffering.semester == preview.semester,
                    CatalogModule.code == code,
                )
                .with_for_update(of=ModuleEnrollment)
            )
        ).scalar_one()
        enrollment.archived = True
        await db.execute(
            update(UserPreference)
            .where(
                UserPreference.user_id == user.id,
                UserPreference.default_enrollment_id == enrollment.id,
            )
            .values(default_enrollment_id=None)
        )
        results.append(
            ImportCommitResponseItem(code=code, status="archived", enrollment_id=enrollment.id)
        )

    response = ImportCommitResponse(preview_id=preview.id, items=results)
    preview.commit_request = request_snapshot
    preview.commit_result = response.model_dump(mode="json")
    preview.committed_at = datetime.now(UTC)
    await db.commit()
    return response


def _topic_snapshot(topic: CurriculumTopic, evidence_warning: str | None) -> dict:
    return {
        "id": str(topic.id),
        "position": topic.position,
        "title": topic.title,
        "archived": topic.archived,
        "state": topic.state,
        "evidence_warning": evidence_warning,
        "provenance": topic.provenance,
        "extraction_rule": topic.extraction_rule,
        "extraction_rule_hash": topic.extraction_rule_hash,
        "source_text": topic.source_text,
        "source_sha256": topic.source_sha256,
    }


def _topics_snapshot_sha256(snapshot: list[dict]) -> str:
    return canonical_payload_sha256(snapshot)


async def save_reviewed_topics(
    enrollment: ModuleEnrollment,
    payload: TopicListUpdate,
    db: AsyncSession,
    *,
    record_revision: bool = True,
    provenance: str = "user_review",
) -> list[CurriculumTopic]:
    existing = list(
        (
            await db.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment.id)
                .order_by(CurriculumTopic.position)
                .with_for_update()
            )
        ).scalars()
    )
    before = [_topic_snapshot(topic, enrollment.evidence_warning) for topic in existing]
    by_id = {topic.id: topic for topic in existing}
    supplied_ids = {item.id for item in payload.topics if item.id}
    if not supplied_ids.issubset(by_id):
        raise WikiBaseError(400, "invalid_topic_id", "Topic does not belong to this enrollment")

    temporary_start = max((topic.position for topic in existing), default=-1) + len(existing) + 101
    for offset, topic in enumerate(existing, start=temporary_start):
        topic.position = offset
    await db.flush()
    reviewed: list[CurriculumTopic] = []
    kept_ids: set[uuid.UUID] = set()
    mapping: dict[str, list] = {"retained": [], "created": [], "archived": [], "superseded": []}
    for position, item in enumerate(payload.topics):
        topic_id = item.id or _manual_topic_id(enrollment.id, position, item.title)
        if topic_id in kept_ids:
            raise WikiBaseError(400, "duplicate_topic_id", "Topic resolves to a duplicate ID")
        topic = by_id.get(topic_id)
        if topic is None:
            topic = CurriculumTopic(
                id=topic_id,
                enrollment_id=enrollment.id,
                title=item.title,
                position=position,
                archived=item.archived,
                state="canonical",
                provenance=provenance,
                extraction_rule=MANUAL_REVIEW_RULE,
                extraction_rule_hash=MANUAL_RULE_HASH,
                source_text=item.title,
                source_sha256=_sha256(item.title),
            )
            db.add(topic)
            by_id[topic_id] = topic
            mapping["created"].append(str(topic_id))
        else:
            mapping["retained"].append(str(topic_id))
            if topic.title != item.title:
                mapping["superseded"].append(str(topic_id))
        rule = SYLLABUS_REFINEMENT_RULE if provenance == "syllabus" else MANUAL_REVIEW_RULE
        rule_hash = SYLLABUS_RULE_HASH if provenance == "syllabus" else MANUAL_RULE_HASH
        topic.title = item.title
        topic.archived = item.archived
        topic.position = position
        topic.state = "canonical"
        topic.provenance = provenance
        topic.extraction_rule = rule
        topic.extraction_rule_hash = rule_hash
        topic.source_text = item.title
        topic.source_sha256 = _sha256(item.title)
        kept_ids.add(topic.id)
        reviewed.append(topic)
    for omitted_position, topic in enumerate(
        (topic for topic in existing if topic.id not in kept_ids), start=len(reviewed)
    ):
        topic.archived = True
        topic.position = omitted_position
        mapping["archived"].append(str(topic.id))
        mapping["superseded"].append(str(topic.id))
        reviewed.append(topic)
    active_ids = {str(topic.id) for topic in reviewed if not topic.archived}
    archived_ids = {str(topic.id) for topic in reviewed if topic.archived}
    created_ids = set(mapping["created"])
    mapping = {
        "accepted": sorted(active_ids),
        "archived": sorted(archived_ids),
        "created": sorted(created_ids),
        "retained": sorted(active_ids - created_ids),
        "superseded": sorted(
            set(mapping["superseded"]) | ({topic["id"] for topic in before} - active_ids)
        ),
    }
    enrollment.topic_state = "canonical"
    enrollment.evidence_warning = None
    await db.flush()
    if record_revision:
        after = [_topic_snapshot(topic, enrollment.evidence_warning) for topic in reviewed]
        db.add(
            TopicRevision(
                enrollment_id=enrollment.id,
                user_id=enrollment.user_id,
                source_id=None,
                status="accepted",
                base_topics=before,
                proposed_topics=after,
                mapping=mapping,
                algorithm=MANUAL_REVIEW_RULE,
                reviewed_at=datetime.now(UTC),
            )
        )
        await db.flush()
    return reviewed


async def propose_syllabus_refinement(
    *, enrollment: ModuleEnrollment, source_id: uuid.UUID, user: User, db: AsyncSession
) -> TopicRevision:
    await db.execute(
        select(func.pg_advisory_xact_lock(func.hashtextextended(f"source:{source_id}", 0)))
    )
    enrollment = (
        await db.execute(
            select(ModuleEnrollment)
            .where(
                ModuleEnrollment.id == enrollment.id,
                ModuleEnrollment.user_id == user.id,
            )
            .with_for_update(of=ModuleEnrollment)
        )
    ).scalar_one_or_none()
    if enrollment is None:
        raise NotFoundError("Enrollment not found")
    source = (
        await db.execute(
            select(Source)
            .where(
                Source.id == source_id,
                Source.user_id == enrollment.user_id,
                Source.status == SourceStatus.READY,
                (Source.enrollment_id.is_(None) | (Source.enrollment_id == enrollment.id)),
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if source is None:
        raise NotFoundError("Ready source not found")
    try:
        chunks, chunk_snapshot, chunks_sha256, chunk_count = await _source_chunks_fingerprint(
            db, source.id
        )
    except ValueError as exc:
        raise WikiBaseError(422, "source_too_large", str(exc)) from exc
    current = list(
        (
            await db.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment.id)
                .order_by(CurriculumTopic.position)
            )
        ).scalars()
    )
    titles = extract_syllabus_topics(chunks)
    if not titles:
        raise WikiBaseError(
            422, "no_syllabus_topics", "No parser-derived syllabus headings were found"
        )
    current_by_title = {topic.title.casefold(): topic for topic in current}
    proposed = [
        {
            "id": str(current_by_title[title.casefold()].id)
            if title.casefold() in current_by_title
            else None,
            "position": position,
            "title": title,
            "archived": False,
            "state": "canonical",
            "evidence_warning": None,
            "provenance": "syllabus",
            "extraction_rule": SYLLABUS_REFINEMENT_RULE,
            "extraction_rule_hash": SYLLABUS_RULE_HASH,
            "source_text": title,
            "source_sha256": _sha256(title),
        }
        for position, title in enumerate(titles)
    ]
    revision = TopicRevision(
        enrollment_id=enrollment.id,
        user_id=user.id,
        source_id=source.id,
        status="pending",
        base_topics=[_topic_snapshot(topic, enrollment.evidence_warning) for topic in current],
        proposed_topics=proposed,
        mapping={
            "base_snapshot_sha256": _topics_snapshot_sha256(
                [_topic_snapshot(topic, enrollment.evidence_warning) for topic in current]
            ),
            "source_chunks": chunk_snapshot,
            "source_chunks_sha256": chunks_sha256,
            "source_chunk_count": chunk_count,
        },
        algorithm=SYLLABUS_REFINEMENT_RULE,
    )
    db.add(revision)
    await db.flush()
    return revision


async def review_topic_revision(
    *,
    enrollment: ModuleEnrollment,
    revision_id: uuid.UUID,
    decision: str,
    user: User,
    db: AsyncSession,
) -> TopicRevision:
    revision_row = (
        await db.execute(
            select(TopicRevision.source_id).where(
                TopicRevision.id == revision_id,
                TopicRevision.enrollment_id == enrollment.id,
                TopicRevision.user_id == user.id,
            )
        )
    ).first()
    if revision_row is None:
        raise NotFoundError("Topic revision not found")
    source_id = revision_row.source_id
    if decision == "accept" and source_id is not None:
        await db.execute(
            select(func.pg_advisory_xact_lock(func.hashtextextended(f"source:{source_id}", 0)))
        )
    enrollment = (
        await db.execute(
            select(ModuleEnrollment)
            .where(
                ModuleEnrollment.id == enrollment.id,
                ModuleEnrollment.user_id == user.id,
            )
            .with_for_update(of=ModuleEnrollment)
        )
    ).scalar_one_or_none()
    if enrollment is None:
        raise NotFoundError("Enrollment not found")
    current = list(
        (
            await db.execute(
                select(CurriculumTopic)
                .where(CurriculumTopic.enrollment_id == enrollment.id)
                .order_by(CurriculumTopic.position)
                .with_for_update()
            )
        ).scalars()
    )
    source = None
    chunk_snapshot: list[dict[str, Any]] = []
    chunks_sha256 = ""
    chunk_count = 0
    source_too_large = False
    if decision == "accept" and source_id is not None:
        source = (
            await db.execute(
                select(Source)
                .where(
                    Source.id == source_id,
                    Source.user_id == enrollment.user_id,
                    Source.status == SourceStatus.READY,
                    (Source.enrollment_id.is_(None) | (Source.enrollment_id == enrollment.id)),
                )
                .with_for_update()
            )
        ).scalar_one_or_none()
        if source is not None:
            try:
                _, chunk_snapshot, chunks_sha256, chunk_count = await _source_chunks_fingerprint(
                    db, source.id
                )
            except ValueError:
                source_too_large = True
    revision = (
        await db.execute(
            select(TopicRevision)
            .where(
                TopicRevision.id == revision_id,
                TopicRevision.enrollment_id == enrollment.id,
                TopicRevision.user_id == user.id,
            )
            .with_for_update()
        )
    ).scalar_one_or_none()
    if revision is None:
        raise NotFoundError("Topic revision not found")
    if revision.status != "pending":
        raise WikiBaseError(409, "revision_already_reviewed", "Topic revision was already reviewed")
    current_snapshot = [_topic_snapshot(topic, enrollment.evidence_warning) for topic in current]
    base_hash = revision.mapping.get("base_snapshot_sha256") or _topics_snapshot_sha256(
        revision.base_topics
    )
    if _topics_snapshot_sha256(current_snapshot) != base_hash:
        raise WikiBaseError(409, "revision_stale", "Topics changed after this revision was created")
    if decision == "accept":
        if (
            source is None
            or source_too_large
            or revision.source_id != source_id
            or revision.mapping.get("source_chunks") != chunk_snapshot
            or revision.mapping.get("source_chunks_sha256") != chunks_sha256
            or revision.mapping.get("source_chunk_count") != chunk_count
        ):
            raise WikiBaseError(
                409,
                "revision_stale",
                "The syllabus source changed after this revision was created",
            )
        topic_payload = TopicListUpdate.model_validate({"topics": revision.proposed_topics})
        topics = await save_reviewed_topics(
            enrollment, topic_payload, db, record_revision=False, provenance="syllabus"
        )
        revision.status = "accepted"
        base_ids = {topic["id"] for topic in revision.base_topics}
        active_ids = {str(topic.id) for topic in topics if not topic.archived}
        archived_ids = {str(topic.id) for topic in topics if topic.archived}
        revision.mapping = {
            **revision.mapping,
            "accepted_topics": sorted(active_ids),
            "archived_topics": sorted(archived_ids),
            "created_topics": sorted(active_ids - base_ids),
            "retained_topics": sorted(active_ids & base_ids),
            "superseded_topics": sorted(base_ids - active_ids),
        }
    else:
        revision.status = "rejected"
    revision.reviewed_at = datetime.now(UTC)
    await db.flush()
    return revision
