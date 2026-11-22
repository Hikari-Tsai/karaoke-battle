#!/usr/bin/env python3
"""Builds the profile avatar SVGs: seven looks x (full | head) x (clear | badge).

Mascot style: a thick plum outline, flat colour, a wide bean of a head, dot
eyes, the microphone held in both hands. Drawn in a 200 x 200 space, as plain
SVG (flat fills, two gradients for the stage, clip paths; no filters or masks)
so flutter_svg can draw it too.

    python3 build_avatars.py <out dir>     # writes <out dir>/svg/<variant>/<look>.svg
"""
import math
import os
import sys

OUT = sys.argv[1] if len(sys.argv) > 1 else 'out'

KINDS = ['female', 'male', 'neutral', 'cat', 'dog', 'rabbit', 'bear']
HUMAN = {'female', 'male', 'neutral'}
INK = '#3B2140'
SKIN, SKIN_D = '#FFE3CF', '#F6C5AB'

LOOKS = {
    'female': dict(body=SKIN, hair='#7A428A', hair_d='#5A2E69', hair_l='#A064B0', top='#FF7AB8', top_d='#E0559A', iris='#C77BE0', accent='#FFD60A', note='#64D2FF'),
    'male': dict(body=SKIN, hair='#3D4877', hair_d='#272E50', hair_l='#6474B0', top='#5AB0FF', top_d='#3A8CE6', iris='#6FB0FF', accent='#64D2FF', note='#64D2FF'),
    'neutral': dict(body=SKIN, hair='#94592F', hair_d='#6E4022', hair_l='#BC8250', top='#5AD6B4', top_d='#36B692', iris='#4CCBA6', accent='#30D158', note='#FF4FA3'),
    'cat': dict(body='#FFB36B', fur_d='#EE8F3A', fur_l='#FFE4C4', top='#B88CFF', top_d='#9366E8', iris='#5FCB7A', accent='#BF5AF2', note='#FF4FA3'),
    'dog': dict(body='#FBE3C0', fur_d='#B97A45', fur_l='#FFF6E8', top='#FF7A6A', top_d='#E0554A', iris='#C98A52', accent='#FF9F0A', note='#64D2FF'),
    'rabbit': dict(body='#F8F4FC', fur_d='#DDD3EC', fur_l='#FFFFFF', top='#7FD8FF', top_d='#4FB8E8', iris='#F0668E', accent='#64D2FF', note='#FF4FA3'),
    'bear': dict(body='#B87A48', fur_d='#8E5A30', fur_l='#EBC79C', top='#FFD45A', top_d='#E8B030', iris='#D69A60', accent='#FFD60A', note='#64D2FF'),
}

HEAD = 'M100,33 C142,33 160,56 160,86 C160,118 136,135 100,135 C64,135 40,118 40,86 C40,56 58,33 100,33 Z'

# Hair: what hangs behind the head, and the fringe over the forehead.
FEMALE_BACK = 'M100,16 C146,16 170,48 168,92 C167,118 174,138 180,154 C183,164 170,172 160,166 C155,175 140,174 137,164 L63,164 C60,174 45,175 40,166 C30,172 17,164 20,154 C26,138 33,118 32,92 C30,48 54,16 100,16 Z'
FEMALE_BACK_HEAD = 'M100,16 C146,16 170,48 168,92 C167,110 171,124 175,136 C178,146 166,153 157,147 C153,156 140,155 138,146 L62,146 C60,155 47,156 43,147 C34,153 22,146 25,136 C29,124 33,110 32,92 C30,48 54,16 100,16 Z'
FEMALE_FRINGE = ('M33,98 C28,46 54,16 100,16 C146,16 172,46 167,98 C167,108 162,116 155,122 C155,102 151,84 143,71 '
                 'C134,80 119,84 104,82 C108,76 109,70 108,63 C96,76 75,84 57,82 C50,93 46,106 45,122 C38,116 33,108 33,98 Z')
MALE_FRINGE = ('M34,98 C27,46 54,15 100,15 C146,15 173,46 166,98 L158,108 C157,96 154,86 150,77 '
               'C148,81 144,84 139,86 C138,79 135,72 130,66 C128,74 123,80 116,84 C114,77 111,70 106,63 '
               'C104,73 99,80 91,84 C89,77 85,70 80,65 C78,73 73,81 65,86 C63,81 60,77 56,73 C50,84 45,96 42,108 Z')
