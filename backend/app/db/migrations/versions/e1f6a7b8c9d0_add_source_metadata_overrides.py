"""add source metadata overrides

Revision ID: e1f6a7b8c9d0
Revises: d9e5f6a7b8c9
Create Date: 2026-07-21 00:00:00.000000
"""

from collections.abc import Sequence

import sqlalchemy as sa
from alembic import op
from sqlalchemy.dialects import postgresql

revision: str = "e1f6a7b8c9d0"
down_revision: str | Sequence[str] | None = "d9e5f6a7b8c9"
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column(
        "sources",
        sa.Column(
            "metadata_overrides",
            postgresql.ARRAY(sa.String(length=32)),
            server_default=sa.text("'{}'::character varying[]"),
            nullable=False,
        ),
    )

    # Source changes were not recorded before the Milestone 3 audit table existed,
    # so preserve every metadata field on external sources without a creation audit.
    # For newer sources, preserve fields changed by a historical update. Those updates
    # did not identify their actor, so this intentionally favors retaining user edits.
    op.execute(
        """
        UPDATE sources AS source
        SET metadata_overrides = CASE
            WHEN NOT EXISTS (
                SELECT 1
                FROM source_changes AS source_change
                WHERE source_change.source_id = source.id
                  AND source_change.change_type = 'source_created'
            ) THEN ARRAY[
                'citation_label',
                'course_context',
                'project_context',
                'topic_tags'
            ]::character varying[]
            ELSE ARRAY(
                SELECT metadata_field.field_name
                FROM unnest(
                    ARRAY[
                        'citation_label',
                        'topic_tags',
                        'course_context',
                        'project_context'
                    ]::character varying[]
                ) AS metadata_field(field_name)
                WHERE EXISTS (
                    SELECT 1
                    FROM source_changes AS source_change
                    WHERE source_change.source_id = source.id
                      AND source_change.change_type IN (
                          'source_updated',
                          'source_metadata_updated'
                      )
                      AND source_change.before_snapshot -> metadata_field.field_name
                          IS DISTINCT FROM
                          source_change.after_snapshot -> metadata_field.field_name
                )
                ORDER BY metadata_field.field_name
            )
        END
        WHERE source.external_id IS NOT NULL
        """
    )


def downgrade() -> None:
    op.drop_column("sources", "metadata_overrides")
