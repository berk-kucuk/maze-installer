#!/usr/bin/env python3
"""Maze Linux installer icon — writes maze-installer.svg next to this script.

OLED, in the Maze app-icon family (Maze Guard, Store, Vault, Ghost): a black
tile with the family's corner radius and soft centre glow, white strokes, and
one "lit" silver element carrying a black sign. Here the lit element is the
core of the Maze mark itself: the mark exactly as maze-branding draws it
(maze-linux-mark.svg), centred, scaled up and with heavier walls so it carries
the same visual weight as its siblings in a dock, and its core square lit and
showing the install sign — an arrow into a tray.

Render the PNG sizes with rsvg-convert (see README in this directory).
"""
import os

MAZE = ("M212.00 212.00h600.00v35.64h-600.00zM212.00 775.82h600.00v36.18h-600.00zM212.00 212.00h35.64v600.00h-35.64z"
        "M775.82 212.00h36.18v600.00h-36.18zM385.36 385.36h252.21v35.10h-252.21zM385.36 602.46h252.21v35.10h-252.21z"
        "M385.36 385.36h35.10v252.21h-35.10zM602.46 385.36h35.10v252.21h-35.10zM493.37 247.64h36.18v137.71h-36.18z"
        "M493.37 689.41h36.18v86.41h-36.18zM298.95 298.95h144.19v35.10h-144.19zM298.95 298.95h35.10v230.60h-35.10z"
        "M298.95 494.45h86.41v35.10h-86.41zM580.32 298.95h144.19v35.10h-144.19zM689.41 298.95h35.10v145.81h-35.10z"
        "M689.41 494.45h86.41v35.10h-86.41zM689.41 494.45h35.10v230.06h-35.10zM580.32 689.41h144.19v35.10h-144.19z"
        "M247.64 580.32h86.41v35.64h-86.41zM298.95 580.32h35.10v144.19h-35.10zM298.95 689.41h144.19v35.10h-144.19z")

# Sizing, tuned beside the sibling icons in a dock: the mark at its own
# proportions looked a size smaller and fainter than their bold glyphs.
SCALE = 1.12          # mark size around the tile centre
WALL = 8              # extra wall thickness (in mark units, before SCALE)
CORE_X, CORE_Y, CORE = 385.36, 385.36, 252.21   # the mark's core square
CX, CY, K, SIGN_W = 512, 504, 92, 34            # install sign: centre, size, stroke

SVG = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">
  <defs>
    <radialGradient id="glow" cx="512" cy="512" r="360" gradientUnits="userSpaceOnUse">
      <stop offset="0" stop-color="#fff" stop-opacity="0.40"/>
      <stop offset="0.45" stop-color="#fff" stop-opacity="0.08"/>
      <stop offset="1" stop-color="#fff" stop-opacity="0"/>
    </radialGradient>
    <linearGradient id="lit" x1="0" y1="0" x2="0" y2="1">
      <stop offset="0" stop-color="#ffffff"/>
      <stop offset="1" stop-color="#cfcfd8"/>
    </linearGradient>
  </defs>
  <rect width="1024" height="1024" rx="220" fill="#000"/>
  <circle cx="512" cy="512" r="360" fill="url(#glow)"/>
  <g transform="translate(512 512) scale({SCALE}) translate(-512 -512)">
    <path fill="#f2f2f4" stroke="#f2f2f4" stroke-width="{WALL}" d="{MAZE}"/>
    <rect x="{CORE_X}" y="{CORE_Y}" width="{CORE}" height="{CORE}" fill="url(#lit)" stroke="#f2f2f4" stroke-width="{WALL}"/>
  </g>
  <g fill="none" stroke="#000" stroke-width="{SIGN_W}" stroke-linecap="butt" stroke-linejoin="miter">
    <path d="M{CX} {CY - K} V{CY + K * 0.42:.0f}"/>
    <path d="M{CX - K * 0.62:.0f} {CY - K * 0.2:.0f} L{CX} {CY + K * 0.42:.0f} L{CX + K * 0.62:.0f} {CY - K * 0.2:.0f}"/>
    <path d="M{CX - K * 0.78:.0f} {CY + K * 0.98:.0f} H{CX + K * 0.78:.0f}"/>
  </g>
</svg>
'''

out = os.path.join(os.path.dirname(os.path.abspath(__file__)), "maze-installer.svg")
with open(out, "w") as f:
    f.write(SVG)
print(out)
