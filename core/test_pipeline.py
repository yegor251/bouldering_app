"""Synthetic fixtures for the route-selection logic (no model needed).

Builds a fake wall: gray background, several red and blue "holds".
The same scenario is the reference for the Swift port.
"""

import cv2
import numpy as np

from .pipeline import RouteSession, hold_from_polygon

RED = (40, 40, 200)      # BGR
RED_DARK = (30, 30, 160)
BLUE = (220, 90, 50)
BG = (120, 120, 120)
BG_HOLD = (135, 135, 135)


def circle_polygon(cx: int, cy: int, r: int, n: int = 24) -> list[list[int]]:
    angles = np.linspace(0, 2 * np.pi, n, endpoint=False)
    return [[int(cx + r * np.cos(a)), int(cy + r * np.sin(a))] for a in angles]


def build_session() -> RouteSession:
    img = np.full((480, 640, 3), BG, dtype=np.uint8)
    specs = [
        (RED, circle_polygon(100, 120, 40)),
        (RED, circle_polygon(200, 300, 35)),
        (RED_DARK, circle_polygon(320, 150, 38)),
        (BLUE, circle_polygon(450, 350, 42)),
        (BLUE, circle_polygon(550, 120, 30)),
        (BG_HOLD, circle_polygon(100, 400, 25)),
    ]
    for bgr, poly in specs:
        cv2.fillPoly(img, [np.asarray(poly, np.int32)], bgr)
    holds = []
    for i, (_, poly) in enumerate(specs):
        hold = hold_from_polygon(img, poly)
        assert hold is not None
        hold.id = i
        holds.append(hold)
    return RouteSession(image_bgr=img, holds=holds)


def test_reference_pick_returns_hold() -> None:
    session = build_session()
    ref = session.pick_reference(100, 120)
    assert ref is not None
    assert ref.id == 0


def test_auto_select_same_color() -> None:
    session = build_session()
    session.pick_reference(100, 120)
    selected = session.auto_select()
    assert 0 in selected and 1 in selected, "both bright-red holds must be selected"
    assert 3 not in selected and 4 not in selected, "blue holds must be excluded"
    assert 2 in selected, "darker red stays within default delta-E"


def test_threshold_excludes_darker_red() -> None:
    session = build_session()
    session.pick_reference(100, 120)
    strict = session.auto_select(max_de=8.0)
    assert 0 in strict and 1 in strict
    assert 2 not in strict, "dark red falls out at a strict threshold"


def test_toggle_add_remove() -> None:
    session = build_session()
    session.pick_reference(100, 120)
    session.auto_select()
    session.toggle(3)
    assert 3 in session.selected
    session.toggle(3)
    assert 3 not in session.selected


def test_tap_empty_background_no_reference() -> None:
    session = build_session()
    assert session.pick_reference(300, 460) is None
    assert session.auto_select() == set()


def test_cutout_alpha_only_on_route() -> None:
    session = build_session()
    session.pick_reference(100, 120)
    session.auto_select()
    rgba = session.export_cutout()
    alpha = rgba[:, :, 3]
    assert alpha[120, 100] == 255, "inside a selected hold"
    assert alpha[350, 450] == 0, "inside a non-selected (blue) hold"
    assert alpha[30, 30] == 0, "background stays transparent"
