"""
Pass 1 of detection-based reframing: find the car in every frame with YOLO.

Unlike a correlation tracker, a detector re-decides each frame from scratch, so it
cannot drift onto smoke. Where the car is genuinely hidden it reports nothing, which
is honest - the camera logic can then coast rather than chase a false positive.
"""
import json
import os
import sys
import numpy as np
from ultralytics import YOLO

# usage: detect_car.py [source_video] [detections_out]
#   defaults match reframe_src.py, so the two compose without arguments
SRC = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("SRC", "stabilised.mp4")
OUT = sys.argv[2] if len(sys.argv) > 2 else os.environ.get("DETECTIONS", "detections.json")

# COCO classes worth accepting as "the car"
VEHICLE = {2: "car", 7: "truck", 5: "bus"}


def main():
    model = YOLO("yolo11m.pt")
    results = model.predict(SRC, stream=True, conf=0.25, verbose=False)

    dets = {}
    n = 0
    for r in results:
        found = []
        for b in r.boxes:
            cls = int(b.cls[0])
            if cls in VEHICLE:
                x1, y1, x2, y2 = [float(v) for v in b.xyxy[0]]
                found.append({
                    "cls": VEHICLE[cls],
                    "conf": float(b.conf[0]),
                    "cx": (x1 + x2) / 2,
                    "cy": (y1 + y2) / 2,
                    "w": x2 - x1,
                    "h": y2 - y1,
                })
        dets[n] = found
        n += 1

    hit = sum(1 for v in dets.values() if v)
    print(f"frames: {n}, frames with a vehicle: {hit} ({100*hit/max(n,1):.0f}%)")
    sizes = [d["w"] for v in dets.values() for d in v]
    if sizes:
        print(f"detected widths: min {min(sizes):.0f}px  median {np.median(sizes):.0f}px  max {max(sizes):.0f}px")

    with open(OUT, "w") as f:
        json.dump(dets, f)
    print(f"saved {OUT}")


if __name__ == "__main__":
    main()
