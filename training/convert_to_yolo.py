"""Convert ClimbInst (Labelme JSON polygons) to YOLO segmentation format.

Layout produced:
    data/yolo/images/{train,validation,test}/*.jpg
    data/yolo/labels/{train,validation,test}/*.txt
    data/yolo/dataset.yaml

Single class 0 "hold" — the dataset annotates holds and volumes uniformly.
"""

import json
import shutil
from collections import Counter
from pathlib import Path

import yaml

SRC = Path("data/climbinst")
DST = Path("data/yolo")
CLASS_ID = 0
SPLITS = {"train": "train", "validation": "val", "test": "test"}


def convert_shape(shape: dict, img_w: int, img_h: int) -> list[float] | None:
    if shape.get("shape_type") not in (None, "polygon"):
        return None
    points = shape["points"]
    if len(points) < 3:
        return None
    coords: list[float] = []
    for x, y in points:
        coords.extend((min(max(x / img_w, 0.0), 1.0), min(max(y / img_h, 0.0), 1.0)))
    return coords


def convert_split(src_split: str, dst_split: str) -> tuple[int, int]:
    ann_dir = SRC / src_split / "annotations"
    img_dir = SRC / src_split / "images"
    dst_img = DST / "images" / dst_split
    dst_lbl = DST / "labels" / dst_split
    dst_img.mkdir(parents=True, exist_ok=True)
    dst_lbl.mkdir(parents=True, exist_ok=True)

    labels_seen: Counter = Counter()
    shapes_written = 0
    images_done = 0

    for ann_file in sorted(ann_dir.glob("*.json")):
        with open(ann_file, encoding="utf-8") as f:
            data = json.load(f)
        img_w, img_h = data["imageWidth"], data["imageHeight"]
        img_src = img_dir / data["imagePath"]
        if not img_src.exists():
            img_src = img_dir / (ann_file.stem + ".jpg")
        if not img_src.exists():
            print(f"skip {ann_file.name}: image not found")
            continue

        lines = []
        for shape in data["shapes"]:
            labels_seen[shape.get("label", "?")] += 1
            coords = convert_shape(shape, img_w, img_h)
            if coords is None:
                continue
            lines.append(f"{CLASS_ID} " + " ".join(f"{c:.6f}" for c in coords))
            shapes_written += 1

        shutil.copy2(img_src, dst_img / img_src.name)
        if lines:
            (dst_lbl / f"{img_src.stem}.txt").write_text("\n".join(lines) + "\n")
        # no lines -> image kept as a pure-negative sample (no label file)
        images_done += 1

    print(f"{src_split}->{dst_split}: {images_done} images, {shapes_written} polygons, labels={dict(labels_seen)}")
    return images_done, shapes_written


def main() -> None:
    for src_split, dst_split in SPLITS.items():
        convert_split(src_split, dst_split)

    yaml_data = {
        "path": str(DST.resolve()),
        "train": "images/train",
        "val": "images/val",
        "test": "images/test",
        "names": {0: "hold"},
    }
    with open(DST / "dataset.yaml", "w") as f:
        yaml.safe_dump(yaml_data, f, sort_keys=False)
    print(f"wrote {DST / 'dataset.yaml'}")


if __name__ == "__main__":
    main()
