"""Kestrel demo-app — FastAPI backend.

Serves the REST API the React UI calls, and (in the container) the built static
frontend. Two roles, one app: the storefront drives the hero's live session into
the real pipeline; the marketing view reads the live funnel + governed lift.
"""

from __future__ import annotations

import os

from fastapi import FastAPI, HTTPException
from fastapi.responses import FileResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

import kestrel

app = FastAPI(title="Kestrel Market demo-app")

STATIC_DIR = os.environ.get("STATIC_DIR", "/app/static")


# ── request models ───────────────────────────────────────────────────────────
class EventIn(BaseModel):
    session_id: str
    member_id: int
    event_type: str
    product_id: int | None = None
    category_id: int | None = None


class SessionIn(BaseModel):
    session_id: str
    member_id: int


class RedeemIn(BaseModel):
    member_id: int


# ── storefront API ───────────────────────────────────────────────────────────
@app.get("/api/status")
def api_status():
    return kestrel.status()


@app.get("/api/catalog")
def api_catalog():
    return kestrel.catalog()


@app.get("/api/hero")
def api_hero():
    return kestrel.hero_persona()


@app.post("/api/events")
def api_events(ev: EventIn):
    kestrel.emit_digital(ev.session_id, ev.member_id, ev.event_type,
                         ev.product_id, ev.category_id)
    return {"ok": True}


@app.post("/api/decide")
def api_decide(s: SessionIn):
    d = kestrel.decide(s.member_id, s.session_id)
    return {"offer": d}


@app.post("/api/accept")
def api_accept(s: SessionIn):
    rec = kestrel.accept_offer(s.member_id, s.session_id)
    if not rec:
        raise HTTPException(409, "no offer to accept")
    return {"assignment": rec}


@app.post("/api/redeem")
def api_redeem(r: RedeemIn):
    try:
        return {"redemption": kestrel.redeem(r.member_id)}
    except Exception as e:
        raise HTTPException(409, f"redeem failed: {e}")


# ── marketing API ────────────────────────────────────────────────────────────
@app.get("/api/campaign")
def api_campaign():
    return kestrel.campaign()


@app.get("/api/funnel")
def api_funnel():
    return kestrel.funnel()


@app.get("/api/lift")
def api_lift():
    return {"rows": kestrel.lift()}


# ── static frontend (SPA) ────────────────────────────────────────────────────
if os.path.isdir(STATIC_DIR):
    app.mount("/assets", StaticFiles(directory=os.path.join(STATIC_DIR, "assets")), name="assets")

    @app.get("/{full_path:path}")
    def spa(full_path: str):
        candidate = os.path.join(STATIC_DIR, full_path)
        if full_path and os.path.isfile(candidate):
            return FileResponse(candidate)
        return FileResponse(os.path.join(STATIC_DIR, "index.html"))
