#!/usr/bin/env python3
"""Stages a household's notes on a throwaway chit-server, for store
screenshots: every kind of note (text, checklist with sub-items, pictures,
a voice memo, a link, reminders, labels, colors, pins, the archive), and a
second person a few notes are shared with.

    seed.py http://127.0.0.1:18131 OUT_DIR

The server must be fresh, with a superuser admin@example.com / adminpass123.
Writes OUT_DIR/session.json (what the app needs to be signed in as Shaun)
and OUT_DIR/angelica.json (her token and device, for presence).
Never point it at a real server.
"""
import io
import json
import math
import os
import random
import struct
import subprocess
import sys
import time
import urllib.request
import uuid
import wave
from datetime import datetime, timedelta, timezone

from PIL import Image, ImageDraw, ImageFilter, ImageFont

SERVER, OUT = sys.argv[1].rstrip('/'), sys.argv[2]
os.makedirs(OUT, exist_ok=True)
assert SERVER.startswith('http://127.0.0.1') or SERVER.startswith('http://localhost'), 'local servers only'

ALPHA = 'abcdefghijklmnopqrstuvwxyz0123456789'


def rid():
    return ''.join(random.choice(ALPHA) for _ in range(15))


def call(method, path, body=None, token=None, device=None, raw=None, ctype='application/json'):
    data = raw if raw is not None else (json.dumps(body).encode() if body is not None else None)
    req = urllib.request.Request(SERVER + path, data=data, method=method)
    if data is not None:
        req.add_header('Content-Type', ctype)
    if token:
        req.add_header('Authorization', token)
    if device:
        req.add_header('X-Chit-Device', device)
    with urllib.request.urlopen(req) as r:
        out = r.read()
        return json.loads(out) if out else None


class Person:
    def __init__(self, admin, email, name):
        call('POST', '/api/collections/users/records', {
            'email': email, 'name': name, 'password': 'testpass123',
            'passwordConfirm': 'testpass123', 'verified': True}, token=admin)
        auth = call('POST', '/api/collections/users/auth-with-password',
                    {'identity': email, 'password': 'testpass123'})
        self.token, self.record = auth['token'], auth['record']
        self.id, self.name, self.email = self.record['id'], name, email
        self.device = 'seed' + rid()[:6]
        self.counter = 0

    def hlc(self):
        self.counter += 1
        return f'{int(time.time() * 1000):013d}-{self.counter:04x}-{self.device}'

    def ops(self, *ops):
        body = {'device': self.device, 'ops': [
            {'collection': c, 'id': i, 'field': f, 'value': v, 'hlc': self.hlc()} for c, i, f, v in ops]}
        res = call('POST', '/api/chit/ops', body, self.token, self.device)
        bad = [r for r in res['results'] if not r.get('applied')]
        assert not bad, bad

    def attach(self, note, name, data, ctype):
        boundary = uuid.uuid4().hex
        aid = rid()
        parts = (f'--{boundary}\r\nContent-Disposition: form-data; name="id"\r\n\r\n{aid}\r\n'
                 f'--{boundary}\r\nContent-Disposition: form-data; name="file"; filename="{name}"\r\n'
                 f'Content-Type: {ctype}\r\n\r\n').encode() + data + f'\r\n--{boundary}--\r\n'.encode()
        call('POST', f'/api/chit/notes/{note}/attachments', raw=parts, token=self.token,
             device=self.device, ctype=f'multipart/form-data; boundary={boundary}')


admin = call('POST', '/api/collections/_superusers/auth-with-password',
             {'identity': 'admin@example.com', 'password': 'adminpass123'})['token']
shaun = Person(admin, 'shaun@example.com', 'Shaun')
angelica = Person(admin, 'angelica@example.com', 'Angelica')
angelo = Person(admin, 'angelo@example.com', 'Angelo')

# ---- labels ------------------------------------------------------------------

labels = {n: rid() for n in ['Home', 'Family', 'Ideas', 'Trips', 'Recipes']}
shaun.ops(*[('labels', i, 'name', n) for n, i in labels.items()])

# ---- pictures and sound, made here -------------------------------------------


def font(size, bold=False):
    for f in ['/usr/share/fonts/TTF/MartianGrotesk-VFVF.ttf', '/usr/share/fonts/TTF/DejaVuSans.ttf']:
        if os.path.exists(f):
            return ImageFont.truetype(f, size)
    return ImageFont.load_default()


def png(img):
    b = io.BytesIO()
    img.save(b, 'JPEG', quality=90)
    return b.getvalue()


