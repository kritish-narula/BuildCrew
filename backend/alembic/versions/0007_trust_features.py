"""start-work code, share trip, police verification, warranty re-fix, same-day pay, direct requests

Revision ID: 0007
Revises: 0006
"""
from alembic import op
import sqlalchemy as sa


revision = '0007'
down_revision = '0006'
branch_labels = None
depends_on = None


def upgrade() -> None:
    # worker profile: police verification + re-fix record
    op.add_column('worker_profiles', sa.Column('police_status', sa.String(length=10), server_default='none', nullable=False))
    op.add_column('worker_profiles', sa.Column('police_requested_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('worker_profiles', sa.Column('police_decided_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('worker_profiles', sa.Column('police_note', sa.String(length=300), nullable=True))
    op.add_column('worker_profiles', sa.Column('refix_count', sa.Integer(), server_default='0', nullable=False))
    # jobs: exclusive "hire again" offer
    op.add_column('jobs', sa.Column('direct_worker_id', sa.Uuid(), nullable=True))
    op.add_column('jobs', sa.Column('direct_until', sa.DateTime(timezone=True), nullable=True))
    op.add_column('jobs', sa.Column('direct_declined', sa.Boolean(), server_default='false', nullable=False))
    op.create_foreign_key('fk_jobs_direct_worker', 'jobs', 'users', ['direct_worker_id'], ['id'])
    # assignments: start code + warranty re-fix link
    op.add_column('assignments', sa.Column('start_code_nonce', sa.String(length=32), nullable=True))
    op.add_column('assignments', sa.Column('start_code_attempts', sa.SmallInteger(), server_default='0', nullable=False))
    op.add_column('assignments', sa.Column('start_code_attempts_day', sa.String(length=10), nullable=True))
    op.add_column('assignments', sa.Column('start_code_locked_until', sa.DateTime(timezone=True), nullable=True))
    op.add_column('assignments', sa.Column('kind', sa.String(length=10), server_default='job', nullable=False))
    op.add_column('assignments', sa.Column('parent_assignment_id', sa.Uuid(), nullable=True))
    op.add_column('assignments', sa.Column('refix_reason', sa.Text(), nullable=True))
    op.create_foreign_key('fk_assignments_parent', 'assignments', 'assignments', ['parent_assignment_id'], ['id'])
    op.add_column('attendance', sa.Column('code_status', sa.String(length=12), server_default='not_required', nullable=False))
    # payouts: same-day pay
    op.add_column('payouts', sa.Column('source', sa.String(length=10), server_default='withdraw', nullable=False))
    op.add_column('payouts', sa.Column('assignment_id', sa.Uuid(), nullable=True))
    op.add_column('payouts', sa.Column('paid_at', sa.DateTime(timezone=True), nullable=True))
    op.add_column('payouts', sa.Column('notified_at', sa.DateTime(timezone=True), nullable=True))
    op.create_foreign_key('fk_payouts_assignment', 'payouts', 'assignments', ['assignment_id'], ['id'])
    # share-trip links
    op.create_table(
        'trip_shares',
        sa.Column('id', sa.Uuid(), nullable=False),
        sa.Column('assignment_id', sa.Uuid(), nullable=False),
        sa.Column('token', sa.String(length=64), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('expires_at', sa.DateTime(timezone=True), nullable=False),
        sa.ForeignKeyConstraint(['assignment_id'], ['assignments.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('id'),
    )
    op.create_index('ix_trip_shares_assignment_id', 'trip_shares', ['assignment_id'])
    op.create_index('ix_trip_shares_token', 'trip_shares', ['token'], unique=True)


def downgrade() -> None:
    op.drop_index('ix_trip_shares_token', table_name='trip_shares')
    op.drop_index('ix_trip_shares_assignment_id', table_name='trip_shares')
    op.drop_table('trip_shares')
    op.drop_constraint('fk_payouts_assignment', 'payouts', type_='foreignkey')
    for c in ('notified_at', 'paid_at', 'assignment_id', 'source'):
        op.drop_column('payouts', c)
    op.drop_column('attendance', 'code_status')
    op.drop_constraint('fk_assignments_parent', 'assignments', type_='foreignkey')
    for c in ('refix_reason', 'parent_assignment_id', 'kind', 'start_code_locked_until', 'start_code_attempts_day',
              'start_code_attempts', 'start_code_nonce'):
        op.drop_column('assignments', c)
    op.drop_constraint('fk_jobs_direct_worker', 'jobs', type_='foreignkey')
    for c in ('direct_declined', 'direct_until', 'direct_worker_id'):
        op.drop_column('jobs', c)
    for c in ('refix_count', 'police_note', 'police_decided_at', 'police_requested_at', 'police_status'):
        op.drop_column('worker_profiles', c)