MALE_TUFT = 'M95,18 C96,9 105,3 116,4 C110,8 108,13 110,18 Z'
NEUTRAL_BACK = 'M100,16 C146,16 172,46 170,96 C170,116 166,132 158,142 L42,142 C34,132 30,116 30,96 C28,46 54,16 100,16 Z'
NEUTRAL_FRINGE = ('M30,100 C26,46 54,16 100,16 C146,16 174,46 170,100 C170,116 166,130 158,142 C158,116 154,92 146,74 '
                  'C126,84 96,82 78,63 C72,75 60,82 50,84 C46,98 43,118 42,142 C34,130 30,116 30,100 Z')


def star(cx, cy, r, ri=0.5):
    pts = []
    for i in range(10):
        rr = r if i % 2 == 0 else r * ri
        a = math.radians(-90 + i * 36)
        pts.append(f'{cx + rr * math.cos(a):.1f},{cy + rr * math.sin(a):.1f}')
    return 'M' + ' L'.join(pts) + ' Z'


def sparkle(cx, cy, r):
    s = r * 0.22
    return (f'M{cx},{cy - r} Q{cx + s},{cy - s} {cx + r},{cy} Q{cx + s},{cy + s} {cx},{cy + r} '
            f'Q{cx - s},{cy + s} {cx - r},{cy} Q{cx - s},{cy - s} {cx},{cy - r} Z')


