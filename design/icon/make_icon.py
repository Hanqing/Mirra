#!/usr/bin/env python3
"""Generates the Mirra icon artwork: a dancer meeting their reflection at a glass mirror.

Outputs (next to this script):
  layers/*.svg        layers for the Icon Composer document (AppIcon.icon)
  preview_full.html   full-bleed square (what Icon Composer composes)
  preview_legacy.html squircle with shadow, for the .icns fallback and the website
Render the HTML files with headless Chrome (see build_icon.sh).
"""
import math
import os

HERE = os.path.dirname(os.path.abspath(__file__))
os.makedirs(os.path.join(HERE, "layers"), exist_ok=True)

BG_TOP, BG_MID, BG_BOTTOM = "#FFA25E", "#FF6A5C", "#E8336A"
MIRROR_X = 520  # the glass surface
PANEL = (MIRROR_X, 168, 872, 868, 64)  # x0, y0, x1, y1, radius

# The dancer, facing the mirror (to the right), in a hip-hop groove:
# leaning back, near arm reaching up to touch the glass, knees bent.
HEAD = (394, 284, 46)
# Torso outline: rounded shoulders, narrow waist, leaning back a touch.
TORSO_PATH = [("M", (354, 364)), ("C", (374, 350), (406, 352), (426, 372)),
              ("C", (420, 418), (404, 452), (402, 478)), ("C", (400, 500), (404, 518), (404, 534)),
              ("L", (350, 530)), ("C", (352, 504), (358, 484), (356, 464)),
              ("C", (352, 432), (344, 398), (354, 364))]
TORSO_ROUND = 16
ARMS = [
    ([(414, 386), (468, 318), (498, 238)], 40),  # front arm, fingertips at the glass
    ([(360, 392), (298, 452), (322, 520)], 40),  # back arm, fist at the hip
]
LEGS = [
    ([(390, 512), (458, 634), (440, 760), (484, 774)], 50),  # front leg
    ([(364, 514), (302, 638), (252, 742), (290, 764)], 50),  # back leg
]


def mirror_x(points):
    return [(2 * MIRROR_X - x, y) for x, y in points]


def dancer(color="#FFFFFF", reflect=False, opacity=1.0, extra=""):
    tx = (lambda pts: mirror_x(pts)) if reflect else (lambda pts: pts)
    hx, hy, hr = HEAD
    if reflect:
        hx = 2 * MIRROR_X - hx
    parts = []
    d = ""
    for cmd, *pts in TORSO_PATH:
        d += cmd + " ".join(f"{x},{y}" for x, y in tx(pts)) + " "
    d += "Z"
    parts.append(f'<path d="{d}" fill="{color}" stroke="{color}" stroke-width="{TORSO_ROUND}" stroke-linejoin="round"/>')
    for pts, w in ARMS + LEGS:
        pts = tx(pts)
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        parts.append(f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" '
                     f'stroke-linecap="round" stroke-linejoin="round"/>')
    parts.append(f'<circle cx="{hx}" cy="{hy}" r="{hr}" fill="{color}"/>')
    # Backwards cap: crown on the head, short brim behind.
    s = -1 if reflect else 1
    parts.append(f'<path d="M{hx - (hr + 4)},{hy - 6} A{hr + 4},{hr + 4} 0 0 1 {hx + hr + 4},{hy - 6} Z" fill="{color}"/>')
    parts.append(f'<path d="M{hx - s * (hr - 8)},{hy - 16} L{hx - s * (hr + 26)},{hy - 9}" stroke="{color}" '
                 f'stroke-width="18" stroke-linecap="round"/>')
    return f'<g opacity="{opacity}" {extra}>' + "".join(parts) + "</g>"


def rounded_rect(x0, y0, x1, y1, r):
    return (f"M{x0 + r},{y0} H{x1 - r} Q{x1},{y0} {x1},{y0 + r} V{y1 - r} Q{x1},{y1} {x1 - r},{y1} "
            f"H{x0 + r} Q{x0},{y1} {x0},{y1 - r} V{y0 + r} Q{x0},{y0} {x0 + r},{y0} Z")


def defs():
    x0, y0, x1, y1, r = PANEL
    return f"""
<defs>
  <linearGradient id="bg" x1="0.15" y1="0" x2="0.85" y2="1">
    <stop offset="0" stop-color="{BG_TOP}"/>
    <stop offset=".5" stop-color="{BG_MID}"/>
    <stop offset="1" stop-color="{BG_BOTTOM}"/>
  </linearGradient>
  <radialGradient id="glow" cx=".28" cy=".18" r=".7">
    <stop offset="0" stop-color="#fff" stop-opacity=".35"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="pane" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="#fff" stop-opacity=".42"/>
    <stop offset=".55" stop-color="#fff" stop-opacity=".16"/>
    <stop offset="1" stop-color="#fff" stop-opacity=".26"/>
  </linearGradient>
  <linearGradient id="sheen" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#fff" stop-opacity="0"/>
    <stop offset=".5" stop-color="#fff" stop-opacity=".55"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </linearGradient>
  <linearGradient id="figure" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#FFFFFF"/>
    <stop offset="1" stop-color="#FFF1EA"/>
  </linearGradient>
  <clipPath id="paneClip"><path d="{rounded_rect(x0, y0, x1, y1, r)}"/></clipPath>
  <filter id="blur6" x="-20%" y="-20%" width="140%" height="140%"><feGaussianBlur stdDeviation="2.5"/></filter>
  <filter id="soft" x="-50%" y="-50%" width="200%" height="200%"><feGaussianBlur stdDeviation="18"/></filter>
  <filter id="figShadow" x="-20%" y="-20%" width="140%" height="140%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="14"/>
    <feComponentTransfer><feFuncA type="linear" slope=".22"/></feComponentTransfer>
    <feFlood flood-color="#7A0F2A"/><feComposite in2="SourceGraphic" operator="in"/>
    <feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
</defs>"""


