"""End-to-end smoke test of the demo server against a running instance."""

import json
import sys
import urllib.request

import cv2
import numpy as np

BASE = "http://127.0.0.1:8000"


def post_json(path: str, payload: dict) -> dict:
    req = urllib.request.Request(
        BASE + path, data=json.dumps(payload).encode(), headers={"Content-Type": "application/json"}
    )
    with urllib.request.urlopen(req, timeout=120) as r:
        return json.loads(r.read())


def analyze(image_path: str) -> dict:
    with open(image_path, "rb") as f:
        data = f.read()
    boundary = "----smoke"
    body = (
        f"--{boundary}\r\nContent-Disposition: form-data; name=\"file\"; "
        f"filename=\"t.jpg\"\r\nContent-Type: image/jpeg\r\n\r\n"
    ).encode() + data + f"\r\n--{boundary}--\r\n".encode()
    req = urllib.request.Request(
        BASE + "/api/analyze",
        data=body,
        headers={"Content-Type": f"multipart/form-data; boundary={boundary}"},
    )
    with urllib.request.urlopen(req, timeout=300) as r:
        return json.loads(r.read())


def main() -> None:
    img_path = sys.argv[1]
    d = analyze(img_path)
    holds = d["holds"]
    print(f"image_id={d['image_id']} size={d['width']}x{d['height']} holds={len(holds)}")
    assert holds, "no holds detected"

    # tap the largest hold: its centroid is guaranteed inside it
    top = max(holds, key=lambda h: len(h["polygon"]))
    poly = np.asarray(top["polygon"], np.int32)
    x, y = int(poly[:, 0].mean()), int(poly[:, 1].mean())
    sel = post_json("/api/select", {"image_id": d["image_id"], "x": x, "y": y, "max_de": 30})
    print(f"select: ok={sel['ok']} reference={sel.get('reference')} selected={len(sel.get('selected', []))}")
    assert sel["ok"]

    if len(holds) > 1:
        other = next(h for h in holds if h["id"] != top["id"])
        tog = post_json("/api/toggle", {"image_id": d["image_id"], "hold_id": other["id"]})
        print(f"toggle: selected={len(tog['selected'])}")
        assert other["id"] in tog["selected"]

    with urllib.request.urlopen(f"{BASE}/api/export/{d['image_id']}", timeout=120) as r:
        png = r.read()
    arr = cv2.imdecode(np.frombuffer(png, np.uint8), cv2.IMREAD_UNCHANGED)
    opaque = int((arr[:, :, 3] > 200).sum())
    print(f"export: {len(png) // 1024} KB, opaque px={opaque}")
    assert arr.shape[2] == 4 and opaque > 0
    print("SMOKE OK")


if __name__ == "__main__":
    main()
