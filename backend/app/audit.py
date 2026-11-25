import uuid

from sqlalchemy.orm import Session

from .models import AuditLog


def audit(db: Session, *, actor_id: uuid.UUID | None, action: str, entity: str, entity_id,
          **meta) -> AuditLog:
    """Append-only audit row. Added to the caller's transaction so the state change and its
    audit record commit (or roll back) together — there is never a change without a trail."""
    row = AuditLog(actor_id=actor_id, action=action, entity=entity, entity_id=str(entity_id),
                   meta={k: (str(v) if isinstance(v, uuid.UUID) else v) for k, v in meta.items()})
    db.add(row)
    return row
