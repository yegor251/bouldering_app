"""Fine-tune YOLO11n-seg on the converted ClimbInst dataset (Apple MPS).

MPS notes (verified empirically, torch 2.15 / ultralytics 8.4):
- losses go NaN at imgsz>=960 regardless of optimizer; 640 is stable
- AMP and deterministic-algorithms mode also trigger NaNs, disabled
"""

import argparse
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parent.parent


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", default="models/holdseg/weights/best.pt")
    parser.add_argument("--epochs", type=int, default=40)
    parser.add_argument("--imgsz", type=int, default=640)
    parser.add_argument("--batch", type=int, default=16)
    parser.add_argument("--device", default="mps")
    parser.add_argument("--name", default="holdseg2")
    parser.add_argument("--workers", type=int, default=6,
                        help="dataloader workers: copy-paste aug is CPU-heavy, "
                             "parallel workers keep the GPU fed")
    args = parser.parse_args()

    model = YOLO(args.model)
    model.train(
        data=str(ROOT / "data" / "yolo" / "dataset.yaml"),
        epochs=args.epochs,
        imgsz=args.imgsz,
        batch=args.batch,
        device=args.device,
        optimizer="SGD",
        lr0=0.005,     # fine-tune: gentler than the from-scratch 0.01
        patience=15,
        amp=False,
        deterministic=False,
        workers=args.workers,
        project=str(ROOT / "models"),
        name=args.name,
        exist_ok=True,
        hsv_h=0.008,   # mild color jitter: color is the downstream route cue,
        hsv_s=0.3,     # aggressive shifts would hurt hold-color statistics
        hsv_v=0.3,
        fliplr=0.5,
        mosaic=1.0,
        copy_paste=0.2,  # seg-only aug: pastes hold instances onto other walls,
        close_mosaic=10, # tightens masks where the base model is sloppy
    )
    metrics = model.val(split="test")
    print("TEST box mAP50-95:", metrics.box.maps, "| seg mAP50-95:", metrics.seg.maps)


if __name__ == "__main__":
    main()
