from fastapi import Request
from fastapi.exceptions import RequestValidationError
from fastapi.responses import JSONResponse

from .i18n import pick_lang, t


class AppError(Exception):
    """Raise with a message KEY, never with an English sentence. The handler localises it."""

    def __init__(self, key: str, status: int = 400, **params):
        self.key, self.status, self.params = key, status, params


def _lang(request: Request) -> str:
    return pick_lang(getattr(request.state, "lang", None), request.headers.get("accept-language"))


async def app_error_handler(request: Request, exc: AppError):
    return JSONResponse(status_code=exc.status, content={
        "error": {"code": exc.key, "message": t(exc.key, _lang(request), **exc.params)}})


async def validation_handler(request: Request, exc: RequestValidationError):
    # Field paths are for developers; the message is localised for the human.
    fields = [".".join(str(p) for p in e["loc"][1:]) for e in exc.errors()]
    return JSONResponse(status_code=422, content={
        "error": {"code": "err.validation", "message": t("err.validation", _lang(request)),
                  "fields": fields}})


async def unhandled_handler(request: Request, exc: Exception):
    # Never leak stack traces / SQL to clients.
    import logging
    logging.getLogger("app").exception("unhandled error")
    return JSONResponse(status_code=500, content={
        "error": {"code": "err.internal", "message": t("err.internal", _lang(request))}})
