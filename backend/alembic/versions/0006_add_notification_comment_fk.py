from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0006_add_notification_comment_fk"
down_revision = "0005_remove_device_mac_from_pets"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column(
        "notifications",
        sa.Column("comment_id", sa.dialects.postgresql.UUID(as_uuid=True), nullable=True),
    )
    op.create_foreign_key(
        "notifications_comment_id_fkey",
        "notifications",
        "comments",
        ["comment_id"],
        ["id"],
    )


def downgrade() -> None:
    op.drop_constraint("notifications_comment_id_fkey", "notifications", type_="foreignkey")
    op.drop_column("notifications", "comment_id")