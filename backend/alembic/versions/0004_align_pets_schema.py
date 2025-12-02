from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0004_align_pets_schema"
down_revision = "0003_adjust_sitting_jobs_schema"
branch_labels = None
depends_on = None


def upgrade() -> None:
    conn = op.get_bind()
    op.drop_constraint("pets_owner_id_fkey", "pets", type_="foreignkey")

    op.alter_column(
        "pets",
        "owner_id",
        existing_type=postgresql.UUID(as_uuid=True),
        nullable=False,
    )
    op.create_foreign_key(
        "pets_owner_id_fkey",
        "pets",
        "users",
        ["owner_id"],
        ["id"],
        ondelete="CASCADE",
    )

    op.alter_column(
        "pets",
        "breed",
        existing_type=sa.String(length=64),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "health",
        existing_type=sa.Text(),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "profile_picture",
        existing_type=sa.String(length=255),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "name",
        existing_type=sa.String(length=128),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "type",
        existing_type=sa.String(length=64),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "gender",
        existing_type=sa.String(length=16),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "weight",
        existing_type=sa.Numeric(5, 2),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "date_of_birth",
        existing_type=sa.Date(),
        type_=postgresql.TIMESTAMP(timezone=True),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "created_at",
        existing_type=sa.DateTime(),
        type_=postgresql.TIMESTAMP(timezone=True),
        nullable=False,
        server_default=sa.text("now()"),
    )

    conn.execute(sa.text("DROP INDEX IF EXISTS idx_pets_date_of_birth"))
    op.create_index(
        "idx_pets_date_of_birth",
        "pets",
        ["date_of_birth"],
        unique=False,
        postgresql_using="btree",
    )


def downgrade() -> None:
    op.drop_index("idx_pets_date_of_birth", table_name="pets")
    op.drop_constraint("pets_owner_id_fkey", "pets", type_="foreignkey")

    op.alter_column(
        "pets",
        "created_at",
        existing_type=postgresql.TIMESTAMP(timezone=True),
        type_=sa.DateTime(),
        nullable=False,
    )
    op.alter_column(
        "pets",
        "date_of_birth",
        existing_type=postgresql.TIMESTAMP(timezone=True),
        type_=sa.Date(),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "weight",
        existing_type=sa.Numeric(5, 2),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "gender",
        existing_type=sa.String(length=16),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "type",
        existing_type=sa.String(length=64),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "name",
        existing_type=sa.String(length=128),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "profile_picture",
        existing_type=sa.String(length=255),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "health",
        existing_type=sa.Text(),
        nullable=True,
    )
    op.alter_column(
        "pets",
        "breed",
        existing_type=sa.String(length=64),
        nullable=True,
    )
    op.create_foreign_key(
        "pets_owner_id_fkey",
        "pets",
        "users",
        ["owner_id"],
        ["id"],
    )