"""Public, unauthenticated endpoints. Only the share-trip link lives here: the token is the credential."""
import html

from fastapi import APIRouter, Depends, Request
from fastapi.responses import HTMLResponse
from sqlalchemy.orm import Session

from ..db import get_db
from ..domain import trust
from ..errors import AppError
from ..security import client_ip, rate_limit

router = APIRouter(tags=["public"])


@router.get("/public/trip/{token}")
def trip(token: str, request: Request, db: Session = Depends(get_db)):
    """What a family member sees: worker name, photo, trade, rating, police-verified badge, live distance + ETA.
    410 once the worker has arrived (or after 6 h / when the hire ends). Never the address, phone or customer."""
    rate_limit(f"trip:{client_ip(request)}", 120, 60)
    if len(token) > 64:
        raise AppError("err.not_found", 404)
    return trust.public_trip(db, token)


@router.get("/t/{token}", response_class=HTMLResponse)
def trip_page(token: str, request: Request, db: Session = Depends(get_db)):
    """The page behind https://buildcrew.app/t/<token> (auto-refreshes every 20 s)."""
    rate_limit(f"trip:{client_ip(request)}", 120, 60)
    try:
        d = trust.public_trip(db, token[:64])
    except AppError:
        return HTMLResponse("<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width'>"
                            "<body style='font-family:sans-serif;padding:24px'><h2>This trip link has ended</h2>"
                            "<p>The worker has arrived or the link expired.</p></body>", status_code=410,
                            headers={"X-Robots-Tag": "noindex", "Referrer-Policy": "no-referrer"})
    e = html.escape
    shield = " &#128737; Police verified" if d["police_verified"] else ""
    eta = f"{d['eta_min']} min" if d["eta_min"] is not None else "on the way"
    dist = f"{d['distance_km']} km away" if d["distance_km"] is not None else ""
    photo = f"<img src='{e(d['photo'])}' width=96 height=96 style='border-radius:48px'>" if d["photo"] else ""
    page = (f"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>"
            f"<meta http-equiv=refresh content=20><meta name=robots content=noindex>"
            f"<body style='font-family:sans-serif;padding:24px;max-width:480px;margin:auto'>"
            f"{photo}<h2>{e(d['name'] or '')}</h2><p>{e(d['trade'])} &middot; {d['rating']} stars{shield}</p>"
            f"<p style='font-size:28px'><b>Arriving in {e(eta)}</b></p><p>{e(dist)}</p>"
            f"<p style='color:#666'>Live trip shared via BuildCrew</p></body>")
    return HTMLResponse(page, headers={"X-Robots-Tag": "noindex", "Referrer-Policy": "no-referrer", "Cache-Control": "no-store"})
