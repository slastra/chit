#!/usr/bin/env python3
"""Frames raw app captures as store screenshots and draws the feature
graphic, in chit's type (Martian Grotesk) and its brand pair.

    compose.py RAW_DIR OUT_DIR

RAW_DIR holds 1080x2400 phone captures (raw-*.png, taken by the harness
on a seed.py server) and raw-wide.png (2560x1600). Writes Play's phone
screenshots (1080x1920, 9:16, inside Play's 2:1 limit), the 1024x500
feature graphic, and the README's images.
"""
import io
import subprocess
import sys
from pathlib import Path

from PIL import Image, ImageDraw, ImageFilter, ImageFont

RAW, OUT = Path(sys.argv[1]), Path(sys.argv[2])
OUT.mkdir(parents=True, exist_ok=True)
APP = Path(__file__).resolve().parents[2] / 'app'
FONT = '/usr/share/fonts/TTF/MartianGrotesk-VFVF.ttf'

# chit's brand pair (tool/brand.py): primary container and its text
GREEN, INK = '#c8ef9d', '#314f0f'
PAPER = '#f4f8ec'


def font(size, style='Std Md'):
    f = ImageFont.truetype(FONT, size)
    f.set_variation_by_name(style)
    return f


def mark(size, color):
    """The chit mark alone, at size px, in color."""
    png = subprocess.run(['rsvg-convert', '-w', str(size), '-h', str(size), str(APP / 'assets/brand/chit-full.svg')],
                         capture_output=True, check=True).stdout
    alpha = Image.open(io.BytesIO(png)).convert('RGBA').getchannel('A')
    out = Image.new('RGBA', alpha.size, color)
    out.putalpha(alpha)
    return out


def rounded(img, r):
    m = Image.new('L', img.size, 0)
    ImageDraw.Draw(m).rounded_rectangle([0, 0, img.size[0] - 1, img.size[1] - 1], r, fill=255)
    out = img.convert('RGBA')
    out.putalpha(m)
    return out


def shadow(size, r, blur, alpha=60):
    s = Image.new('RGBA', (size[0] + blur * 4, size[1] + blur * 4), (0, 0, 0, 0))
    ImageDraw.Draw(s).rounded_rectangle([blur * 2, blur * 2, blur * 2 + size[0], blur * 2 + size[1]], r,
                                        fill=(20, 40, 0, alpha))
    return s.filter(ImageFilter.GaussianBlur(blur))


def phone(raw, height, crop_to=None):
    """A capture in a thin rounded device outline, scaled to height."""
    img = Image.open(raw).convert('RGB')
    if crop_to:
        img = img.crop((0, 0, img.width, crop_to))
    w = round(img.width * height / img.height)
    img = img.resize((w, height), Image.LANCZOS)
    bezel = max(10, w // 45)
    r = w // 11
    body = Image.new('RGBA', (w + bezel * 2, height + bezel * 2), (0, 0, 0, 0))
    ImageDraw.Draw(body).rounded_rectangle([0, 0, body.width - 1, body.height - 1], r + bezel, fill='#1d2117')
    body.alpha_composite(rounded(img, r), (bezel, bezel))
    return body


def wrap(draw, text, f, width):
    lines, line = [], ''
    for word in text.split():
        t = (line + ' ' + word).strip()
        if draw.textlength(t, font=f) <= width:
            line = t
        else:
            lines.append(line)
            line = word
    return lines + [line]


SHOTS = [
    ('raw-board.png', 'Every kind of note', 'Text, checklists, pictures and voice memos on one board.'),
    ('raw-list.png', 'Shared, live', 'See who is in a list as they type. Edits merge, nothing is lost.'),
    ('raw-trip.png', 'Lists that nest', 'Sub-items, drag to reorder, checked items fold away.'),
    ('raw-paint.png', 'Pictures, reminders', 'Snap it, add a time, and the reminder finds you.'),
    ('raw-player.png', 'Voice memos', 'Record in the note, play back at your speed.'),
    ('raw-dark.png', 'Day or night', 'Material You on Android, your theme on the desktop.'),
]


def screenshot(i, raw, title, sub):
    W, H = 1080, 1920
    canvas = Image.new('RGBA', (W, H), GREEN if i % 2 == 0 else PAPER)
    d = ImageDraw.Draw(canvas)
    head, body = font(72, 'Std Bd'), font(38, 'Std Rg')
    y = 120
    for line in wrap(d, title, head, W - 160):
        d.text((W // 2, y), line, font=head, fill=INK, anchor='ma')
        y += 92
    y += 14
    for line in wrap(d, sub, body, W - 200):
        d.text((W // 2, y), line, font=body, fill='#41542c', anchor='ma')
        y += 54
    assert y <= 380, (raw, y)  # one title line, two lines under it
    top = 440  # every phone at the same height, whatever the caption
    ph = phone(RAW / raw, 2400 * 2 // 3)  # the device runs off the foot
    x = (W - ph.width) // 2
    sh = shadow(ph.size, ph.width // 10, 24)
    canvas.alpha_composite(sh, (x - 48, top - 40))
    canvas.alpha_composite(ph, (x, top))
    out = OUT / f'play-{i + 1:02d}-{raw[4:-4]}.png'
    canvas.convert('RGB').save(out, optimize=True)
    return out


def feature():
    W, H = 1024, 500
    g = Image.new('RGBA', (W, H), GREEN)
    d = ImageDraw.Draw(g)
    m = mark(132, INK)
    g.alpha_composite(m, (64, 120))
    d.text((64, 276), 'chit', font=font(96, 'Std Bd'), fill=INK)
    d.text((66, 396), 'Notes and lists for the', font=font(28, 'Std Rg'), fill='#41542c')
    d.text((66, 432), 'people you live with', font=font(28, 'Std Rg'), fill='#41542c')
    # two phones, leaning in from the right, cut by the edge
    for raw, x, y, angle in [('raw-dark.png', 560, 60, 8), ('raw-board.png', 735, 30, -6)]:
        ph = phone(RAW / raw, 1000).rotate(angle, resample=Image.BICUBIC, expand=True)
        sh = shadow(ph.size, 60, 18, 50).rotate(0)
        g.alpha_composite(sh, (x - 36, y - 20)) if False else None
        g.alpha_composite(ph, (x, y))
    out = OUT / 'feature-graphic.png'
    g.convert('RGB').save(out, optimize=True)
    return out


def readme():
    """The README's strip: three phones side by side, and the desktop."""
    picks = ['raw-board.png', 'raw-list.png', 'raw-dark.png']
    phs = [phone(RAW / p, 1200) for p in picks]
    gap = 48
    W = sum(p.width for p in phs) + gap * (len(phs) + 1)
    strip = Image.new('RGBA', (W, phs[0].height + gap * 2), (0, 0, 0, 0))
    x = gap
    for p in phs:
        strip.alpha_composite(p, (x, gap))
        x += p.width + gap
    strip.save(OUT / 'readme-phones.png', optimize=True)
    wide = Image.open(RAW / 'raw-wide.png').convert('RGB').resize((1600, 1000), Image.LANCZOS)
    rounded(wide, 24).save(OUT / 'readme-desktop.png', optimize=True)


for i, (raw, title, sub) in enumerate(SHOTS):
    print(screenshot(i, raw, title, sub))
print(feature())
readme()
print('readme images')
