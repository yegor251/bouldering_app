"""Hold detection with a fine-tuned YOLO11n-seg model."""

import threading

import numpy as np
from ultralytics import YOLO

from .pipeline import Hold, hold_from_polygon

DEFAULT_WEIGHTS = "models/holdseg/weights/best.pt"

_lock = threading.Lock()
_models: dict[str, YOLO] = {}


def load(weights: str = DEFAULT_WEIGHTS) -> YOLO:
    with _lock:
        if weights not in _models:
            _models[weights] = YOLO(weights)
        return _models[weights]


def detect(
    image_bgr: np.ndarray,
    weights: str = DEFAULT_WEIGHTS,
    conf: float = 0.25,
    imgsz: int = 1024,
) -> list[Hold]:
    model = load(weights)
    result = model.predict(source=image_bgr, conf=conf, imgsz=imgsz, verbose=False)[0]
    if result.masks is None or len(result.masks.xy) == 0:
        return []
    confs = result.boxes.conf.tolist() if result.boxes is not None else [1.0] * len(result.masks.xy)
    holds: list[Hold] = []
    for polygon, c in zip(result.masks.xy, confs):
        hold = hold_from_polygon(image_bgr, polygon, conf=c)
        if hold is None:
            continue
        hold.id = len(holds)
        holds.append(hold)
    return holds
