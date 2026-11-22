"""Core route-selection pipeline.

Detect holds (see core.detector), then: user taps one hold -> its mean LAB
color becomes the reference -> all holds within a color distance (delta-E)
form the route -> manual toggle fixes misses. Background is cut via the
union mask of the selected holds.

This module is the reference implementation: the future Swift port must
reproduce its behavior against the same fixtures (plan.md, stage 3).
"""

from dataclasses import dataclass, field

import cv2
import numpy as np

# Same-route holds (incl. worn/darker ones) measure ~26 in OpenCV LAB,
# different-color routes 100+. 30 catches the former with margin.
DEFAULT_MAX_DE = 30.0
L_WEIGHT = 0.5  # lightness shifts with shading; chroma is the route identity


def weighted_de(lab_a, lab_b) -> float:
    """Delta-E with lightness discounted: shadows must not split a route."""
    dl = (lab_a[0] - lab_b[0]) * L_WEIGHT
    da = lab_a[1] - lab_b[1]
    db = lab_a[2] - lab_b[2]
    return float(np.sqrt(dl * dl + da * da + db * db))


@dataclass
class Hold:
    id: int
    polygon: list[list[int]]  # original image pixel coords
    color_lab: tuple[float, float, float]
    color_bgr: tuple[float, float, float]
    area: int
    centroid: tuple[float, float]
    conf: float = 1.0

    def contains(self, x: float, y: float) -> bool:
        contour = np.asarray(self.polygon, dtype=np.int32)
        return cv2.pointPolygonTest(contour, (float(x), float(y)), False) >= 0

    def color_hex(self) -> str:
        b, g, r = (int(round(c)) for c in self.color_bgr)
        return f"#{r:02x}{g:02x}{b:02x}"


def hold_from_polygon(image_bgr: np.ndarray, polygon: list, conf: float = 1.0) -> Hold | None:
    """Build a Hold from a pixel-coordinate polygon: rasterize, measure color."""
    contour = np.round(np.asarray(polygon, dtype=np.float64)).astype(np.int32)
    h, w = image_bgr.shape[:2]
    mask = np.zeros((h, w), dtype=np.uint8)
    cv2.fillPoly(mask, [contour], 1)
    area = int(mask.sum())
    if area < 30:
        return None
    sel = mask.astype(bool)
    lab = cv2.cvtColor(image_bgr, cv2.COLOR_BGR2LAB)
    # median (not mean): robust to specular highlights and bolt holes
    color_lab = tuple(float(np.median(lab_pixels)) for lab_pixels in lab[sel].T)
    color_bgr = tuple(float(np.median(channel)) for channel in image_bgr[sel].T)
    ys, xs = np.nonzero(mask)
    centroid = (float(xs.mean()), float(ys.mean()))
    return Hold(
        id=-1,
        polygon=contour.tolist(),
        color_lab=color_lab,
        color_bgr=color_bgr,
        area=area,
        centroid=centroid,
        conf=float(conf),
    )


@dataclass
class RouteSession:
    image_bgr: np.ndarray
    holds: list[Hold] = field(default_factory=list)
    selected: set[int] = field(default_factory=set)
    reference_id: int | None = None

    @property
    def hold_map(self) -> dict[int, Hold]:
        return {h.id: h for h in self.holds}

    def pick_reference(self, x: float, y: float) -> Hold | None:
        """Hold under the tap; smallest wins when polygons overlap."""
        inside = [h for h in self.holds if h.contains(x, y)]
        if not inside:
            return None
        ref = min(inside, key=lambda h: h.area)
        self.reference_id = ref.id
        return ref

    def auto_select(self, max_de: float = DEFAULT_MAX_DE) -> set[int]:
        ref = self.hold_map.get(self.reference_id)
        if ref is None:
            self.selected = set()
            return self.selected
        self.selected = {
            h.id
            for h in self.holds
            if weighted_de(h.color_lab, ref.color_lab) <= max_de
        }
        return self.selected

    def toggle(self, hold_id: int) -> set[int]:
        if hold_id in self.selected:
            self.selected.discard(hold_id)
        else:
            self.selected.add(hold_id)
        return self.selected

    def union_mask(self) -> np.ndarray:
        h, w = self.image_bgr.shape[:2]
        mask = np.zeros((h, w), dtype=np.uint8)
        contours = [
            np.asarray(self.hold_map[i].polygon, dtype=np.int32) for i in self.selected
        ]
        if contours:
            cv2.fillPoly(mask, contours, 1)
        return mask.astype(bool)

    def render_highlight(self, dim: float = 0.35) -> np.ndarray:
        """Background dimmed, selected holds at full brightness with contour."""
        out = (self.image_bgr.astype(np.float32) * dim).astype(np.uint8)
        union = self.union_mask()
        out[union] = self.image_bgr[union]
        contours = [
            np.asarray(self.hold_map[i].polygon, dtype=np.int32) for i in self.selected
        ]
        if contours:
            cv2.polylines(out, contours, True, (60, 220, 120), 2)
        return out

    def export_cutout(self) -> np.ndarray:
        """RGBA image: transparent background, feathered route edges."""
        h, w = self.image_bgr.shape[:2]
        rgba = np.dstack([self.image_bgr, np.zeros((h, w), dtype=np.uint8)])
        alpha = np.zeros((h, w), dtype=np.uint8)
        union = self.union_mask()
        alpha[union] = 255
        alpha = cv2.GaussianBlur(alpha, (5, 5), 0)
        rgba[:, :, 3] = alpha
        return rgba