class Art:
    def __init__(self, kind, mode):
        self.k = kind
        self.l = LOOKS[kind]
        self.mode = mode
        self.pre = f'{kind}-{mode}'
        self.defs = []
        self.out = []
        self.n = 0

    def add(self, s):
        self.out.append(s)

    def clip(self, inner):
        self.n += 1
        i = f'{self.pre}-c{self.n}'
        self.defs.append(f'<clipPath id="{i}">{inner}</clipPath>')
        return f'clip-path="url(#{i})"'

    def st(self, w=3.4):
        return f'stroke="{INK}" stroke-width="{w}" stroke-linejoin="round" stroke-linecap="round"'

    def limb(self, d, color, w=11):
        """A stubby arm or tail: a round-capped stroke with an outline."""
        self.add(f'<path d="{d}" fill="none" stroke="{INK}" stroke-width="{w + 6.8}" stroke-linecap="round" stroke-linejoin="round"/>'
                 f'<path d="{d}" fill="none" stroke="{color}" stroke-width="{w}" stroke-linecap="round" stroke-linejoin="round"/>')

    # Face ------------------------------------------------------------------
    def eye(self, x, y):
        iris = self.l['iris']
        self.add(f'<ellipse cx="{x}" cy="{y}" rx="6.6" ry="8.8" fill="{INK}"/>'
                 f'<path d="M{x - 5},{y + 3.4} C{x - 3},{y + 8} {x + 3},{y + 8} {x + 5},{y + 3.4} C{x + 2},{y + 5.4} {x - 2},{y + 5.4} {x - 5},{y + 3.4} Z" fill="{iris}"/>'
                 f'<circle cx="{x - 2}" cy="{y - 3.4}" r="2.9" fill="#FFFFFF"/><circle cx="{x + 2.4}" cy="{y + 1.2}" r="1.2" fill="#FFFFFF"/>')
        if self.k == 'female':
            s = -1 if x < 100 else 1
            self.add(f'<path d="M{x + s * 6},{y - 4.6} L{x + s * 10.4},{y - 6.6} M{x + s * 6.6},{y - 0.6} L{x + s * 11},{y - 1}" stroke="{INK}" stroke-width="2.2" stroke-linecap="round"/>')

    def eyes(self, y):
        self.eye(74, y)
        self.eye(126, y)

    def blush(self, x, y, c='#FF9DB0'):
        self.add(f'<ellipse cx="{100 - x}" cy="{y}" rx="8.5" ry="5.4" fill="{c}" opacity="0.85"/><ellipse cx="{100 + x}" cy="{y}" rx="8.5" ry="5.4" fill="{c}" opacity="0.85"/>')

    def mouth(self, y, teeth=False):
        d = f'M91,{y - 4} Q100,{y - 6} 109,{y - 4} Q109,{y + 8} 100,{y + 8} Q91,{y + 8} 91,{y - 4} Z'
        c = self.clip(f'<path d="{d}"/>')
        inner = f'<ellipse cx="100" cy="{y + 7}" rx="6" ry="4" fill="#FF8FA3"/>'
        if teeth:
            inner += (f'<rect x="95" y="{y - 7}" width="10" height="7.4" rx="1.6" fill="#FFFFFF" stroke="{INK}" stroke-width="1.6"/>'
                      f'<line x1="100" y1="{y - 5}" x2="100" y2="{y + 0.4}" stroke="{INK}" stroke-width="1.4"/>')
        self.add(f'<path d="{d}" fill="#A82848"/><g {c}>{inner}</g><path d="{d}" fill="none" {self.st(2.8)}/>')

    def snout(self, y, color):
        """A dog's or bear's nose."""
        self.add(f'<path d="M92.4,{y} Q100,{y - 3} 107.6,{y} Q106.6,{y + 8} 100,{y + 8.4} Q93.4,{y + 8} 92.4,{y} Z" fill="{color}" stroke="{INK}" stroke-width="2" stroke-linejoin="round"/>'
                 f'<ellipse cx="97.4" cy="{y + 1.6}" rx="2.4" ry="1.3" fill="#FFFFFF" opacity="0.75"/>')

    def pink_nose(self, y):
        self.add(f'<path d="M95.6,{y} Q100,{y - 1.4} 104.4,{y} Q103.6,{y + 4.8} 100,{y + 5} Q96.4,{y + 4.8} 95.6,{y} Z" fill="#FF7A9A" stroke="{INK}" stroke-width="2" stroke-linejoin="round"/>')

    def whiskers(self):
        self.add(f'<path d="M48,108 L27,103 M48,115 L28,119 M152,108 L173,103 M152,115 L172,119" stroke="{INK}" stroke-width="2.2" stroke-linecap="round"/>')

    def head_base(self, markings=''):
        c = self.clip(f'<path d="{HEAD}"/>')
        self.add(f'<path d="{HEAD}" fill="{self.l["body"]}"/>')
        if markings:
            self.add(f'<g {c}>{markings}</g>')
        self.add(f'<path d="{HEAD}" fill="none" {self.st()}/>')

    # Looks -----------------------------------------------------------------
    def behind(self):
        """What sits behind the body: long hair, a tail."""
        l, k = self.l, self.k
        if k == 'female':
            self.add(f'<path d="{FEMALE_BACK if self.mode == "full" else FEMALE_BACK_HEAD}" fill="{l["hair_d"]}" {self.st()}/>')
        elif k == 'neutral':
            self.add(f'<path d="{NEUTRAL_BACK}" fill="{l["hair_d"]}" {self.st()}/>')
        if self.mode != 'full':
            return
        if k == 'cat':
            self.limb('M130,192 C162,196 178,172 164,150', l['body'])
            self.add(f'<path d="M171,160 L160,157 M173,170 L162,170" stroke="{l["fur_d"]}" stroke-width="4" stroke-linecap="round"/>')
        elif k == 'dog':
            self.limb('M134,188 C150,186 160,176 160,164', l['fur_d'], 10)

    def hair(self):
        l, k = self.l, self.k
        if k == 'female':
            self.add(f'<path d="{FEMALE_FRINGE}" fill="{l["hair"]}" {self.st()}/>')
            self.add(f'<path d="M56,40 C68,28 92,22 112,24 C96,30 78,36 64,50 C60,52 54,46 56,40 Z" fill="{l["hair_l"]}"/>')
            self.add(f'<path d="{star(141, 56, 10)}" fill="{l["accent"]}" {self.st(2.6)}/>')
        elif k == 'male':
            self.add(f'<path d="{MALE_TUFT}" fill="{l["hair"]}" {self.st()}/>')
            self.add(f'<path d="{MALE_FRINGE}" fill="{l["hair"]}" {self.st()}/>')
            self.add(f'<path d="M54,42 C66,29 88,22 108,24 C94,30 76,36 62,50 C58,52 52,48 54,42 Z" fill="{l["hair_l"]}"/>')
        elif k == 'neutral':
            self.add(f'<path d="{NEUTRAL_FRINGE}" fill="{l["hair"]}" {self.st()}/>')
            self.add(f'<path d="M112,24 C128,26 142,34 150,48 C152,54 146,58 142,54 C134,42 124,34 110,30 Z" fill="{l["hair_l"]}"/>')
            self.add(f'<rect x="50" y="71" width="19" height="6.4" rx="3.2" transform="rotate(-24 59.5 74)" fill="{l["accent"]}" {self.st(2.4)}/>')

    def head(self):
        l, k = self.l, self.k
        if k in HUMAN:
            fringe = {'female': FEMALE_FRINGE, 'male': MALE_FRINGE, 'neutral': NEUTRAL_FRINGE}[k]
            # The fringe's shadow on the forehead.
            self.head_base(f'<path d="{fringe}" transform="translate(0,6)" fill="{SKIN_D}" opacity="0.75"/>')
            self.hair()
            self.blush(42, 111)
            self.eyes(100)
            self.mouth(112)
        elif k == 'cat':
            for sx in (-1, 1):
                x = lambda v: 100 + sx * v
                self.add(f'<path d="M{x(52)},56 C{x(54)},36 {x(52)},22 {x(46)},12 C{x(32)},16 {x(18)},26 {x(12)},42 Z" fill="{l["body"]}" {self.st()}/>')
                self.add(f'<path d="M{x(44)},46 C{x(46)},36 {x(45)},28 {x(42)},22 C{x(34)},25 {x(26)},32 {x(22)},42 Z" fill="#FF9DB0"/>')
            self.head_base(f'<ellipse cx="100" cy="122" rx="34" ry="24" fill="{l["fur_l"]}"/>'
                           f'<path d="M100,30 L100,52 M84,32 L86,48 M116,32 L114,48" stroke="{l["fur_d"]}" stroke-width="6" stroke-linecap="round"/>'
                           f'<path d="M40,84 L52,86 M40,96 L50,96 M160,84 L148,86 M160,96 L150,96" stroke="{l["fur_d"]}" stroke-width="5" stroke-linecap="round"/>')
            self.blush(40, 112, '#FF8FA3')
            self.eyes(98)
            self.pink_nose(103.6)
            self.mouth(114)
            self.whiskers()
        elif k == 'dog':
            self.head_base(f'<ellipse cx="129" cy="96" rx="19" ry="21" fill="#E0A870"/>'
                           f'<ellipse cx="100" cy="120" rx="27" ry="21" fill="{l["fur_l"]}"/>')
            # A tuft on top.
            self.add(f'<path d="M91,36 C91,29 97,26 100,30 C103,25 110,28 109,36" fill="{l["body"]}" {self.st()}/>')
            self.blush(41, 113, '#FF9DB0')
            self.eyes(98)
            self.snout(102, INK)
            self.mouth(116.4)
            # Floppy ears, hanging over the sides of the head.
            for sx in (-1, 1):
                x = lambda v: 100 + sx * v
                self.add(f'<path d="M{x(42)},40 C{x(60)},32 {x(82)},48 {x(83)},78 C{x(84)},100 {x(74)},118 {x(60)},118 C{x(48)},118 {x(45)},102 {x(45)},86 C{x(45)},70 {x(41)},56 {x(34)},46 Z" fill="{l["fur_d"]}" {self.st()}/>')
                self.add(f'<path d="M{x(62)},56 C{x(70)},66 {x(72)},82 {x(68)},98" fill="none" stroke="#D49A62" stroke-width="5" stroke-linecap="round"/>')
        elif k == 'rabbit':
            for sx in (-1, 1):
                self.add(f'<g transform="translate({100 + sx * 24},46) rotate({sx * 13})">'
                         f'<path d="M-13,6 C-17,-18 -13,-44 0,-56 C13,-44 17,-18 13,6 Z" fill="{l["body"]}" {self.st()}/>'
                         f'<path d="M-6,-2 C-8.6,-18 -6,-34 0,-44 C6,-34 8.6,-18 6,-2 Z" fill="#FF9DB0"/></g>')
            self.head_base()
            # A bow at the foot of one ear.
            bx, by, bc = 133, 42, '#FF7AB8'
            self.add(f'<path d="M{bx},{by} C{bx - 14},{by - 12} {bx - 16},{by + 8} {bx},{by} C{bx + 14},{by - 13} {bx + 18},{by + 6} {bx},{by} Z" fill="{bc}" {self.st(2.6)}/>'
                     f'<circle cx="{bx}" cy="{by}" r="3.6" fill="#FFB3D6" {self.st(2.2)}/>')
            self.blush(40, 112, '#FF9DB0')
            self.eyes(98)
            self.pink_nose(103.6)
            self.mouth(114, teeth=True)
            self.whiskers()
        elif k == 'bear':
            for x in (56, 144):
                self.add(f'<circle cx="{x}" cy="44" r="18" fill="{l["body"]}" {self.st()}/><circle cx="{x}" cy="45" r="9" fill="{l["fur_l"]}"/>')
            self.head_base(f'<ellipse cx="100" cy="120" rx="27" ry="21" fill="{l["fur_l"]}"/>')
            self.blush(41, 113, '#FF8FA3')
            self.eyes(98)
            self.snout(102, INK)
            self.mouth(116.4)

    def body(self):
        l, k = self.l, self.k
        top, top_d = l['top'], l['top_d']
        if k in ('male', 'cat'):
            # The hood, behind the neck.
            self.add(f'<path d="M63,148 C63,130 137,130 137,148 C126,156 74,156 63,148 Z" fill="{top_d}" {self.st()}/>')
        self.add(f'<path d="M72,138 L128,138 C136,160 140,182 142,206 L58,206 C60,182 64,160 72,138 Z" fill="{top}" {self.st()}/>')
        self.add(f'<path d="M124,150 C130,168 134,186 136,206 L142,206 C140,182 136,160 128,138 Z" fill="{top_d}"/>')
        # Collars and little motifs.
        if k in ('female', 'rabbit'):
            for sx in (-1, 1):
                x = lambda v: 100 + sx * v
                self.add(f'<path d="M{x(28)},139 L{x(4)},139 C{x(6)},149 {x(18)},152 {x(27)},146 Z" fill="#FFFFFF" {self.st(2.6)}/>')
        elif k == 'neutral':
            self.add(f'<path d="M73,137 L127,137 L129,146 C110,150 90,150 71,146 Z" fill="#A8EDD8" {self.st(2.6)}/>')
        elif k in ('male', 'cat'):
            self.add('<path d="M86,140 L85,150 M114,140 L115,150" stroke="#FFFFFF" stroke-width="3" stroke-linecap="round"/>')
        elif k == 'dog':
            self.add(f'<path d="M73,137 L127,137 L128.6,144 C110,148 90,148 71.4,144 Z" fill="#E03C3C" {self.st(2.6)}/>')
        elif k == 'bear':
            self.add(f'<path d="M73,137 L127,137 L129,146 C110,150 90,150 71,146 Z" fill="#E8504A" {self.st(2.6)}/>')
        mx, my = (79, 188) if k != 'rabbit' else (80, 178)
        if k == 'female':
            self.add(f'<path d="M{mx},{my + 5} C{mx - 9},{my - 1} {mx - 5},{my - 8} {mx},{my - 3} C{mx + 5},{my - 8} {mx + 9},{my - 1} {mx},{my + 5} Z" fill="#FFFFFF" opacity="0.9"/>')
        elif k == 'male':
            self.add(f'<path d="M{mx + 2},{my - 9} L{mx - 5},{my + 1} L{mx - 0.5},{my + 1} L{mx - 2.5},{my + 9} L{mx + 5},{my - 2} L{mx + 0.5},{my - 2} Z" fill="#FFFFFF" opacity="0.9"/>')
        elif k == 'neutral':
            self.add(f'<path d="{star(mx, my, 7)}" fill="#FFFFFF" opacity="0.9"/>')
        elif k == 'cat':
            self.add(f'<g fill="#FFFFFF" opacity="0.9"><ellipse cx="{mx}" cy="{my + 2}" rx="5" ry="4"/>'
                     + ''.join(f'<circle cx="{mx + dx}" cy="{my + dy}" r="1.9"/>' for dx, dy in ((-5.4, -3.4), (-1.9, -6.4), (1.9, -6.4), (5.4, -3.4))) + '</g>')
        elif k == 'dog':
            self.add(f'<g transform="translate({mx},{my}) rotate(-20)" fill="#FFFFFF" opacity="0.9"><rect x="-6" y="-1.8" width="12" height="3.6"/>'
                     '<circle cx="-6.4" cy="-2.2" r="2.6"/><circle cx="-6.4" cy="2.2" r="2.6"/><circle cx="6.4" cy="-2.2" r="2.6"/><circle cx="6.4" cy="2.2" r="2.6"/></g>')
        elif k == 'rabbit':
            self.add(f'<g transform="translate({mx},{my}) rotate(35)"><path d="M-3.6,-4 L3.6,-4 L0,9 Z" fill="#FF9F0A" stroke="#FF9F0A" stroke-width="2" stroke-linejoin="round"/>'
                     '<path d="M0,-5 L-3,-10 M0,-5 L0,-11 M0,-5 L3,-10" stroke="#30D158" stroke-width="2.2" stroke-linecap="round"/></g>')
        elif k == 'bear':
            self.add(f'<path d="M{mx},{my - 8} C{mx + 3},{my - 3} {mx + 6},{my} {mx + 6},{my + 3} C{mx + 6},{my + 8} {mx - 6},{my + 8} {mx - 6},{my + 3} C{mx - 6},{my} {mx - 3},{my - 3} {mx},{my - 8} Z" fill="#FF9F0A"/>'
                     f'<circle cx="{mx - 2}" cy="{my + 2.4}" r="1.6" fill="#FFFFFF" opacity="0.85"/>')
        # Sleeves.
        self.limb('M74,150 Q70,163 87,162', top)
        self.limb('M126,148 Q130,161 112,160', top)

    def extras_over_body(self):
        """Things on the neck that sit over the collar, beside the microphone."""
        if self.k == 'dog':
            self.add(f'<circle cx="83" cy="150.4" r="6" fill="#FFD60A" {self.st(2.4)}/><circle cx="81.4" cy="148.8" r="1.7" fill="#FFFFFF" opacity="0.9"/>')
        elif self.k == 'bear':
            self.add(f'<path d="M124,143 L135,158 L121,157 Z" fill="#E8504A" {self.st(2.6)}/>')

    def microphone(self):
        """Held in both hands, just under the chin."""
        l = self.l
        hand = l['body']
        self.add('<g transform="rotate(-7 100 150)">'
                 f'<rect x="95.4" y="140" width="9.2" height="40" rx="3" fill="#4A4658" {self.st()}/>'
                 f'<rect x="95.4" y="146" width="9.2" height="5" fill="{l["accent"]}" stroke="{INK}" stroke-width="2"/>'
                 f'<circle cx="100" cy="133" r="10.5" fill="#C9C9D6" {self.st()}/>'
                 f'<path d="M93,130 Q100,126 107,130 M92.4,135.6 Q100,132 107.6,135.6" fill="none" stroke="{INK}" stroke-width="1.4" opacity="0.45"/>'
                 '<circle cx="96.4" cy="128.6" r="2.4" fill="#FFFFFF"/></g>'
                 f'<circle cx="89.5" cy="161" r="8.4" fill="{hand}" {self.st()}/><circle cx="109.5" cy="159" r="8.4" fill="{hand}" {self.st()}/>'
                 '<circle cx="87.4" cy="158.6" r="2.2" fill="#FFFFFF" opacity="0.7"/><circle cx="107.4" cy="156.6" r="2.2" fill="#FFFFFF" opacity="0.7"/>')

    def note(self, x, y, sc, color, rot=-10):
        self.add(f'<g transform="translate({x},{y}) rotate({rot}) scale({sc})" fill="{color}" stroke="{INK}" stroke-width="1.6" stroke-linejoin="round">'
                 '<path d="M1.2,-17 L1.2,-0.5 C1.2,3.4 -7,4.4 -7.6,0.6 C-8,-2.6 -3.6,-4 -1.2,-2.6 L-1.2,-20 C5,-19 9,-15 7.4,-8 C6.6,-12 4.6,-14.6 1.2,-15.4 Z"/></g>')