def swatches():
    """Paint chips on a card, as if photographed on the workbench."""
    W, H = 1200, 900
    img = Image.new('RGB', (W, H), '#d9cdb8')
    d = ImageDraw.Draw(img)
    rng = random.Random(4)
    for _ in range(9000):  # wood grain
        x, y = rng.randrange(W), rng.randrange(H)
        d.line([(x, y), (x + rng.randrange(40, 160), y + rng.randrange(-2, 3))],
               fill=(196 + rng.randrange(-12, 10), 180 + rng.randrange(-12, 10), 152 + rng.randrange(-10, 10)))
    card = Image.new('RGB', (760, 640), '#f7f5f0')
    cd = ImageDraw.Draw(card)
    chips = [('Morning Fog', '#d7d9d3'), ('Sage Field', '#a7b49a'), ('Harbor Blue', '#4f6a80'),
             ('Barn Door', '#8c3b2e')]
    for i, (name, c) in enumerate(chips):
        y = 40 + i * 145
        cd.rounded_rectangle([40, y, 300, y + 120], 10, fill=c)
        cd.text((330, y + 30), name, fill='#2b2b2b', font=font(40))
        cd.text((330, y + 78), f'No. {412 + i * 37}  ·  satin', fill='#777', font=font(26))
    card = card.rotate(-4, expand=True, fillcolor='#d9cdb8')
    shadow = Image.new('RGBA', card.size, (0, 0, 0, 0))
    ImageDraw.Draw(shadow).rectangle([30, 30, card.size[0] - 10, card.size[1] - 10], fill=(0, 0, 0, 90))
    img.paste(shadow.filter(ImageFilter.GaussianBlur(18)), (200, 120), shadow.filter(ImageFilter.GaussianBlur(18)))
    img.paste(card, (190, 100))
    return png(img)


def garden():
    """A sketch of the raised beds, in pencil on graph paper."""
    W, H = 1200, 900
    img = Image.new('RGB', (W, H), '#fbfaf4')
    d = ImageDraw.Draw(img)
    for x in range(0, W, 40):
        d.line([(x, 0), (x, H)], fill='#dde8ef')
    for y in range(0, H, 40):
        d.line([(0, y), (W, y)], fill='#dde8ef')
    pencil = '#5a5a5a'
    beds = [((120, 140, 520, 340), 'Tomatoes'), ((640, 140, 1080, 340), 'Peppers + basil'),
            ((120, 480, 520, 760), 'Greens'), ((640, 480, 1080, 760), 'Squash')]
    rng = random.Random(7)
    for (x0, y0, x1, y1), name in beds:
        for k in range(2):
            j = lambda v: v + rng.randrange(-3, 4)
            d.line([(j(x0), j(y0)), (j(x1), j(y0)), (j(x1), j(y1)), (j(x0), j(y1)), (j(x0), j(y0))], fill=pencil, width=3)
        d.text((x0 + 24, y0 + 24), name, fill='#3d3d3d', font=font(42))
    d.text((120, 60), 'Back yard beds, spring', fill='#2f2f2f', font=font(48))
    d.text((120, 800), '4 ft paths  ·  drip line along the fence', fill='#6a6a6a', font=font(32))
    return png(img)


def memo():
    """Nine seconds of humming, as AAC in M4A (needs ffmpeg)."""
    rate, secs = 44100, 9
    frames = bytearray()
    notes = [220, 247, 262, 294, 262, 247, 220, 196, 220]
    for i in range(rate * secs):
        t = i / rate
        f = notes[min(int(t), len(notes) - 1)]
        env = 0.5 + 0.5 * math.sin(math.pi * (t % 1))
        v = 0.25 * env * (math.sin(2 * math.pi * f * t) + 0.3 * math.sin(4 * math.pi * f * t))
        frames += struct.pack('<h', int(v * 32767))
    wav = os.path.join(OUT, 'memo.wav')
    with wave.open(wav, 'wb') as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(bytes(frames))
    m4a = os.path.join(OUT, 'memo.m4a')
    subprocess.run(['ffmpeg', '-loglevel', 'error', '-y', '-i', wav, '-c:a', 'aac', '-b:a', '96k', m4a], check=True)
    return open(m4a, 'rb').read()

# ---- notes, oldest first (the board shows the newest on top) ----------------


