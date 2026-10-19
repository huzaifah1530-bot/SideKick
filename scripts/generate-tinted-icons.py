"""Generate SideKick's accent-matched alternate app icons.

Each variant recolours the primary icon so its average hue is the variant's hue.
The gradient's hue spread is narrowed, so a red variant reads as red rather than
running from red into orange. The white bolt keeps its colour because white has
no saturation. Run from the repository root after changing the primary icon:

    python scripts/generate-tinted-icons.py

Requires Pillow and NumPy. The output is committed, so CI does not run this.
Keep the constants in sync with SideKick/Services/AppIconVariant.swift.
"""
from __future__ import annotations

import json
import shutil
from pathlib import Path

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
CATALOG = ROOT / "SideKick" / "Assets.xcassets"
SOURCE = CATALOG / "AppIcon.appiconset" / "SideKickIcon-1024.png"
STEP = 15                     # degrees between variant hues
PRIMARY_RANGE = (160, 200)    # accent hues the original teal icon already matches
SPREAD = 0.5                  # keep half of the original gradient's hue range
PREVIEW_SIZE = 300            # sharp enough for SideKick's hero icon at 3x


def variant_hues() -> list[int]:
    low, high = PRIMARY_RANGE
    return [h for h in range(0, 360, STEP) if not (low <= h <= high)]


def contents(images: list[dict]) -> str:
    return json.dumps({"images": images, "info": {"author": "xcode", "version": 1}}, indent=2) + "\n"


def write(name: str, image: Image.Image) -> None:
    icon = CATALOG / f"{name}.appiconset"
    icon.mkdir()
    image.save(icon / f"{name}-1024.png", optimize=True)
    (icon / "Contents.json").write_text(contents([{
        "filename": f"{name}-1024.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}]), encoding="utf-8")
    # Image sets can be loaded at runtime with UIImage(named:); app icon sets cannot.
    preview_name = name.replace("AppIcon", "AppIconPreview", 1)
    preview = CATALOG / f"{preview_name}.imageset"
    preview.mkdir()
    image.resize((PREVIEW_SIZE, PREVIEW_SIZE), Image.LANCZOS).save(preview / f"{preview_name}.png", optimize=True)
    (preview / "Contents.json").write_text(contents([{"filename": f"{preview_name}.png", "idiom": "universal"}]), encoding="utf-8")


def mean_hue(hsv: np.ndarray) -> float:
    """Saturation- and brightness-weighted circular mean, in degrees."""
    angle = hsv[..., 0] / 256 * 2 * np.pi
    weight = (hsv[..., 1] / 255) * (hsv[..., 2] / 255)
    return float(np.degrees(np.arctan2((weight * np.sin(angle)).sum(), (weight * np.cos(angle)).sum())) % 360)


def main() -> None:
    for old in list(CATALOG.glob("AppIcon-*.appiconset")) + list(CATALOG.glob("AppIconPreview*.imageset")):
        shutil.rmtree(old)
    source = Image.open(SOURCE).convert("RGB")
    hsv = np.array(source.convert("HSV"), dtype=np.float64)
    reference = mean_hue(hsv)
    print(f"Reference (average) hue: {reference:.1f} degrees")

    # Offset of each pixel from the average, wrapped to -180...180.
    offset = ((hsv[..., 0] / 256 * 360 - reference + 180) % 360) - 180
    for hue in variant_hues():
        recoloured = hsv.copy()
        recoloured[..., 0] = ((hue + offset * SPREAD) % 360) / 360 * 256 % 256
        write(f"AppIcon-Hue{hue:03d}", Image.fromarray(recoloured.round().astype(np.uint8), "HSV").convert("RGB"))

    # Greys, black and white accents have no hue to match.
    write("AppIcon-Mono", source.convert("L").convert("RGB"))

    preview = CATALOG / "AppIconPreview.imageset"
    preview.mkdir()
    source.resize((PREVIEW_SIZE, PREVIEW_SIZE), Image.LANCZOS).save(preview / "AppIconPreview.png", optimize=True)
    (preview / "Contents.json").write_text(contents([{"filename": "AppIconPreview.png", "idiom": "universal"}]), encoding="utf-8")
    print("Wrote", len(variant_hues()) + 1, "alternate icons:", ", ".join(f"{h:03d}" for h in variant_hues()))


if __name__ == "__main__":
    main()
