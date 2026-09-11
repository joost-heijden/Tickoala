#!/usr/bin/env python3
"""Genereert de icoonvarianten voor Tickoala als SVG.

Alle varianten delen dezelfde koala-geometrie, zodat de vergelijking echt over
stijl en kleur gaat en niet over toevallige vormverschillen.
"""
import pathlib

S = 512           # canvasgrootte
R = 114           # hoekradius van de app-icoon-achtergrond

# Gedeelde koala-geometrie
EAR_L, EAR_R, EAR_Y, EAR_OUT, EAR_IN = 138, 374, 196, 74, 46
HEAD_CX, HEAD_CY, HEAD_RX, HEAD_RY = 256, 288, 124, 118
EYE_L, EYE_R, EYE_Y = 198, 314, 262
NOSE = "M 256 244 C 308 244, 334 270, 334 306 C 334 350, 298 384, 256 384 C 214 384, 178 350, 178 306 C 178 270, 204 244, 256 244 Z"


def bg(fill, rounded=True):
    if not rounded:
        return f'<rect width="{S}" height="{S}" fill="{fill}"/>'
    return f'<rect width="{S}" height="{S}" rx="{R}" ry="{R}" fill="{fill}"/>'


def ears(fur, inner):
    return f"""
  <circle cx="{EAR_L}" cy="{EAR_Y}" r="{EAR_OUT}" fill="{fur}"/>
  <circle cx="{EAR_R}" cy="{EAR_Y}" r="{EAR_OUT}" fill="{fur}"/>
  <circle cx="{EAR_L}" cy="{EAR_Y}" r="{EAR_IN}" fill="{inner}"/>
  <circle cx="{EAR_R}" cy="{EAR_Y}" r="{EAR_IN}" fill="{inner}"/>"""


def head(fur):
    return f'  <ellipse cx="{HEAD_CX}" cy="{HEAD_CY}" rx="{HEAD_RX}" ry="{HEAD_RY}" fill="{fur}"/>'


def eyes_open(colour, r=15):
    return f"""
  <circle cx="{EYE_L}" cy="{EYE_Y}" r="{r}" fill="{colour}"/>
  <circle cx="{EYE_R}" cy="{EYE_Y}" r="{r}" fill="{colour}"/>"""


def eyes_closed(colour, w=6):
    return f"""
  <path d="M {EYE_L-22} {EYE_Y+4} q 22 -22 44 0" fill="none" stroke="{colour}"
        stroke-width="{w}" stroke-linecap="round"/>
  <path d="M {EYE_R-22} {EYE_Y+4} q 22 -22 44 0" fill="none" stroke="{colour}"
        stroke-width="{w}" stroke-linecap="round"/>"""


def nose(colour):
    return f'  <path d="{NOSE}" fill="{colour}"/>'


def wrap(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{S}" height="{S}" '
            f'viewBox="0 0 {S} {S}">\n{body}\n</svg>\n')


variants = {}

# 1. Flat & friendly — de klassieke lezing, warme achtergrond
variants["1-flat"] = wrap(
    bg("#E9A23B")
    + ears("#9AA3AD", "#C9CFD6")
    + head("#9AA3AD")
    + eyes_open("#2C3038")
    + nose("#2C3038")
)

# 2. Klokneus — de neus is de wijzerplaat, met uurstreepjes rond de kop
ticks = "".join(
    f'<rect x="254" y="{y}" width="4" height="14" rx="2" fill="#ffffff" opacity="0.55" '
    f'transform="rotate({a} 256 288)"/>'
    for a, y in [(0, 150), (90, 150), (180, 150), (270, 150)]
)
variants["2-klok"] = wrap(
    bg("#2F6F4E")
    + ticks
    + ears("#A8B0B8", "#CDD3D9")
    + head("#A8B0B8")
    + eyes_open("#22262C")
    + nose("#22262C")
    + """
  <circle cx="256" cy="312" r="6" fill="#F2C14E"/>
  <rect x="253" y="272" width="6" height="44" rx="3" fill="#F2C14E"/>
  <rect x="253" y="300" width="6" height="34" rx="3" fill="#F2C14E"
        transform="rotate(115 256 312)"/>"""
)

# 3. Monoline — alleen lijnen, licht en modern
LINE = "#33405A"
variants["3-monoline"] = wrap(
    bg("#F4F1E8")
    + f"""
  <circle cx="{EAR_L}" cy="{EAR_Y}" r="{EAR_OUT}" fill="none" stroke="{LINE}" stroke-width="14"/>
  <circle cx="{EAR_R}" cy="{EAR_Y}" r="{EAR_OUT}" fill="none" stroke="{LINE}" stroke-width="14"/>
  <circle cx="{EAR_L}" cy="{EAR_Y}" r="{EAR_IN-8}" fill="none" stroke="{LINE}" stroke-width="10" opacity="0.5"/>
  <circle cx="{EAR_R}" cy="{EAR_Y}" r="{EAR_IN-8}" fill="none" stroke="{LINE}" stroke-width="10" opacity="0.5"/>
  <ellipse cx="{HEAD_CX}" cy="{HEAD_CY}" rx="{HEAD_RX}" ry="{HEAD_RY}" fill="#F4F1E8" stroke="{LINE}" stroke-width="14"/>
  <path d="{NOSE}" fill="none" stroke="{LINE}" stroke-width="14"/>"""
    + eyes_open(LINE, r=13)
)

# 4. Slaapkop — ogen dicht, knipoog naar de koala die 20 uur per dag slaapt
variants["4-slaapkop"] = wrap(
    bg("#3B4C6B")
    + ears("#B9C0C7", "#D8DDE2")
    + head("#B9C0C7")
    + eyes_closed("#2A2F36")
    + nose("#2A2F36")
    + """
  <text x="392" y="150" font-family="Helvetica,Arial,sans-serif" font-size="52"
        font-weight="700" fill="#F2C14E">z</text>
  <text x="436" y="106" font-family="Helvetica,Arial,sans-serif" font-size="34"
        font-weight="700" fill="#F2C14E" opacity="0.75">z</text>"""
)

# 5. Geometrisch — strak, hoog contrast, houdt stand op klein formaat
variants["5-geometrisch"] = wrap(
    bg("#1F2933")
    + ears("#F2C14E", "#1F2933")
    + head("#F2C14E")
    + eyes_open("#1F2933", r=17)
    + nose("#1F2933")
)

# 6. Silhouet — één kleur, werkt ook als sjabloon voor de menubalk
SIL = "#FFFFFF"
variants["6-silhouet"] = wrap(
    bg("#6C7A89")
    + f"""
  <g fill="{SIL}">
    <circle cx="{EAR_L}" cy="{EAR_Y}" r="{EAR_OUT}"/>
    <circle cx="{EAR_R}" cy="{EAR_Y}" r="{EAR_OUT}"/>
    <ellipse cx="{HEAD_CX}" cy="{HEAD_CY}" rx="{HEAD_RX}" ry="{HEAD_RY}"/>
  </g>
  <g fill="#6C7A89">
    <circle cx="{EAR_L}" cy="{EAR_Y}" r="{EAR_IN-10}"/>
    <circle cx="{EAR_R}" cy="{EAR_Y}" r="{EAR_IN-10}"/>
    <circle cx="{EYE_L}" cy="{EYE_Y}" r="15"/>
    <circle cx="{EYE_R}" cy="{EYE_Y}" r="15"/>
    <path d="{NOSE}"/>
  </g>"""
)

for name, svg in variants.items():
    pathlib.Path(f"{name}.svg").write_text(svg)
    print("geschreven:", name + ".svg")
