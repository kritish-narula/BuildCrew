"""completion disagreement flow, released hires, auto-rating flag

Revision ID: 0005
Revises: 0004
"""
from alembic import op
import sqlalchemy as sa
from sqlalchemy.dialects import postgresql


revision = '0005'
down_revision = '0004'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('jobs', sa.Column('nudged_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('ratings', sa.Column('is_auto', sa.Boolean(), server_default='false', nullable=False))
    a = 'assignments'
    op.add_column(a, sa.Column('expected_arrival_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column(a, sa.Column('proof_photos', postgresql.ARRAY(sa.String(length=500)), server_default='{}', nullable=False))
    op.add_column(a, sa.Column('worker_done_note', sa.Text(), nullable=True))
    op.add_column(a, sa.Column('rework_count', sa.SmallInteger(), server_default='0', nullable=False))
    op.add_column(a, sa.Column('rework_open', sa.Boolean(), server_default='false', nullable=False))
    op.add_column(a, sa.Column('auto_confirmed', sa.Boolean(), server_default='false', nullable=False))
    op.add_column(a, sa.Column('released_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column(a, sa.Column('release_reason', sa.String(length=30), nullable=True))
    # a job may be hired again after a hire is released: uniqueness only for the ACTIVE hire
    op.drop_constraint('assignments_job_id_key', a, type_='unique')
    op.create_index('ix_assignments_job_id', a, ['job_id'], unique=False)
    op.create_index('uq_assignment_active_job', a, ['job_id'], unique=True, postgresql_where=sa.text('released_at IS NULL'))
    op.create_table(
        'assignment_events',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('assignment_id', sa.Uuid(), nullable=False),
        sa.Column('kind', sa.String(length=30), nullable=False),
        sa.Column('actor_role', sa.String(length=10), nullable=False),
        sa.Column('reasons', postgresql.ARRAY(sa.String(length=30)), server_default='{}', nullable=False),
        sa.Column('note', sa.Text(), nullable=True),
        sa.Column('photos', postgresql.ARRAY(sa.String(length=500)), server_default='{}', nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.ForeignKeyConstraint(['assignment_id'], ['assignments.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_assignment_events_assignment_id', 'assignment_events', ['assignment_id'], unique=False)


def downgrade() -> None:
    op.drop_index('ix_assignment_events_assignment_id', table_name='assignment_events')
    op.drop_table('assignment_events')
    a = 'assignments'
    op.drop_index('uq_assignment_active_job', table_name=a)
    op.drop_index('ix_assignments_job_id', table_name=a)
    op.create_unique_constraint('assignments_job_id_key', a, ['job_id'])
    for c in ('release_reason', 'released_at', 'auto_confirmed', 'rework_open', 'rework_count', 'worker_done_note',
              'proof_photos', 'expected_arrival_at'):
        op.drop_column(a, c)
    op.drop_column('ratings', 'is_auto')
    op.drop_column('jobs', 'nudged_at')
