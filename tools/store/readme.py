"""The README's images: the rounded logo and plain captures (no captions) with rounded corners.

    python3 tools/store/readme.py      # build/store/shots → docs/icon.png, docs/mac.webp, docs/iphone-*.webp
"""
import pathlib
from PIL import Image, ImageDraw

REPO = pathlib.Path(__file__).resolve().parents[2]
SHOTS, DOCS = REPO / "build/store/shots", REPO / "docs"


def rounded(im, radius):
    # Drawn at 3× and scaled down, so the corner is antialiased.
    m = Image.new("L", (im.width * 3, im.height * 3), 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, im.width * 3 - 1, im.height * 3 - 1], radius=radius * 3, fill=255)
    im = im.convert("RGBA")
    im.putalpha(m.resize(im.size, Image.LANCZOS))
    return im


icon = Image.open(REPO / "FujiBridge/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
rounded(icon, int(1024 * 0.2237) // 1).resize((256, 256), Image.LANCZOS).save(DOCS / "icon.png", optimize=True)

for src, out, width, radius in [("mac-camera", "mac", 1600, 18), ("iphone-import", "iphone-import", 520, 56),
                                ("iphone-camera", "iphone-camera", 520, 56), ("iphone-viewer", "iphone-viewer", 520, 56)]:
    im = Image.open(SHOTS / f"{src}.png").convert("RGB")
    im = im.resize((width, round(im.height * width / im.width)), Image.LANCZOS)
    rounded(im, radius).save(DOCS / f"{out}.webp", quality=86, method=6)
    print(f"docs/{out}.webp")
