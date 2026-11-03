#!/usr/bin/env python3
"""Generates the DisplayCam icon artwork.

Outputs (next to this script):
  layers/*.svg        layers for the Icon Composer document (AppIcon.icon)
  preview_full.html   full-bleed square (what Icon Composer composes)
  preview_legacy.html squircle with shadow, for the .icns fallback / website
Render the HTML files with headless Chrome (see build_icon.sh).
"""
import math, os

HERE = os.path.dirname(os.path.abspath(__file__))
os.makedirs(os.path.join(HERE, "layers"), exist_ok=True)

# Palette
BG_TOP, BG_BOTTOM = "#FFFFFF", "#E7E6E2"
MIRROR_TOP, MIRROR_BOTTOM = "#FF9A3C", "#FF3D5E"
FRAME_TOP, FRAME_BOTTOM = "#FFB066", "#E8304F"

# Geometry (1024 canvas)
CX = 512
AX0, AX1 = 286, 738          # arch left/right
ATOP, ABOT = 128, 900        # arch top/bottom
R = (AX1 - AX0) / 2          # top radius
INSET = 30                   # frame width


def arch(x0, x1, top, bottom, corner):
    r = (x1 - x0) / 2
    cy = top + r
    return (f"M{x0},{cy} A{r},{r} 0 0 1 {x1},{cy} "
            f"V{bottom - corner} Q{x1},{bottom} {x1 - corner},{bottom} "
            f"H{x0 + corner} Q{x0},{bottom} {x0},{bottom - corner} Z")


OUTER = arch(AX0, AX1, ATOP, ABOT, 56)
INNER = arch(AX0 + INSET, AX1 - INSET, ATOP + INSET, ABOT - INSET, 30)

# Dancer: hip-hop pose, thick round strokes.
HEAD = (492, 300, 50)
LIMBS = [
    [(500, 372), (522, 552)],                       # torso, leaning back a little
    [(502, 410), (424, 466), (462, 536)],           # left arm, fist on the hip
    [(506, 408), (598, 372), (640, 270)],           # right arm, pointing up
    [(522, 552), (446, 640), (420, 760)],           # left leg, knee bent
    [(522, 552), (604, 652), (628, 760)],           # right leg, knee bent
    [(420, 762), (376, 770)],                       # left sneaker
    [(628, 762), (674, 770)],                       # right sneaker
]
STROKE = 52


def dancer(color="#FFFFFF", opacity=1.0, extra=""):
    paths = "".join(
        f'<path d="M{" L".join(f"{x},{y}" for x, y in pts)}" />' for pts in LIMBS)
    x, y, r = HEAD
    # Backwards snapback: crown over the head, brim sticking out behind.
    cap = (f'<path d="M{x - r - 4},{y - 6} A{r + 4},{r + 4} 0 0 1 {x + r + 4},{y - 6} Z" fill="{color}"/>'
           f'<path d="M{x - r + 6},{y - 16} L{x - r - 40},{y - 4}" stroke="{color}" stroke-width="22" stroke-linecap="round"/>')
    return (f'<g opacity="{opacity}" {extra}>'
            f'<g fill="none" stroke="{color}" stroke-width="{STROKE}" stroke-linecap="round" '
            f'stroke-linejoin="round">{paths}</g>'
            f'<circle cx="{x}" cy="{y}" r="{r}" fill="{color}"/>{cap}</g>')


def defs():
    return f"""
<defs>
  <linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">
    <stop offset="0" stop-color="{BG_TOP}"/><stop offset="1" stop-color="{BG_BOTTOM}"/>
  </linearGradient>
  <linearGradient id="frame" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="{FRAME_TOP}"/><stop offset="1" stop-color="{FRAME_BOTTOM}"/>
  </linearGradient>
  <linearGradient id="mirror" x1="0.2" y1="0" x2="0.8" y2="1">
    <stop offset="0" stop-color="{MIRROR_TOP}"/><stop offset="1" stop-color="{MIRROR_BOTTOM}"/>
  </linearGradient>
  <linearGradient id="streak" x1="0" y1="0" x2="1" y2="0">
    <stop offset="0" stop-color="#fff" stop-opacity="0"/>
    <stop offset=".5" stop-color="#fff" stop-opacity=".9"/>
    <stop offset="1" stop-color="#fff" stop-opacity="0"/>
  </linearGradient>
  <radialGradient id="lens" cx=".38" cy=".35" r=".75">
    <stop offset="0" stop-color="#3A4A66"/><stop offset=".55" stop-color="#121722"/><stop offset="1" stop-color="#05070B"/>
  </radialGradient>
  <clipPath id="innerClip"><path d="{INNER}"/></clipPath>
  <filter id="soft" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur stdDeviation="22"/>
  </filter>
  <filter id="deboss" x="-10%" y="-10%" width="120%" height="120%">
    <feGaussianBlur in="SourceAlpha" stdDeviation="2.5" result="b"/>
    <feOffset dx="0" dy="3" result="o"/>
    <feComposite in="o" in2="SourceAlpha" operator="out" result="shadowOut"/>
    <feFlood flood-color="#fff" flood-opacity=".9"/>
    <feComposite in2="shadowOut" operator="in" result="hi"/>
    <feOffset in="SourceAlpha" dx="0" dy="-2" result="o2"/>
    <feGaussianBlur in="o2" stdDeviation="2" result="b2"/>
    <feComposite in="SourceGraphic" in2="SourceGraphic"/>
    <feMerge><feMergeNode in="SourceGraphic"/><feMergeNode in="hi"/></feMerge>
  </filter>
</defs>"""


