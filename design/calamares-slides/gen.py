#!/usr/bin/env python3
"""Maze Linux Calamares slideshow generator — writes slide-NN.svg (1600x960)."""
import base64, os, sys

OUT = os.path.dirname(os.path.abspath(__file__))
BRAND = sys.argv[1]  # dir with maze-logo.png / maze-simple-logo.png
W, H = 1600, 960
TOTAL = 7

def b64(name):
    with open(os.path.join(BRAND, name), "rb") as f:
        return base64.b64encode(f.read()).decode()

LOGO = b64("maze-logo.png")
MARK = b64("maze-simple-logo.png")

FONT = "Inter, 'Inter Display', 'DejaVu Sans', sans-serif"
MONO = "'JetBrains Mono', 'DejaVu Sans Mono', monospace"
FG = "#f4f4f5"
DIM = "#9d9da8"
LINE = "#e9e9ee"

DEFS = f"""
<defs>
  <radialGradient id="bloom" cx="0.72" cy="0.55" r="0.55">
    <stop offset="0" stop-color="#262629" stop-opacity="0.85"/>
    <stop offset="1" stop-color="#0a0a0b" stop-opacity="0"/>
  </radialGradient>
  <radialGradient id="halo" cx="0.5" cy="0.5" r="0.5">
    <stop offset="0" stop-color="#ffffff" stop-opacity="0.10"/>
    <stop offset="1" stop-color="#ffffff" stop-opacity="0"/>
  </radialGradient>
  <linearGradient id="silver" x1="0" y1="0" x2="0" y2="1">
    <stop offset="0" stop-color="#ffffff"/>
    <stop offset="1" stop-color="#b9b9c0"/>
  </linearGradient>
  <filter id="glow" x="-30%" y="-30%" width="160%" height="160%">
    <feGaussianBlur stdDeviation="7" result="b"/>
    <feMerge><feMergeNode in="b"/><feMergeNode in="SourceGraphic"/></feMerge>
  </filter>
</defs>"""

def background():
    # True black, a soft bloom, and the Maze mark embossed very faintly in a
    # corner — the same idea as the default wallpaper.
    return f"""
<rect width="{W}" height="{H}" fill="#0a0a0b"/>
<rect width="{W}" height="{H}" fill="url(#bloom)"/>
<image href="data:image/png;base64,{MARK}" x="1180" y="-190" width="620" height="620" opacity="0.045"/>
<image href="data:image/png;base64,{MARK}" x="-260" y="600" width="560" height="560" opacity="0.035"/>"""

def footer(n):
    dots = "".join(
        f'<rect x="{1330 + i*30}" y="872" width="{18 if i == n-1 else 8}" height="8" rx="4" '
        f'fill="{FG if i == n-1 else "#3a3a40"}"/>' for i in range(TOTAL))
    return f"""
<image href="data:image/png;base64,{MARK}" x="96" y="858" width="36" height="36" opacity="0.9"/>
<text x="148" y="884" font-family="{FONT}" font-size="22" font-weight="600" letter-spacing="5" fill="{DIM}">MAZE LINUX</text>
{dots}"""

def text_block(kicker, title_lines, body_lines, x=790, y=330):
    out = [f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="22" font-weight="600" '
           f'letter-spacing="4" fill="{DIM}">{kicker}</text>']
    ty = y + 78
    for t in title_lines:
        out.append(f'<text x="{x}" y="{ty}" font-family="{FONT}" font-size="58" font-weight="700" '
                   f'fill="url(#silver)">{t}</text>')
        ty += 74
    by = ty + 26
    for b in body_lines:
        out.append(f'<rect x="{x}" y="{by-15}" width="12" height="12" fill="none" stroke="{LINE}" stroke-width="2.5"/>')
        out.append(f'<text x="{x+34}" y="{by}" font-family="{FONT}" font-size="29" fill="{DIM}">{b}</text>')
        by += 54
    return "\n".join(out)

def art(inner, cx=420, cy=470):
    return f"""
<circle cx="{cx}" cy="{cy}" r="300" fill="url(#halo)"/>
<g transform="translate({cx},{cy})" fill="none" stroke="{LINE}" stroke-width="5"
   stroke-linecap="round" stroke-linejoin="round" filter="url(#glow)">{inner}</g>"""

def svg(body):
    return (f'<svg xmlns="http://www.w3.org/2000/svg" width="{W}" height="{H}" '
            f'viewBox="0 0 {W} {H}">{DEFS}{background()}{body}</svg>')

slides = []

# 1 — welcome
slides.append(f"""
<circle cx="800" cy="400" r="340" fill="url(#halo)"/>
<image href="data:image/png;base64,{LOGO}" x="565" y="170" width="470" height="262"/>
<text x="800" y="545" text-anchor="middle" font-family="{FONT}" font-size="58" font-weight="700" fill="url(#silver)">Welcome to Maze Linux</text>
<text x="800" y="605" text-anchor="middle" font-family="{FONT}" font-size="29" fill="{DIM}">A private, secure and AI-native desktop.</text>
<text x="800" y="650" text-anchor="middle" font-family="{FONT}" font-size="29" fill="{DIM}">Sit back — the installation takes a few minutes.</text>
{footer(1)}""")

