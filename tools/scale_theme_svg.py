import re
import sys
import pathlib

root = pathlib.Path(sys.argv[1])
root_tag_pat = re.compile(r"<svg\b[^>]*>", re.S)
attr_pat = {
    "width": re.compile(r'width="([^"]+)"'),
    "height": re.compile(r'height="([^"]+)"'),
    "viewBox": re.compile(r'viewBox="([^"]+)"'),
}


def fmt(v):
    s = f"{v:.6f}".rstrip("0").rstrip(".")
    return s


for svg in sorted(root.glob("mellow-*/*.svg")):
    text = svg.read_text(encoding="utf-8")
    m = root_tag_pat.search(text)
    if not m:
        print(f"  SKIP (no root tag): {svg.relative_to(root)}")
        continue
    tag = m.group(0)

    dims = {}
    vm = attr_pat["viewBox"].search(tag)
    if not vm:
        print(f"  SKIP (no viewBox): {svg.relative_to(root)}")
        continue
    parts = vm.group(1).split()
    if len(parts) != 4:
        print(f"  SKIP (bad viewBox): {svg.relative_to(root)}")
        continue
    vx, vy, vw, vh = (float(p) for p in parts)
    dims["viewBox"] = f"{fmt(vx)} {fmt(vy)} {fmt(vw * 2)} {fmt(vh * 2)}"
    for name in ("width", "height"):
        am = attr_pat[name].search(tag)
        if not am:
            print(f"  SKIP (no {name}): {svg.relative_to(root)}")
            break
        dims[name] = fmt(float(am.group(1)) * 2)
    else:
        new_tag = tag
        for name, val in dims.items():
            new_tag = attr_pat[name].sub(f'{name}="{val}"', new_tag, count=1)
        # Wrap all content (defs, metadata, renderables) in a scale(2) group.
        # defs/filter/namedview are never rendered directly; referenced ids
        # resolve regardless of nesting, and user-space units of referenced
        # geometry (incl. filter stdDeviation/offset) scale with the group.
        new_text = (
            text[: m.start()]
            + new_tag
            + '\n  <g transform="scale(2)">'
            + text[m.end() :].replace(
                "</svg>", "</g>\n</svg>", 1
            )
        )
        svg.write_text(new_text, encoding="utf-8")
        print(f"  scaled: {svg.relative_to(root)}  {tag.splitlines()[1].strip()} -> {dims}")
