"""contractor team hiring + scheduled time

Revision ID: 0006
Revises: 0005
"""
from alembic import op
import sqlalchemy as sa


revision = '0006'
down_revision = '0005'
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.add_column('jobs', sa.Column('scheduled_for', sa.DateTime(timezone=True), nullable=True))
    op.add_column('jobs', sa.Column('time_slot', sa.String(length=12), nullable=True))
    op.add_column('jobs', sa.Column('kind', sa.String(length=10), server_default='single', nullable=False))
    op.add_column('work_items', sa.Column('headcount', sa.SmallInteger(), server_default='1', nullable=False))
    op.add_column('work_items', sa.Column('days', sa.SmallInteger(), server_default='1', nullable=False))
    op.add_column('work_items', sa.Column('daily_wage_paise', sa.BigInteger(), nullable=True))
    op.add_column('bids', sa.Column('work_item_id', sa.Uuid(), nullable=True))
    op.create_foreign_key('fk_bids_work_item', 'bids', 'work_items', ['work_item_id'], ['id'])
    op.add_column('assignments', sa.Column('work_item_id', sa.Uuid(), nullable=True))
    op.add_column('assignments', sa.Column('days_planned', sa.SmallInteger(), server_default='1', nullable=False))
    op.create_foreign_key('fk_assignments_work_item', 'assignments', 'work_items', ['work_item_id'], ['id'])
    # a team job has one assignment per hired worker -> job_id is no longer unique
    # (0005 already turned it into a partial unique index; narrow it to single-worker jobs)
    op.drop_index('uq_assignment_active_job', table_name='assignments')
    op.create_index('uq_assignment_active_job', 'assignments', ['job_id'], unique=True,
                    postgresql_where=sa.text('released_at IS NULL AND work_item_id IS NULL'))


def downgrade() -> None:
    op.drop_index('uq_assignment_active_job', table_name='assignments')
    op.create_index('uq_assignment_active_job', 'assignments', ['job_id'], unique=True,
                    postgresql_where=sa.text('released_at IS NULL'))
    op.drop_constraint('fk_assignments_work_item', 'assignments', type_='foreignkey')
    op.drop_column('assignments', 'days_planned')
    op.drop_column('assignments', 'work_item_id')
    op.drop_constraint('fk_bids_work_item', 'bids', type_='foreignkey')
    op.drop_column('bids', 'work_item_id')
    op.drop_column('work_items', 'daily_wage_paise')
    op.drop_column('work_items', 'days')
    op.drop_column('work_items', 'headcount')
    op.drop_column('jobs', 'kind')
    op.drop_column('jobs', 'time_slot')
    op.drop_column('jobs', 'scheduled_for')
