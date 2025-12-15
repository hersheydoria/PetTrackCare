from __future__ import annotations

from alembic import op
import sqlalchemy as sa

revision = "0008_remove_location_firebase_entry"
down_revision = "0007_add_message_metadata"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.drop_index("ix_location_history_firebase_entry_id", table_name="location_history")
    op.drop_column("location_history", "firebase_entry_id")


def downgrade() -> None:
    op.add_column(
        "location_history",
        sa.Column("firebase_entry_id", sa.String(length=255), nullable=True),
    )
    op.create_index(
        "ix_location_history_firebase_entry_id",
        "location_history",
        ["firebase_entry_id"],
    )
