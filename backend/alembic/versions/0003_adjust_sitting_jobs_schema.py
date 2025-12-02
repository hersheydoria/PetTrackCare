from __future__ import annotations

from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

revision = "0003_adjust_sitting_jobs_schema"
down_revision = "0003_add_sitting_jobs_notes"
branch_labels = None
depends_on = None


def upgrade() -> None:
    conn = op.get_bind()
    inspector = sa.inspect(conn)
    columns = {col["name"] for col in inspector.get_columns("sitting_jobs")}

    conn.execute(sa.text("ALTER TABLE sitting_jobs DROP CONSTRAINT IF EXISTS sitting_jobs_sitter_id_fkey"))
    conn.execute(sa.text("ALTER TABLE sitting_jobs DROP CONSTRAINT IF EXISTS sitting_jobs_owner_id_fkey"))
    if "notes" in columns:
        op.drop_column("sitting_jobs", "notes")
    if "owner_id" in columns:
        op.drop_column("sitting_jobs", "owner_id")
    if "updated_at" in columns:
        op.drop_column("sitting_jobs", "updated_at")

    # make sitter_id reference users table and enforce cascade delete
    op.create_foreign_key(
        "sitting_jobs_sitter_id_fkey",
        "sitting_jobs",
        "users",
        ["sitter_id"],
        ["id"],
        ondelete="CASCADE",
    )

    # ensure start_date is required and created_at has timezone
    op.alter_column(
        "sitting_jobs",
        "start_date",
        existing_type=sa.DATE(),
        nullable=False,
    )
    op.alter_column(
        "sitting_jobs",
        "created_at",
        existing_type=sa.DateTime(),
        type_=postgresql.TIMESTAMP(timezone=True),
        existing_nullable=True,
        nullable=True,
        server_default=sa.text("now()"),
    )

    # add status check constraint
    conn.execute(sa.text("ALTER TABLE sitting_jobs DROP CONSTRAINT IF EXISTS sitting_jobs_status_check"))
    op.create_check_constraint(
        "sitting_jobs_status_check",
        "sitting_jobs",
        "status = ANY (ARRAY['Pending','Active','Completed','Cancelled'])",
    )


def downgrade() -> None:
    conn = op.get_bind()
    conn.execute(sa.text("ALTER TABLE sitting_jobs DROP CONSTRAINT IF EXISTS sitting_jobs_status_check"))
    conn.execute(sa.text("ALTER TABLE sitting_jobs DROP CONSTRAINT IF EXISTS sitting_jobs_sitter_id_fkey"))

    op.add_column(
        "sitting_jobs",
        sa.Column("updated_at", sa.DateTime(), nullable=True),
    )
    op.add_column(
        "sitting_jobs",
        sa.Column(
            "owner_id",
            postgresql.UUID(as_uuid=True),
            sa.ForeignKey("users.id"),
            nullable=False,
        ),
    )
    op.add_column(
        "sitting_jobs",
        sa.Column("notes", sa.Text(), nullable=True),
    )

    op.create_foreign_key(
        "sitting_jobs_sitter_id_fkey",
        "sitting_jobs",
        "sitters",
        ["sitter_id"],
        ["id"],
        ondelete="CASCADE",
    )
    op.create_foreign_key(
        "sitting_jobs_owner_id_fkey",
        "sitting_jobs",
        "users",
        ["owner_id"],
        ["id"],
        ondelete="CASCADE",
    )

    op.alter_column(
        "sitting_jobs",
        "start_date",
        existing_type=sa.DATE(),
        nullable=True,
    )
    op.alter_column(
        "sitting_jobs",
        "created_at",
        existing_type=postgresql.TIMESTAMP(timezone=True),
        type_=sa.DateTime(),
        existing_nullable=True,
        nullable=True,
    )