# 2 — secure boot chain
shield = """
<path d="M0,-210 L170,-150 L170,10 C170,120 90,185 0,225 C-90,185 -170,120 -170,10 L-170,-150 Z"/>
<rect x="-70" y="-60" width="140" height="140" rx="6"/>
<path d="M-70,-10 H-40 V40 H40 V-10"/>
<circle cx="0" cy="5" r="14"/><path d="M0,19 V40"/>"""
slides.append(art(shield) + text_block(
    "SECURE BY DEFAULT", ["Protected from", "the first instruction"],
    ["Secure Boot with a key unique to your PC",
     "Full-disk encryption (LUKS2)",
     "AppArmor and a firewall, on out of the box"]) + footer(2))

# 3 — network control
net = """
<rect x="-55" y="-55" width="110" height="110" rx="10"/>
<rect x="-22" y="-22" width="44" height="44" rx="4"/>
<circle cx="-190" cy="-150" r="34"/><circle cx="190" cy="-150" r="34"/>
<circle cx="-190" cy="150" r="34"/><circle cx="190" cy="150" r="34"/>
<path d="M-160,-126 L-55,-40"/><path d="M160,-126 L55,-40"/><path d="M-160,126 L-55,40"/>
<path d="M160,126 L55,40" stroke-dasharray="4 16"/>
<path d="M92,68 L128,104 M128,68 L92,104" stroke-width="7"/>"""
slides.append(art(net) + text_block(
    "YOUR NETWORK, YOUR RULES", ["Every connection", "under your control"],
    ["Maze Guard spots attacks on public Wi-Fi",
     "Maze Cloak randomizes your MAC address",
     "Kill switches for camera, microphone, radios"]) + footer(3))

# 4 — Tor
onion = """
<circle r="210"/><circle r="150" stroke-opacity="0.8"/><circle r="92" stroke-opacity="0.6"/>
<circle r="16" fill="#e9e9ee"/>
<path d="M-300,-40 C-200,-40 -150,40 -60,20" stroke-dasharray="2 14"/>
<path d="M60,-20 C150,-40 200,40 300,40" stroke-dasharray="2 14"/>"""
slides.append(art(onion) + text_block(
    "ANONYMOUS BY DESIGN", ["Private conversations,", "private files"],
    ["Haze: encrypted peer-to-peer chat over Tor",
     "HazeDrop: anonymous encrypted file transfer",
     "Entropy Shield: Tor, DNSCrypt and I2P"]) + footer(4))

# 5 — local AI
chip = "".join(
    f'<path d="M{p},-150 V-190"/><path d="M{p},150 V190"/><path d="M-150,{p} H-190"/><path d="M150,{p} H190"/>'
    for p in (-90, -30, 30, 90))
chip = f"""
<rect x="-150" y="-150" width="300" height="300" rx="26"/>
<rect x="-92" y="-92" width="184" height="184" rx="10" stroke-opacity="0.8"/>
{chip}
<text x="0" y="24" text-anchor="middle" font-family="{FONT}" font-size="72" font-weight="700"
      fill="#e9e9ee" stroke="none">AI</text>"""
slides.append(art(chip) + text_block(
    "AI THAT STAYS HOME", ["Your AI,", "on your machine"],
    ["Maze AI runs local models with Ollama",
     "By default, nothing leaves your computer",
     "Every risky action asks you first"]) + footer(5))

# 6 — snapshots / rollback
snap = """
<path d="M-230,60 H230"/>
<circle cx="-180" cy="60" r="20"/><circle cx="-60" cy="60" r="20"/>
<circle cx="60" cy="60" r="20"/><circle cx="180" cy="60" r="26" fill="#e9e9ee"/>
<path d="M180,20 C180,-130 -60,-130 -60,20" stroke-dasharray="1 0"/>
<path d="M-84,-8 L-60,22 L-36,-8"/>
<text x="-60" y="140" text-anchor="middle" font-family="'DejaVu Sans', sans-serif" font-size="26"
      fill="#9d9da8" stroke="none">before update</text>"""
slides.append(art(snap) + text_block(
    "SAFETY NET", ["Broke something?", "Just go back."],
    ["A snapshot before every update",
     "Roll back with one command: maze-rollback",
     "A recovery kernel in the boot menu"]) + footer(6))

# 7 — updates / tools
term = f"""
<rect x="-230" y="-160" width="460" height="320" rx="18"/>
<path d="M-230,-104 H230"/>
<circle cx="-196" cy="-132" r="7"/><circle cx="-168" cy="-132" r="7"/><circle cx="-140" cy="-132" r="7"/>
<text x="-196" y="-36" font-family="{MONO}" font-size="30" fill="#e9e9ee" stroke="none">$ sudo pacman -Syu</text>
<text x="-196" y="16" font-family="{MONO}" font-size="30" fill="#9d9da8" stroke="none">$ maze-doctor</text>
<path d="M-196,70 L-176,92 L-138,52" stroke-width="6"/>
<text x="-118" y="84" font-family="{MONO}" font-size="26" fill="#9d9da8" stroke="none">all good</text>"""
slides.append(art(term) + text_block(
    "ALWAYS UP TO DATE", ["Rolling, signed,", "and checked"],
    ["Updates are signed by Maze and Arch Linux",
     "Maze Control Center for everyday settings",
     "maze-doctor tells you if anything is wrong"]) + footer(7))

for i, body in enumerate(slides, 1):
    with open(os.path.join(OUT, f"slide-{i:02d}.svg"), "w") as f:
        f.write(svg(body))
print(f"{len(slides)} slides")