def note(who, title, body='', kind='text', color='', items=(), pinned=False, archived=False,
         label_names=(), reminder=None):
    nid = rid()
    ops = [('notes', nid, 'kind', kind), ('notes', nid, 'title', title)]
    if body:
        ops.append(('notes', nid, 'body', body))
    if color:
        ops.append(('notes', nid, 'color', color))
    who.ops(*ops)
    order = 'V'
    item_ops = []
    for it in items:
        text, checked, indent = (it + (False, 0))[:3] if isinstance(it, tuple) else (it, False, 0)
        iid = rid()
        item_ops += [('items', iid, 'note', nid), ('items', iid, 'text', text), ('items', iid, 'order', order)]
        if checked:
            item_ops.append(('items', iid, 'checked', True))
        if indent:
            item_ops.append(('items', iid, 'indent', indent))
        order += 'V'
    if item_ops:
        who.ops(*item_ops)
    state = []
    if pinned:
        state.append(('note_state', nid, 'pinned', True))
    if archived:
        state.append(('note_state', nid, 'archived', True))
    if label_names:
        state.append(('note_state', nid, 'labels', [labels[n] for n in label_names]))
    if reminder:
        state.append(('note_state', nid, 'reminder', reminder.astimezone(timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')))
    if state:
        who.ops(*state)
    time.sleep(0.02)  # distinct creation times, for a stable board order
    return nid


def share(nid, person, role='editor'):
    call('POST', f'/api/chit/notes/{nid}/members', {'user': person.id, 'role': role}, shaun.token, shaun.device)


now = datetime.now().astimezone()
tue = (now + timedelta(days=(1 - now.weekday()) % 7 or 7)).replace(hour=9, minute=0, second=0, microsecond=0)
sat = (now + timedelta(days=(5 - now.weekday()) % 7 or 7)).replace(hour=10, minute=0, second=0, microsecond=0)
soon = (now + timedelta(days=1)).replace(hour=18, minute=0, second=0, microsecond=0)

# the archive: done with, kept
note(shaun, 'Thanksgiving', 'Turkey ordered from the farm. Pick up Wednesday after 3.', archived=True,
     label_names=['Family'])
note(shaun, 'Car registration', 'Renewed online, sticker in the glovebox.', archived=True)

memo_note = note(shaun, 'Song idea', 'Hummed it in the car. Chorus goes up on the last line.',
                 color='purple', label_names=['Ideas'])
shaun.attach(memo_note, f'Voice memo, {now:%b} {now.day} 18.42.m4a', memo(), 'audio/mp4')

note(shaun, 'Read later', 'https://m3.material.io/blog/building-with-m3-expressive', color='teal')

note(shaun, 'Lasagna', 'Noodles, ricotta, mozzarella, parmesan, marinara, spinach.\n\n'
     'Layer sauce, noodles, cheese, spinach. Three layers, cheese on top. 375 for 45 min covered, '
     '15 uncovered. Rest 15 before cutting.', color='orange', label_names=['Recipes'])

garden_note = note(shaun, 'Garden beds', 'Order soil by March. Drip line kit is in the garage.',
                   color='green', label_names=['Home'])
shaun.attach(garden_note, 'garden-beds.jpg', garden(), 'image/jpeg')

trip = note(shaun, 'Buffalo River trip', '', kind='list', color='blue', label_names=['Trips', 'Family'], items=[
    ('Book the cabin', True), 'Canoe rental for Saturday', 'Hot Springs on the way back',
    'Pack', ('Rain jackets', False, 1), ('Headlamps', False, 1), ('Fishing license', False, 1)])
share(trip, angelica)

note(shaun, 'Gift ideas', '', kind='list', color='pink', label_names=['Family'], items=[
    'Angelica: pottery class', 'Angelo: LEGO Technic set', 'Mom: framed print of the lake', ('Dad: new reel', True)])

note(shaun, 'Dentist', 'Cleaning for Angelo. Bring the insurance card.', color='yellow', reminder=tue)

paint = note(shaun, 'Paint the fence', 'Two coats. Sage Field on the fence, Harbor Blue on the gate.',
             label_names=['Home'], reminder=sat)
shaun.attach(paint, 'swatches.jpg', swatches(), 'image/jpeg')
share(paint, angelica)

saturday = note(shaun, 'Saturday', '', kind='list', items=[
    'Hardware store', ('Brushes', False, 1), ('Drop cloth', True, 1), 'Farmers market',
    'Pick up Angelo at 2', ('Return library books', True)], label_names=['Home'])
share(saturday, angelica)

note(shaun, 'Wifi for guests', 'Network: Lastra-Guest\nThe password is on the fridge.', color='gray', pinned=True,
     label_names=['Home'])

groceries = note(shaun, 'Groceries', '', kind='list', pinned=True, label_names=['Home'], items=[
    'Oat milk', 'Eggs', 'Sourdough', 'Bananas', 'Spinach', 'Parmesan', ('Coffee beans', True), ('Olive oil', True)])
share(groceries, angelica)
share(groceries, angelo, 'viewer')

note(shaun, 'Call the plumber', 'Kitchen sink drips. Ask about the water heater too.', reminder=soon)

json.dump({'server': SERVER, 'user': shaun.record, 'token': shaun.token, 'device': 'shotsdevice1'},
          open(os.path.join(OUT, 'session.json'), 'w'))
json.dump({'token': angelica.token, 'device': angelica.device, 'groceries': groceries, 'paint': paint},
          open(os.path.join(OUT, 'angelica.json'), 'w'))
print('seeded')
