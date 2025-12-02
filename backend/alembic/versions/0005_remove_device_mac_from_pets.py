from __future__ import annotations

from alembic import op
import sqlalchemy as sa


revision = "0005_remove_device_mac_from_pets"
down_revision = "0004_align_pets_schema"
branch_labels = None
depends_on = None


def upgrade() -> None:
    conn = op.get_bind()
    inspector = sa.inspect(conn)
    columns = {col["name"] for col in inspector.get_columns("pets")}
    conn.execute(sa.text("DROP INDEX IF EXISTS ix_pets_device_mac"))
    if "device_mac" in columns:
        op.drop_column("pets", "device_mac")


def downgrade() -> None:
    op.add_column(
        "pets",
        sa.Column("device_mac", sa.String(length=64), nullable=True),
    )
    conn = op.get_bind()
    conn.execute(sa.text("DROP INDEX IF EXISTS ix_pets_device_mac"))
    op.create_index("ix_pets_device_mac", "pets", ["device_mac"], unique=False)
