import logging

from fastapi import FastAPI, Request
from fastapi.exceptions import RequestValidationError
from fastapi.middleware.cors import CORSMiddleware

from .config import get_settings
from .errors import AppError, app_error_handler, unhandled_handler, validation_handler
from .routers import admin, auth, core, customer, worker

logging.basicConfig(level=logging.INFO)
settings = get_settings()

# Refuse to boot in staging/prod with dev secrets — the most common real-world leak.
if not settings.is_dev:
    weak = [n for n, v in {"JWT_SECRET": settings.jwt_secret, "DATA_ENCRYPTION_KEY": settings.data_encryption_key}.items()
            if v.startswith(("dev-only", "xY3v0J6m"))]
    if weak:
        raise RuntimeError(f"Set strong production values for: {', '.join(weak)}")

app = FastAPI(title="BuildCrew API", version="0.1.0",
              docs_url="/docs" if settings.is_dev else None, redoc_url=None)

app.add_middleware(CORSMiddleware, allow_origins=[o.strip() for o in settings.cors_origins.split(",") if o.strip()],
                   allow_methods=["*"], allow_headers=["*"], allow_credentials=False)


@app.middleware("http")
async def security_headers(request: Request, call_next):
    response = await call_next(request)
    response.headers.update({
        "X-Content-Type-Options": "nosniff", "X-Frame-Options": "DENY", "Referrer-Policy": "no-referrer",
        "Strict-Transport-Security": "max-age=31536000; includeSubDomains",
        "Permissions-Policy": "geolocation=(), microphone=(), camera=()",
    })
    return response


app.add_exception_handler(AppError, app_error_handler)
app.add_exception_handler(RequestValidationError, validation_handler)
app.add_exception_handler(Exception, unhandled_handler)

for r in (auth.router, auth.me_router, core.meta, core.media, core.files, core.dev,
          worker.router, customer.router, admin.router):
    app.include_router(r)


@app.get("/health")
def health():
    return {"ok": True, "env": settings.env}
