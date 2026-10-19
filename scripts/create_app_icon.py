#!/usr/bin/env python3
"""Generate a native iOS opaque 1024px icon, no placeholder artwork."""
import json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont

root = Path("CarTripAssistant/Assets.xcassets/AppIcon.appiconset")
root.mkdir(parents=True, exist_ok=True)
size = 1024
im = Image.new("RGB", (size, size), "#0b1425")
d = ImageDraw.Draw(im)
d.rounded_rectangle((95, 95, 929, 929), radius=205, fill="#172943")
d.rounded_rectangle((150, 150, 874, 874), radius=160, outline="#327df5", width=13)
# Distinctive route stroke and destination pin.
d.line([(250, 690), (350, 620), (440, 660), (550, 535), (680, 565), (770, 405)], fill="#43e2ad", width=35, joint="curve")
for x, y in [(250, 690), (770, 405)]:
    d.ellipse((x-29, y-29, x+29, y+29), fill="#43e2ad")
# White car silhouette and wheels.
d.rounded_rectangle((295, 400, 710, 515), radius=43, fill="#f7fbff")
d.polygon([(355, 408), (413, 334), (592, 334), (657, 408)], fill="#f7fbff")
d.rounded_rectangle((431, 348, 568, 402), radius=14, fill="#327df5")
d.ellipse((350, 480, 435, 565), fill="#0b1425")
d.ellipse((574, 480, 659, 565), fill="#0b1425")
im.save(root / "AppIcon.png")
(root / "Contents.json").write_text(json.dumps({
    "images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}],
    "info": {"author": "xcode", "version": 1}
}, ensure_ascii=False, indent=2) + "\n")