def background():
    return '<rect width="1024" height="1024" fill="url(#bg)"/><rect width="1024" height="1024" fill="url(#glow)"/>'


def floor():
    # Soft contact shadows for the dancer and the reflection.
    return ('<ellipse cx="368" cy="784" rx="150" ry="16" fill="#6E0A26" opacity=".24" filter="url(#soft)"/>'
            f'<ellipse cx="{2 * MIRROR_X - 368}" cy="784" rx="130" ry="13" fill="#6E0A26" opacity=".12" filter="url(#soft)"/>')


def reflection():
    # The reflection sits behind the glass: softer, slightly blurred.
    return (f'<g clip-path="url(#paneClip)">'
            f'{dancer(color="#FFFFFF", reflect=True, opacity=.66, extra=chr(32) + "filter=" + chr(34) + "url(#blur6)" + chr(34))}'
            f'</g>')


def pane():
    x0, y0, x1, y1, r = PANEL
    shape = rounded_rect(x0, y0, x1, y1, r)
    return (f'<path d="{shape}" fill="url(#pane)"/>'
            f'<g clip-path="url(#paneClip)">'
            f'<rect x="560" y="-300" width="64" height="1600" fill="url(#sheen)" opacity=".45" transform="rotate(24 700 520)"/>'
            f'<rect x="650" y="-300" width="22" height="1600" fill="url(#sheen)" opacity=".35" transform="rotate(24 700 520)"/>'
            f'</g>'
            f'<path d="{shape}" fill="none" stroke="#fff" stroke-opacity=".75" stroke-width="4"/>'
            f'<path d="{rounded_rect(x0 + 10, y0 + 10, x1 - 10, y1 - 10, r - 10)}" fill="none" stroke="#fff" stroke-opacity=".22" stroke-width="2"/>')


def figure():
    return f'<g filter="url(#figShadow)">{dancer(color="url(#figure)")}</g>'


def svg(content, size=1024):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" viewBox="0 0 1024 1024">'
            f'{defs()}{content}</svg>')


SHIFT = -26  # centres the dancer + mirror group
SCALE = 1.06
GROUP = f"translate(512 512) scale({SCALE}) translate(-512 -512) translate({SHIFT} 0)"


def full_art():
    return background() + f'<g transform="{GROUP}">' + floor() + reflection() + pane() + figure() + "</g>"


def superellipse(cx, cy, a, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        pts.append(f"{cx + a * math.copysign(abs(c) ** (2 / n), c):.2f},"
                   f"{cy + a * math.copysign(abs(s) ** (2 / n), s):.2f}")
    return "M" + " L".join(pts) + " Z"


def legacy_art():
    # macOS icon grid: an 824pt squircle centred on a 1024 canvas, with a soft drop shadow.
    shape = superellipse(512, 512, 412)
    return (f'<defs><clipPath id="sq"><path d="{shape}"/></clipPath>'
            f'<filter id="drop" x="-20%" y="-20%" width="140%" height="140%">'
            f'<feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/>'
            f'<feComponentTransfer><feFuncA type="linear" slope=".28"/></feComponentTransfer>'
            f'<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>'
            f'<g filter="url(#drop)"><g clip-path="url(#sq)">'
            f'<g transform="translate(100 100) scale({824 / 1024})">{full_art()}</g>'
            f'<path d="{shape}" fill="none" stroke="#fff" stroke-opacity=".22" stroke-width="3"/>'
            f'</g></g>')


def page(markup):
    return ("<!doctype html><html><head><style>html,body{margin:0;background:transparent}"
            "svg{display:block}</style></head><body>" + markup + "</body></html>")


def write(name, text):
    with open(os.path.join(HERE, name), "w") as f:
        f.write(text)


write("preview_full.html", page(svg(full_art())))
write("preview_legacy.html", page(svg(legacy_art())))

# Icon Composer layers; the background gradient lives in icon.json.
def shifted(markup):
    return f'<g transform="{GROUP}">{markup}</g>'


write("layers/floor.svg", svg(shifted(floor())))
write("layers/reflection.svg", svg(shifted(f'<g clip-path="url(#paneClip)">{dancer(reflect=True, opacity=.7)}</g>')))
write("layers/pane.svg", svg(shifted(pane())))
write("layers/dancer.svg", svg(shifted(dancer())))
print("ok")
