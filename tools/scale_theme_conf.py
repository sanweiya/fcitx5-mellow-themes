import re
import sys
import pathlib

PIXEL_KEYS = {"Left", "Right", "Top", "Bottom", "OverlayOffsetX", "OverlayOffsetY", "BorderWidth", "Spacing"}
SCALE = 2
line_pat = re.compile(r"^(%s)=(\d+)$" % "|".join(PIXEL_KEYS))

root = pathlib.Path(sys.argv[1])
changed = 0
for conf in root.glob("mellow-*/theme.conf"):
    lines = []
    for line in conf.read_text(encoding="utf-8").splitlines():
        m = line_pat.match(line)
        if m:
            v = int(m.group(2)) * SCALE
            if v:
                changed += 1
            line = f"{m.group(1)}={v}"
        lines.append(line)
    conf.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"  scaled: {conf.relative_to(root)}")
print(f"total: {changed} non-zero pixel values x{SCALE}")
