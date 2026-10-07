# Builds the app icons from assets/brand/logo_source.png (white mark on
# transparent). Run from app/:  python3 tool/make_icon.py && dart run flutter_launcher_icons
from PIL import Image, ImageDraw, ImageFilter

BG = (10, 10, 10)
SRC = Image.open("assets/brand/logo_source.png").convert("RGBA")
MARK = SRC.crop(SRC.getchannel("A").point(lambda a: 255 if a > 8 else 0).getbbox())


def place(canvas, scale):
    """Centre the mark on canvas, its larger side = scale * canvas size."""
    S = canvas.size[0]
    w, h = MARK.size
    k = S * scale / max(w, h)
    m = MARK.resize((round(w * k), round(h * k)), Image.LANCZOS)
    canvas.alpha_composite(m, ((S - m.size[0]) // 2, (S - m.size[1]) // 2))
    return canvas


S = 1024
# iOS / Windows / legacy Android: full-bleed square.
place(Image.new("RGBA", (S, S), BG + (255,)), 0.56).convert("RGB").save("assets/icon/icon.png")
# Android adaptive foreground: mark inside the 66% safe zone.
place(Image.new("RGBA", (S, S), (0, 0, 0, 0)), 0.40).save("assets/icon/foreground.png")
# macOS: rounded tile with margin and a soft shadow.
mac = Image.new("RGBA", (S, S), (0, 0, 0, 0))
box = [100, 100, S - 100, S - 100]
shadow = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(shadow).rounded_rectangle([box[0], box[1] + 12, box[2], box[3] + 12], radius=185, fill=(0, 0, 0, 110))
mac.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
tile = Image.new("RGBA", (S, S), (0, 0, 0, 0))
ImageDraw.Draw(tile).rounded_rectangle(box, radius=185, fill=BG + (255,), outline=(40, 40, 40, 255), width=3)
place(tile, 0.46)
mac.alpha_composite(tile)
mac.save("assets/icon/icon_macos.png")
# In-app mark.
MARK.save("assets/brand/logo.png")
print("ok", MARK.size)

# Tray and menu-bar icons (lib/tray.dart): the bare mark, no tile. tray.png
# is 36 px, twice the 18 pt the macOS menu bar draws it at, so Retina bars
# get a sharp glyph; it is a template there (alpha only), so it follows a
# light or dark bar, and Linux panels scale it to their own size. Windows
# draws icons as they are, so it gets an .ico in white for the usual dark
# taskbar and one in black for the light theme (lib/tray.dart picks), with
# the sizes the notification area asks for from 100% to 200% scale.
def mark_only(size, scale, color=(255, 255, 255)):
    m = place(Image.new("RGBA", (size, size), (0, 0, 0, 0)), scale)
    tinted = Image.new("RGBA", m.size, color + (0,))
    tinted.putalpha(m.getchannel("A"))
    return tinted


mark_only(36, 0.9).save("assets/brand/tray.png")
ICO_SIZES = [(16, 16), (20, 20), (24, 24), (32, 32)]
mark_only(256, 0.92).save("assets/brand/tray.ico", sizes=ICO_SIZES)
mark_only(256, 0.92, (0, 0, 0)).save("assets/brand/tray_light.ico", sizes=ICO_SIZES)