def floor_waves():
    # Embossed beat waves on the floor, echoing the reference's soft relief style.
    out = []
    for y, amp in [(892, 22), (956, 18)]:
        d = f"M-20,{y} C200,{y - amp * 2} 340,{y + amp * 2} 512,{y} S820,{y - amp * 2} 1044,{y}"
        # A carved groove: white lip below, soft shade inside.
        out.append(f'<path d="{d}" transform="translate(0 4)" fill="none" stroke="#FFFFFF" stroke-width="20" stroke-linecap="round"/>')
        out.append(f'<path d="{d}" fill="none" stroke="#DCDBD6" stroke-width="18" stroke-linecap="round"/>')
        out.append(f'<path d="{d}" transform="translate(0 -3)" fill="none" stroke="#C9C8C2" stroke-width="8" stroke-linecap="round" opacity=".55"/>')
    return "".join(out)


def mirror_body():
    # Frame, glass, and a thin bevel highlight along the top of the frame.
    return (f'<path d="{OUTER}" fill="url(#frame)"/>'
            f'<path d="{INNER}" fill="url(#mirror)"/>'
            f'<path d="{arch(AX0 + 6, AX1 - 6, ATOP + 6, ABOT - 6, 50)}" fill="none" stroke="#fff" '
            f'stroke-opacity=".35" stroke-width="4"/>')


def mirror_glass():
    # Inner shine + classic diagonal mirror streaks, clipped to the glass.
    return (f'<g clip-path="url(#innerClip)">'
            f'<path d="{INNER}" fill="#fff" opacity=".10"/>'
            f'<rect x="300" y="-200" width="70" height="1500" fill="url(#streak)" opacity=".38" transform="rotate(32 512 512)"/>'
            f'<rect x="392" y="-200" width="26" height="1500" fill="url(#streak)" opacity=".30" transform="rotate(32 512 512)"/>'
            f'<ellipse cx="524" cy="790" rx="150" ry="14" fill="#8A1830" opacity=".14" filter="url(#soft)"/>'
            f'</g>')


def lens():
    x, y = CX, ATOP + 64
    return (f'<circle cx="{x}" cy="{y}" r="34" fill="#FFF3EA" opacity=".9"/>'
            f'<circle cx="{x}" cy="{y}" r="26" fill="url(#lens)"/>'
            f'<circle cx="{x - 8}" cy="{y - 8}" r="7" fill="#9FC2FF" opacity=".85"/>'
            f'<circle cx="{x + 9}" cy="{y + 9}" r="3" fill="#fff" opacity=".5"/>')


def shadow_under_mirror():
    return (f'<ellipse cx="{CX}" cy="{ABOT + 6}" rx="250" ry="34" fill="#5A1420" opacity=".28" filter="url(#soft)"/>')


def svg(content, size=1024, extra=""):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{size}" height="{size}" '
            f'viewBox="0 0 1024 1024" {extra}>{defs()}{content}</svg>')


def full_art():
    return (f'<rect width="1024" height="1024" fill="url(#bg)"/>' + floor_waves() + shadow_under_mirror()
            + mirror_body() + mirror_glass() + dancer() + lens())


def superellipse(cx, cy, a, n=5.0, steps=720):
    pts = []
    for i in range(steps):
        t = 2 * math.pi * i / steps
        c, s = math.cos(t), math.sin(t)
        x = cx + a * math.copysign(abs(c) ** (2 / n), c)
        y = cy + a * math.copysign(abs(s) ** (2 / n), s)
        pts.append(f"{x:.2f},{y:.2f}")
    return "M" + " L".join(pts) + " Z"


def legacy_art():
    # macOS icon grid: 824pt body centred on a 1024 canvas, with a soft drop shadow.
    shape = superellipse(512, 512, 412)
    return (f'<defs><clipPath id="sq"><path d="{shape}"/></clipPath>'
            f'<filter id="drop" x="-20%" y="-20%" width="140%" height="140%">'
            f'<feGaussianBlur in="SourceAlpha" stdDeviation="14"/><feOffset dy="12"/>'
            f'<feComponentTransfer><feFuncA type="linear" slope=".30"/></feComponentTransfer>'
            f'<feMerge><feMergeNode/><feMergeNode in="SourceGraphic"/></feMerge></filter></defs>'
            f'<g filter="url(#drop)"><g clip-path="url(#sq)">'
            f'<g transform="translate(100 100) scale({824/1024})">{full_art()}</g>'
            f'<path d="{shape}" fill="none" stroke="#000" stroke-opacity=".08" stroke-width="2"/>'
            f'</g></g>')


def page(svg_markup):
    return ("<!doctype html><html><head><style>html,body{margin:0;background:transparent}"
            "svg{display:block}</style></head><body>" + svg_markup + "</body></html>")


def write(name, text):
    with open(os.path.join(HERE, name), "w") as f:
        f.write(text)


write("preview_full.html", page(svg(full_art())))
write("preview_legacy.html", page(svg(legacy_art())))
write("icon_legacy.svg", svg(legacy_art()))

# Icon Composer layers (background comes from icon.json's fill).
write("layers/waves.svg", svg(floor_waves()))
write("layers/mirror.svg", svg(shadow_under_mirror() + mirror_body()))
write("layers/glass.svg", svg(mirror_glass()))
write("layers/dancer.svg", svg(dancer()))
write("layers/lens.svg", svg(lens()))
print("ok")
