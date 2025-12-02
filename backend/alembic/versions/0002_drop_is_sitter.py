from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0002_drop_is_sitter"
down_revision = "0002_behavior_logs_updated_at"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_column("users", "is_sitter")


def downgrade() -> None:
    op.add_column(
        "users",
        sa.Column("is_sitter", sa.Boolean(), nullable=False, server_default=sa.text("false")),
    )
