"""Temporary web demo: upload a wall photo, tap a hold, get the route.

Run:  .venv/bin/python -m demo.server  (then open http://127.0.0.1:8000)
"""

import base64
import io
import sys
import uuid
from pathlib import Path

import cv2
import numpy as np
from fastapi import FastAPI, File, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, Response
from pydantic import BaseModel

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from core.detector import DEFAULT_WEIGHTS, detect  # noqa: E402
from core.pipeline import DEFAULT_MAX_DE, RouteSession  # noqa: E402

app = FastAPI(title="Bouldering route demo")
app.add_middleware(CORSMiddleware, allow_origins=["*"], allow_methods=["*"], allow_headers=["*"])

MAX_SIDE = 2000  # cap for speed and payload size
SESSIONS: dict[str, RouteSession] = {}


def decode_image(data: bytes) -> np.ndarray:
    img = cv2.imdecode(np.frombuffer(data, np.uint8), cv2.IMREAD_COLOR)
    if img is None:
        raise HTTPException(400, "not an image")
    h, w = img.shape[:2]
    scale = MAX_SIDE / max(h, w)
    if scale < 1.0:
        img = cv2.resize(img, (int(w * scale), int(h * scale)), interpolation=cv2.INTER_AREA)
    return img


def to_data_url(img_bgr: np.ndarray, ext: str = ".jpg") -> str:
    ok, buf = cv2.imencode(ext, img_bgr, [cv2.IMWRITE_JPEG_QUALITY, 85])
    return "data:image/jpeg;base64," + base64.b64encode(buf.tobytes()).decode()


def subsample(polygon: list, max_points: int = 40) -> list[list[int]]:
    if len(polygon) <= max_points:
        return polygon
    step = len(polygon) / max_points
    return [polygon[int(i * step)] for i in range(max_points)]


def holds_payload(session: RouteSession) -> list[dict]:
    return [
        {
            "id": h.id,
            "polygon": subsample(h.polygon),
            "color": h.color_hex(),
            "conf": round(h.conf, 2),
        }
        for h in session.holds
    ]


@app.get("/")
def index() -> FileResponse:
    return FileResponse(Path(__file__).parent / "static" / "index.html")


@app.post("/api/analyze")
async def analyze(file: UploadFile = File(...)) -> dict:
    data = await file.read()
    image = decode_image(data)
    weights = sys.argv[sys.argv.index("--weights") + 1] if "--weights" in sys.argv else DEFAULT_WEIGHTS
    holds = detect(image, weights=weights)
    session = RouteSession(image_bgr=image, holds=holds)
    image_id = uuid.uuid4().hex[:12]
    SESSIONS[image_id] = session
    h, w = image.shape[:2]
    return {
        "image_id": image_id,
        "width": w,
        "height": h,
        "image": to_data_url(image),
        "holds": holds_payload(session),
    }


class SelectRequest(BaseModel):
    image_id: str
    x: float
    y: float
    max_de: float = DEFAULT_MAX_DE


@app.post("/api/select")
def select(req: SelectRequest) -> dict:
    session = SESSIONS.get(req.image_id) or raise_404(req.image_id)
    ref = session.pick_reference(req.x, req.y)
    if ref is None:
        return {"ok": False, "reason": "no hold at this point"}
    selected = session.auto_select(req.max_de)
    return {
        "ok": True,
        "reference": ref.id,
        "selected": sorted(selected),
        "render": to_data_url(session.render_highlight()),
    }


class ReselectRequest(BaseModel):
    image_id: str
    max_de: float


@app.post("/api/reselect")
def reselect(req: ReselectRequest) -> dict:
    session = SESSIONS.get(req.image_id) or raise_404(req.image_id)
    if session.reference_id is None:
        return {"ok": False, "reason": "no reference picked yet"}
    selected = session.auto_select(req.max_de)
    return {"ok": True, "selected": sorted(selected), "render": to_data_url(session.render_highlight())}


class ToggleRequest(BaseModel):
    image_id: str
    hold_id: int


@app.post("/api/toggle")
def toggle(req: ToggleRequest) -> dict:
    session = SESSIONS.get(req.image_id) or raise_404(req.image_id)
    if req.hold_id not in session.hold_map:
        return {"ok": False, "reason": "unknown hold id"}
    session.toggle(req.hold_id)
    return {
        "ok": True,
        "selected": sorted(session.selected),
        "render": to_data_url(session.render_highlight()),
    }


@app.get("/api/export/{image_id}")
def export(image_id: str) -> Response:
    session = SESSIONS.get(image_id) or raise_404(image_id)
    if not session.selected:
        raise HTTPException(400, "nothing selected")
    ok, buf = cv2.imencode(".png", session.export_cutout())
    return Response(content=buf.tobytes(), media_type="image/png")


def raise_404(image_id: str):
    raise HTTPException(404, f"unknown image_id: {image_id}")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=8000)
