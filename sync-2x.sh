#!/bin/bash
# 从两个 1x 源目录 (mellow, mellow-compact) 重新生成对应的 2x 目录
# (mellow-2x, mellow-compact-2x)，构成四个发布变体。
# 所有 theme.conf 像素值与 SVG 几何均由脚本确定性放大 2 倍，
# 保证 1x 与 2x 严格保持对应关系。
# 用法：修改 mellow/ 或 mellow-compact/ 后运行 ./sync-2x.sh
set -euo pipefail

BASE="$(cd "$(dirname "$0")" && pwd)"

for variant in mellow mellow-compact; do
    DST="$BASE/${variant}-2x"
    rsync -a --delete "$BASE/$variant/" "$DST/"
    python3 -I "$BASE/tools/scale_theme_conf.py" "$DST"
    python3 -I "$BASE/tools/scale_theme_svg.py" "$DST"
done
