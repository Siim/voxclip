"""Phone frames with real rendered text (1,280 x 720 PNG) for the Windows OCR probe: python3 -I render_text_frames.py <out dir> [font]."""
import sys
from PIL import Image, ImageDraw, ImageFont, ImageFilter
out = sys.argv[1]
font_path = sys.argv[2] if len(sys.argv) > 2 else "/System/Library/Fonts/Helvetica.ttc"
lines = ["Meeting moved to 3 pm", "Can you send the slides?", "Sure, sending them now",
         "Thanks! See you there", "Don't forget the notes", "The room is on floor 4", "Parking is free today"]
def frame(name, count, size, screen=(470, 110, 810, 610), tilt=0.0):
    img = Image.new("RGB", (1280, 720))
    d = ImageDraw.Draw(img)
    for y in range(720):
        g = 70 + y * 40 // 720
        d.line([(0, y), (1279, y)], fill=(g, g - 10, g - 20))
    x0, y0, x1, y1 = screen
    phone = Image.new("RGBA", (1280, 720), (0, 0, 0, 0))
    p = ImageDraw.Draw(phone)
    p.rounded_rectangle([x0 - 14, y0 - 30, x1 + 14, y1 + 30], radius=28, fill=(25, 25, 28, 255))
    scr = Image.new("RGBA", (x1 - x0, y1 - y0), (245, 245, 247, 255))
    sd = ImageDraw.Draw(scr)
    f = ImageFont.truetype(font_path, size)
    y = 20
    for text in lines[:count]:
        sd.text((14, y), text, fill=(20, 20, 20, 255), font=f)
        y += int(size * 1.9)
    phone.paste(scr, (x0, y0))
    if tilt:
        phone = phone.rotate(tilt, resample=Image.BICUBIC, center=((x0 + x1) / 2, (y0 + y1) / 2))
    img.paste(phone, (0, 0), phone)
    img.filter(ImageFilter.GaussianBlur(0.6)).save(f"{out}/{name}.png")
frame("phone-text-5-22px", 5, 22)
frame("phone-text-7-16px", 7, 16)
frame("phone-text-3-24px-tilted", 3, 24, tilt=3.0)
