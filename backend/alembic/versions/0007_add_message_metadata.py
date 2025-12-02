from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0007_add_message_metadata"
down_revision = "0006_add_notification_comment_fk"
branch_labels = None
depends_on = None

def upgrade() -> None:
    op.add_column(
        "messages",
        sa.Column(
            "metadata",
            sa.dialects.postgresql.JSON,
            nullable=True,
            server_default=sa.text("'{}'::json"),
        ),
    )

def downgrade() -> None:
    op.drop_column("messages", "metadata")
