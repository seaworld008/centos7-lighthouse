"""Generate the repo/plugin icon (512x512 PNG): a lighthouse beaming over a dark sea.
Usage: python tools/make_icon.py [output_path]   (default: .claude-plugin/icon.png)
"""
import math
import sys

from PIL import Image, ImageDraw, ImageFilter

S = 1024  # draw at 2x, downscale for anti-aliasing
out = sys.argv[1] if len(sys.argv) > 1 else ".claude-plugin/icon.png"

img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
d = ImageDraw.Draw(img)

# rounded-square night sky background with vertical gradient
bg = Image.new("RGBA", (S, S))
bd = ImageDraw.Draw(bg)
for y in range(S):
    t = y / S
    r = int(12 + 18 * t); g = int(24 + 40 * t); b = int(54 + 60 * t)
    bd.line([(0, y), (S, y)], fill=(r, g, b, 255))
mask = Image.new("L", (S, S), 0)
ImageDraw.Draw(mask).rounded_rectangle([0, 0, S - 1, S - 1], radius=200, fill=255)
img.paste(bg, (0, 0), mask)

# light beams (soft, semi-transparent)
beam = Image.new("RGBA", (S, S), (0, 0, 0, 0))
bm = ImageDraw.Draw(beam)
lx, ly = S // 2, 330
for ang, w in ((-18, 1.0), (198, 1.0)):
    a0, a1 = math.radians(ang - 9), math.radians(ang + 9)
    L = S
    pts = [(lx, ly), (lx + L * math.cos(a0), ly + L * math.sin(a0)), (lx + L * math.cos(a1), ly + L * math.sin(a1))]
    bm.polygon(pts, fill=(255, 214, 102, int(110 * w)))
beam = beam.filter(ImageFilter.GaussianBlur(18))
img = Image.alpha_composite(img, Image.composite(beam, Image.new("RGBA", (S, S)), mask))
d = ImageDraw.Draw(img)

# sea
d.rectangle([0, 800, S, S], fill=(10, 40, 70, 255))
for i, y in enumerate(range(820, S, 46)):
    for x in range(-60 + (i % 2) * 60, S, 120):
        d.arc([x, y, x + 120, y + 40], 200, 340, fill=(80, 150, 200, 180), width=8)

# tower (tapered), red/white stripes
top_w, bot_w, top_y, bot_y = 120, 230, 400, 820
def xspan(y):
    t = (y - top_y) / (bot_y - top_y)
    w = top_w + (bot_w - top_w) * t
    return S / 2 - w / 2, S / 2 + w / 2
stripes = [(400, 480, (240, 240, 240)), (480, 560, (214, 48, 49)), (560, 640, (240, 240, 240)), (640, 720, (214, 48, 49)), (720, 820, (240, 240, 240))]
for y0, y1, col in stripes:
    a0, b0 = xspan(y0); a1, b1 = xspan(y1)
    d.polygon([(a0, y0), (b0, y0), (b1, y1), (a1, y1)], fill=col + (255,))
# gallery + lantern room + roof
d.rectangle([S / 2 - 95, 380, S / 2 + 95, 405], fill=(45, 52, 70, 255))
d.rectangle([S / 2 - 60, 275, S / 2 + 60, 380], fill=(45, 52, 70, 255))
d.rectangle([S / 2 - 44, 290, S / 2 + 44, 372], fill=(255, 224, 130, 255))
glow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(glow).ellipse([lx - 110, ly - 90, lx + 110, ly + 90], fill=(255, 220, 120, 150))
img = Image.alpha_composite(img, Image.composite(glow.filter(ImageFilter.GaussianBlur(30)), Image.new("RGBA", (S, S)), mask))
d = ImageDraw.Draw(img)
d.rectangle([S / 2 - 44, 290, S / 2 + 44, 372], fill=(255, 236, 170, 255))
d.polygon([(S / 2 - 80, 278), (S / 2 + 80, 278), (S / 2, 195)], fill=(214, 48, 49, 255))
d.ellipse([S / 2 - 14, 178, S / 2 + 14, 206], fill=(45, 52, 70, 255))
# door
d.rounded_rectangle([S / 2 - 32, 735, S / 2 + 32, 820], radius=28, fill=(45, 52, 70, 255))

img.resize((512, 512), Image.LANCZOS).save(out)
print("saved", out)
