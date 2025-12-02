from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0003_add_sitting_jobs_notes"
down_revision = "0002_drop_is_sitter"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "sitting_jobs",
        sa.Column("notes", sa.Text(), nullable=True),
    )


def downgrade() -> None:
    op.drop_column("sitting_jobs", "notes")
