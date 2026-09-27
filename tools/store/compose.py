"""Store screenshots: a raw capture framed on the icon's gold with a New York caption.

    python3 tools/store/compose.py        # build/store/shots/*.png → build/store/final/{iphone,ipad,mac}-N.png

Colors, sizes and captions are the ones documented in docs/STORE.md. Change them here and there together.
"""
import pathlib
from PIL import Image, ImageDraw, ImageFont, ImageFilter

REPO = pathlib.Path(__file__).resolve().parents[2]
SHOTS, FINAL = REPO / "build/store/shots", REPO / "build/store/final"

# The icon's palette (tools/icon.swift): gold gradient, ink, and a warm brown for subtitles and shadows.
GOLD_TOP, GOLD_BOTTOM = (0xC9, 0xA0, 0x4C), (0xA8, 0x7E, 0x32)
INK, SUBTITLE, SHADOW, BORDER = (0x1B, 0x15, 0x10), (0x3A, 0x2C, 0x18), (0x3A, 0x28, 0x0C), (0x2A, 0x20, 0x16)
SERIF = "/System/Library/Fonts/NewYork.ttf"   # variable: optical size, weight, grade
SANS = "/System/Library/Fonts/SFNS.ttf"       # variable: width, optical size, grade, weight

# (canvas, title size, subtitle size, corner radius of the capture, top and bottom margins)
LAYOUT = {
    "iphone": dict(size=(1284, 2778), title=84, sub=42, radius=70, top=170, bottom=90),   # 6.5" slot
    "ipad": dict(size=(2064, 2752), title=104, sub=48, radius=44, top=170, bottom=120),   # 13" slot
    "mac": dict(size=(2880, 1800), title=84, sub=40, radius=28, top=110, bottom=80),
}

# Order is the order on the App Store: the first three show on the install sheet.
CAPTIONS = {
    "iphone": [
        ("import", "Import from your Fujifilm\nin one tap", "USB or Wi-Fi, woken over Bluetooth"),
        ("camera", "Preview the card,\nkeep what you pick", "Browse before anything is copied"),
        ("library", "Your photos,\nbeautifully laid out", "Straight into Files, newest first"),
        ("viewer", "Every frame at\nfull resolution", "Swipe, zoom, share"),
    ],
    "ipad": [
        ("import", "Import from your Fujifilm in one tap", "USB or Wi-Fi, woken over Bluetooth"),
        ("camera", "Preview the card, keep what you pick", "Browse before anything is copied"),
        ("library", "Your photos, beautifully laid out", "Straight into Files, newest first"),
        ("viewer", "Every frame at full resolution", "Swipe, zoom, share"),
    ],
    "mac": [
        ("import", "Import from your Fujifilm in one click", "USB or Wi-Fi, woken over Bluetooth"),
        ("camera", "Preview the card, keep what you pick", "Browse before anything is copied"),
        ("library", "Your photos, straight into Pictures", "A calm grid that makes room for the images"),
        ("viewer", "Every frame at full resolution", "Arrow keys to move, Space to close"),
        ("diagnostics", "Every import, measured and explained", "Share a report when something goes wrong"),
    ],
}


def font(path, size, weight):
    f = ImageFont.truetype(path, size)
    # Set every axis: left alone, New York comes out at its thin display cut.
    f.set_variation_by_axes([64, weight, 0] if path == SERIF else [100, 28, 400, weight])
    return f


def background(w, h):
    bg = Image.new("RGB", (w, h))
    d = ImageDraw.Draw(bg)
    for y in range(h):
        t = y / (h - 1)
        d.line([(0, y), (w, y)], fill=tuple(int(a + (b - a) * t) for a, b in zip(GOLD_TOP, GOLD_BOTTOM)))
    return bg


def compose(shot, out, size, title, subtitle, top, title_size, sub_size, radius, bottom):
    W, H = size
    bg = background(W, H)
    d = ImageDraw.Draw(bg)
    tf, sf = font(SERIF, title_size, 640), font(SANS, sub_size, 480)
    y = top
    for line in title.split("\n"):
        d.text(((W - d.textlength(line, font=tf)) / 2, y), line, font=tf, fill=INK)
        y += int(title_size * 1.18)
    y += int(sub_size * 0.45)
    d.text(((W - d.textlength(subtitle, font=sf)) / 2, y), subtitle, font=sf, fill=SUBTITLE)
    y += int(sub_size * 1.3) + int(title_size * 0.55)

    im = Image.open(shot).convert("RGB")
    scale = min((H - y - bottom) / im.height, (W - 2 * max(bottom, int(W * 0.07))) / im.width)
    sw, sh = int(im.width * scale), int(im.height * scale)
    im = im.resize((sw, sh), Image.LANCZOS)
    x = (W - sw) // 2
    mask = Image.new("L", (sw, sh), 0)
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, sw - 1, sh - 1], radius=radius, fill=255)
    shadow = Image.new("L", (W, H), 0)
    ImageDraw.Draw(shadow).rounded_rectangle([x, y + 18, x + sw, y + sh + 18], radius=radius, fill=110)
    bg.paste(Image.new("RGB", (W, H), SHADOW), (0, 0), shadow.filter(ImageFilter.GaussianBlur(36)))
    bg.paste(im, (x, y), mask)
    ImageDraw.Draw(bg).rounded_rectangle([x, y, x + sw - 1, y + sh - 1], radius=radius, outline=BORDER, width=3)
    bg.save(out)
    print(out.relative_to(REPO), bg.size)


if __name__ == "__main__":
    FINAL.mkdir(parents=True, exist_ok=True)
    for platform, shots in CAPTIONS.items():
        L = LAYOUT[platform]
        for i, (name, title, subtitle) in enumerate(shots, 1):
            src = SHOTS / f"{platform}-{name}.png"
            if not src.exists():
                continue
            compose(src, FINAL / f"{platform}-{i}.png", L["size"], title, subtitle, L["top"], L["title"],
                    L["sub"], L["radius"], L["bottom"])