def frame(kind, mode, badge):
    """The square each variant shows: (centre x, centre y, half side).

    A head on its own shows all of it; in a badge it is cropped closer.
    """
    if mode == 'full':
        return 100, 100, 100
    if badge:
        return {'rabbit': (100, 68, 78), 'cat': (100, 82, 72), 'bear': (100, 82, 72)}.get(kind, (100, 84, 72))
    return {'rabbit': (100, 62, 80), 'dog': (100, 80, 88), 'cat': (100, 76, 80), 'bear': (100, 80, 76)}.get(kind, (100, 86, 84))


# Where the two notes float: clear of each look's ears.
NOTES = {
    'cat': ((178, 90, 1.15), (24, 92, 0.95)),
    'dog': ((130, 30, 1.0), (68, 28, 0.85)),
    'bear': ((177, 68, 1.15), (26, 74, 0.95)),
}


def build(kind, mode, badge):
    a = Art(kind, mode)
    l = a.l
    cx, cy, R = frame(kind, mode, badge)
    # The rabbit stands a little lower, to make room for its ears.
    dy = 14 if (kind == 'rabbit' and mode == 'full') else 0
    if badge:
        a.defs.append(f'<radialGradient id="{a.pre}-stage" cx="{cx}" cy="{cy - R * 0.55}" r="{R * 1.25}" gradientUnits="userSpaceOnUse">'
                      '<stop offset="0" stop-color="#6A3796"/><stop offset="0.55" stop-color="#2A1646"/><stop offset="1" stop-color="#140B22"/></radialGradient>'
                      f'<linearGradient id="{a.pre}-beam" x1="0" y1="{cy - R}" x2="0" y2="{cy + R}" gradientUnits="userSpaceOnUse">'
                      '<stop offset="0" stop-color="#FFFFFF" stop-opacity="0.18"/><stop offset="1" stop-color="#FFFFFF" stop-opacity="0"/></linearGradient>'
                      f'<linearGradient id="{a.pre}-ring" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="{l["accent"]}"/><stop offset="0.5" stop-color="{l["top"]}"/><stop offset="1" stop-color="#BF5AF2"/></linearGradient>')
        a.add(f'<g {a.clip(f"""<circle cx="{cx}" cy="{cy}" r="{R}"/>""")}>')
        a.add(f'<rect x="{cx - R}" y="{cy - R}" width="{2 * R}" height="{2 * R}" fill="url(#{a.pre}-stage)"/>'
              f'<path d="M{cx - R * 0.18},{cy - R} L{cx + R * 0.18},{cy - R} L{cx + R * 0.76},{cy + R} L{cx - R * 0.76},{cy + R} Z" fill="url(#{a.pre}-beam)"/>')
        if mode == 'full':
            for x, y, r, o in ((30, 112, 3.4, 0.6), (172, 126, 3, 0.5), (40, 36, 2.4, 0.5), (164, 26, 2.2, 0.45)):
                a.add(f'<path d="{sparkle(x, y, r)}" fill="#FFFFFF" opacity="{o}"/>')
    if dy:
        a.add(f'<g transform="translate(0,{dy})">')
    a.behind()
    if mode == 'full':
        a.body()
        a.extras_over_body()
    a.head()
    if mode == 'full':
        a.microphone()
    if dy:
        a.add('</g>')
    if mode == 'full':
        n1, n2 = NOTES.get(kind, ((170, 62, 1.2), (28, 72, 0.95)))
        a.note(*n1, '#FFD60A')
        a.note(*n2, l['note'], 12)
    if badge:
        a.add('</g>')
        w = 3.4 if mode == 'full' else 4
        a.add(f'<circle cx="{cx}" cy="{cy}" r="{R - w / 2}" fill="none" stroke="url(#{a.pre}-ring)" stroke-width="{w}"/>')
    return (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="{cx - R} {cy - R} {2 * R} {2 * R}" width="512" height="512">'
            f'<defs>{"".join(a.defs)}</defs>{"".join(a.out)}</svg>\n')


def main():
    for mode in ('full', 'head'):
        for badge in (False, True):
            d = os.path.join(OUT, 'svg', f'{mode}_badge' if badge else mode)
            os.makedirs(d, exist_ok=True)
            for k in KINDS:
                with open(os.path.join(d, f'{k}.svg'), 'w') as f:
                    f.write(build(k, mode, badge))


if __name__ == '__main__':
    main()
