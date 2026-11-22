#!/usr/bin/env bash
# Mellow 主题生成器 —— 交互问答生成自定义 fcitx5 主题（1x 或 2x）。
#
# 流程（不带参数运行时逐项提问；参数可跳过对应问答）：
#   1. 主题色（高亮背景）——十六进制，必填
#   2. 密度：0=宽松（mellow），1=紧凑（mellow-compact）；留空=0
#   3. 面板背景：0=浅色，1=深色；留空=0
#   4. 缩放：0=不缩放（1x），1=2x 缩放；留空=0
#      LowDPI 与 Wayland HiDPI 选 0 不缩放；X11 HiDPI 选 1 做 2x 缩放
#      （本主题集不支持 X11 HiDPI 原生缩放，2x 主题即为其替代方案）
#   5. 高亮候选词文字颜色——留空=自动（按主题色深浅在纯黑/纯白中取 WCAG 对比度更高者）
#   6. 一般文字颜色——留空=自动（浅色面板 #000000 / 深色面板 #bcbcbc，同已有主题深浅版主流值）
#   7. 主题名——留空=按主题色十六进制命名
#
# 实现要点（graphite 模板为基座，颜色无关几何）：
#   - highlight.svg：明暗两版逐字节相同，仅替换有效填色 style="fill:#808080…"；
#     presentation 属性 fill="#015ad7" 等被 style 覆盖、无视觉效果，保持原样。
#   - panel.svg：浅色 fill #f9f9f9 / 深色 fill #151515（与全部已有主题一致），整文件照抄。
#   - theme.conf：awk 节感知改写 Name、NormalColor（InputPanel 与 Menu 两节）、
#     HighlightCandidateColor、HighlightColor、HighlightBackgroundColor（=主题色，
#     预编辑高亮段底色，5.1.12 insertAttr 已核）、Background/Highlight 的 Color
#     回退值；每条编辑断言恰好命中一次。已有主题深色版 Menu/NormalColor 仍是黑色
#     （深面板上不可读，属旧版遗留）；生成主题让菜单文字跟随一般文字色。
#   - 2x：staging 内复制 1x 后调用 tools/scale_theme_conf.py 与 scale_theme_svg.py，
#     与 sync-2x.sh 同一实现，保证 1x/2x 严格对应。
#   - 生成后自检：关键键值计数断言；2x 再做 conf 全量键值对账（像素键 ×2、其余不变）
#     与 SVG scale(2) 包裹组 / 根宽 ×2 检查。
#
# 输出与安装：
#   generated/<变体>/<主题>/（1x）或 generated/<变体>-2x/<主题>/（2x），不入库（.gitignore）。
#   安装：cp -r <生成目录> ~/.local/share/fcitx5/themes/ 后重启 fcitx5。

set -u

BASE="$(cd "$(dirname "$0")" && pwd)"
OUT="$BASE/generated"
TOOLS="$BASE/tools"

HL_STYLE_OLD='style="fill:#808080;fill-opacity:1"'
PANEL_FILL_LIGHT='#f9f9f9'
PANEL_FILL_DARK='#151515'
TEXT_AUTO_LIGHT='#000000'
TEXT_AUTO_DARK='#bcbcbc'

stage=""
cleanup() { [[ -n $stage && -d $stage ]] && rm -rf "$stage"; }
trap cleanup EXIT

die()  { printf '✗ %s\n' "$*" >&2; exit 1; }
warn() { printf '  ⚠ %s\n' "$*"; }
note() { printf '  ✗ %s\n' "$*" >&2; }

usage() {
  cat <<'EOF'
用法：./generate-theme.sh [选项]
不带参数进入交互问答。
  -c, --highlight HEX            主题色/高亮背景（6 位十六进制，必填）
  -d, --density 0|1              0=宽松，1=紧凑（默认 0）
  -p, --panel 0|1                0=浅色面板，1=深色面板（默认 0）
  -s, --scale 0|1                0=不缩放（LowDPI / Wayland HiDPI），
                                 1=2x 缩放（X11 HiDPI）（默认 0）
      --highlight-text HEX|auto  高亮候选词文字颜色（默认 auto：按主题色深浅取纯黑/纯白）
      --text HEX|auto            一般文字颜色（默认 auto：浅面板 #000000 / 深面板 #bcbcbc）
  -n, --name NAME                主题目录名（完整名；默认 mellow[-compact]-<主题色>[-dark]）
  -f, --force                    覆盖 generated/ 中已存在的同名主题
  -h, --help                     显示本帮助
EOF
}

# ---------------- 颜色 ----------------

parse_hex() { # $1 原始输入 -> RET（"#abcdef" 或 ""）
  local s=${1#\#}
  s=${s,,}
  if [[ $s =~ ^[0-9a-f]{6}$ ]]; then RET="#$s"; else RET=""; fi
}

lum() { # $1 "#abcdef" -> stdout 相对亮度 Y（0-1）
  local r g b
  printf -v r '%d' "0x${1:1:2}"
  printf -v g '%d' "0x${1:3:2}"
  printf -v b '%d' "0x${1:5:2}"
  awk -v r="$r" -v g="$g" -v b="$b" '
    function lin(c) { c /= 255; return (c <= 0.04045) ? c / 12.92 : ((c + 0.055) / 1.055) ^ 2.4 }
    BEGIN { printf "%.6f\n", 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b) }'
}

auto_hl_text() { # $1 主题色 -> stdout 纯黑/纯白（对比度更高者）
  local y
  y=$(lum "$1")
  awk -v y="$y" 'BEGIN {
    cb = (y + 0.05) / 0.05; cw = 1.05 / (y + 0.05)
    printf "%s", (cb >= cw) ? "#000000" : "#ffffff" }'
}

cratio() { # $1 底色 $2 字色 -> stdout "16.3:1"
  awk -v a="$(lum "$1")" -v b="$(lum "$2")" 'BEGIN {
    la = (a > b) ? a : b; lb = (a > b) ? b : a
    printf "%.1f:1", (la + 0.05) / (lb + 0.05) }'
}

# ---------------- 交互输入 ----------------
# 统一排版：步骤间空一行；提问块（标题 + 说明）独立成段；回答行以 "> " 开头。

ask_hex_required() { # $1 标题 $2 说明块(自带换行) -> ACCENT
  local input
  printf '\n%s\n' "$1"
  printf '%s' "$2"
  while :; do
    read -r -p '> ' input || { printf '\n' >&2; die "未读到输入，已取消"; }
    parse_hex "$input"
    [[ -n $RET ]] && { ACCENT=$RET; return 0; }
    note "无效颜色码：请输入六位十六进制，如 #AFEEEE。"
  done
}

ask_hex_or_auto() { # $1 标题 $2 说明块 -> RET（""=自动；EOF 视为自动）
  local input
  printf '\n%s\n' "$1"
  printf '%s' "$2"
  while :; do
    read -r -p '> ' input || { RET=""; return 0; }
    [[ -z $input || ${input,,} == auto ]] && { RET=""; return 0; }
    parse_hex "$input"
    [[ -n $RET ]] && return 0
    note "无效颜色码：请输入六位十六进制（如 #AFEEEE），或留空=自动。"
  done
}

ask_choice() { # $1 标题 $2 选项块 $3 默认 -> RET 0/1（EOF 视为默认）
  local input
  printf '\n%s\n' "$1"
  printf '%s' "$2"
  while :; do
    read -r -p '> ' input || { RET=$3; return 0; }
    [[ -z $input ]] && { RET=$3; return 0; }
    [[ $input == 0 || $input == 1 ]] && { RET=$input; return 0; }
    note "请输入 0 或 1。"
  done
}

ask_name() { # $1 预填完整目录名 -> TDIR_IN（EOF 视为预填值）
  local prefill=$1 input
  printf '\n%s\n' "7/7 主题名"
  printf '%s' $'    预填可编辑，回车确认；显示名 Name= 由目录名推导。\n'
  while :; do
    if [[ -t 0 ]]; then
      # 终端下用 readline 预填，光标停在行尾，用户可自由修改
      read -e -r -i "$prefill" -p '> ' input \
        || { printf '\n' >&2; die "未读到输入，已取消"; }
    else
      read -r -p '> ' input || { TDIR_IN=$prefill; return 0; }
    fi
    [[ -z $input ]] && input=$prefill
    input=${input// /-}
    input=${input,,}
    if [[ $input =~ ^[a-z0-9]([a-z0-9-]{0,46}[a-z0-9])?$ ]]; then
      TDIR_IN=$input
      return 0
    fi
    note "目录名仅限小写字母/数字/连字符，不以连字符开头或结尾，长度 ≤ 48。"
  done
}

derive_name() { # $1 完整目录名 -> NAME_NEW（Name= 显示名）
  local t=$1 disp="" rest title="" w dark=""
  if [[ $t == mellow-compact-* ]]; then
    disp="Mellow Compact"
    rest=${t#mellow-compact-}
  elif [[ $t == mellow-* ]]; then
    disp="Mellow"
    rest=${t#mellow-}
  else
    rest=$t
  fi
  [[ $rest == *-dark ]] && { dark=" dark"; rest=${rest%-dark}; }
  for w in ${rest//-/ }; do title+="${title:+ }${w^}"; done
  NAME_NEW="${disp:+$disp }${title}${dark}"
  [[ -z ${NAME_NEW// /} ]] && NAME_NEW=$t
}

ask_overwrite() { # $1 路径 -> 0=覆盖
  local r
  read -r -p "  ⚠ 已存在 $1，覆盖？[y/N]：" r || return 1
  [[ ${r,,} == y || ${r,,} == yes ]]
}

# ---------------- 文件改写 ----------------

apply_conf() { # $1 模板 $2 目标 $3 编辑清单(TAB 分隔四列/行) $4 主题名
  awk -F= -v EDITS="$3" -v LABEL="$4" '
    BEGIN {
      n = split(EDITS, L, "\n")
      for (i = 1; i <= n; i++) {
        m = split(L[i], f, "\t")
        if (m == 4) {
          old[f[1] SUBSEP f[2]] = f[3]
          newv[f[1] SUBSEP f[2]] = f[4]
          hit[f[1] SUBSEP f[2]] = 0
          nedit++
        }
      }
      if (nedit == 0) { print "✗ 编辑清单为空" > "/dev/stderr"; exit 1 }
    }
    /^\[/ { s = $0; gsub(/^[ \t]*\[|\][ \t\r]*$/, "", s); section = s; print; next }
    /=/   {
      key = $1; v = $0; sub(/^[^=]*=/, "", v)
      k = section SUBSEP key
      if ((k in old) && v == old[k]) { print key "=" newv[k]; hit[k]++; next }
    }
    { print }
    END {
      bad = 0
      for (k in hit) if (hit[k] != 1) {
        split(k, p, SUBSEP)
        printf "✗ 模板不匹配：%s 中 [%s]%s 期望命中 1 次，实际 %d 次\n", \
               LABEL, p[1], p[2], hit[k] > "/dev/stderr"
        bad = 1
      }
      exit bad
    }' "$1" > "$2" || die "conf 改写校验失败（graphite 模板与生成器预期不一致？请核对）"
}

apply_highlight_svg() { # $1 模板 $2 目标 $3 主题色
  awk -v old="$HL_STYLE_OLD" -v new="style=\"fill:$3;fill-opacity:1\"" '
    { hits += gsub(old, new); print }
    END { exit (hits == 1) ? 0 : 1 }' "$1" > "$2" \
    || die "模板不匹配：highlight.svg 有效填色样式与预期不一致，请核对"
}

# ---------------- 自检 ----------------

verify_theme() { # $1 1x目录 $2 2x目录(""=未生成) $3 Name $4 主题色 $5 高亮文字 $6 一般文字 $7 面板色
  local c="$1/theme.conf" n f
  grep -qxF "Name=$3" "$c" || die "自检失败：Name 不符"
  n=$(grep -cxF "HighlightBackgroundColor=$4" "$c");   [[ $n == 1 ]] || die "自检失败：HighlightBackgroundColor（$n 处）"
  n=$(grep -cxF "NormalColor=$6" "$c");                [[ $n == 2 ]] || die "自检失败：NormalColor 应两节（$n 处）"
  n=$(grep -cxF "HighlightCandidateColor=$5" "$c");    [[ $n == 2 ]] || die "自检失败：HighlightCandidateColor 应两节（$n 处）"
  n=$(grep -cxF "Color=$4" "$c");                      [[ $n == 2 ]] || die "自检失败：Highlight/Color 主题色回退（$n 处）"
  n=$(grep -cxF "Color=$7" "$c");                      [[ $n == 2 ]] || die "自检失败：Background/Color 面板色回退（$n 处）"
  n=$(grep -cF "a5a5a5" "$c");                         [[ $n == 0 ]] || die "自检失败：残留旧值 #a5a5a5（$n 处）"
  n=$(grep -cF "style=\"fill:$4;fill-opacity:1\"" "$1/highlight.svg")
  [[ $n == 1 ]] || die "自检失败：highlight.svg 填色（$n 处）"

  [[ -n $2 ]] || return 0
  for f in panel.svg highlight.svg; do
    grep -qF '<g transform="scale(2)">' "$2/$f" || die "自检失败：2x $f 缺 scale(2) 包裹组"
    grep -qF 'width="62"' "$2/$f" || die "自检失败：2x $f 根宽未 ×2"
  done
  # 2x conf 全量对账：像素键 ×2，其余键不变
  awk -F= '
    function ispix(k) {
      return k ~ /^(Left|Right|Top|Bottom|OverlayOffsetX|OverlayOffsetY|BorderWidth|Spacing)$/
    }
    NR == FNR {
      if ($0 ~ /^\[/) { s = $0; gsub(/\[|\]/, "", s); sec = s; next }
      if (/=/) { v = $0; sub(/^[^=]*=/, "", v); a[sec SUBSEP $1] = v }
      next
    }
    {
      if ($0 ~ /^\[/) { s = $0; gsub(/\[|\]/, "", s); sec = s; next }
      if (/=/) { v = $0; sub(/^[^=]*=/, "", v); b[sec SUBSEP $1] = v }
    }
    END {
      bad = 0
      for (k in a) {
        if (!(k in b)) { printf "✗ 2x 缺键：%s\n", k > "/dev/stderr"; bad = 1; continue }
        split(k, p, SUBSEP)
        if (ispix(p[2])) {
          if (b[k] != a[k] * 2) {
            printf "✗ 2x %s=%s，预期 %d\n", k, b[k], a[k] * 2 > "/dev/stderr"; bad = 1
          }
        } else if (b[k] != a[k]) {
          printf "✗ 2x %s 应不变：%s -> %s\n", k, a[k], b[k] > "/dev/stderr"; bad = 1
        }
      }
      for (k in b) if (!(k in a)) {
        printf "✗ 2x 多键：%s\n", k > "/dev/stderr"; bad = 1
      }
      exit bad
    }' "$c" "$2/theme.conf" || die "自检失败：2x conf 与 1x 对账不符"
}

# ---------------- 生成 ----------------

add_edit() { # $1 节 $2 键 $3 旧值 $4 新值
  # 注意：$(printf '…\n') 会丢失尾部换行，故换行符在替换外显式拼接
  EDITS+="$(printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4")"$'\n'
}

generate() { # 全局：variant tdir tone accent hl_text text_color scale force name_new …
  local tpl_light tpl_dark tpl_tone name_old panel_color src1x destdir dest
  if [[ $density == 0 ]]; then
    tpl_light="$BASE/mellow/mellow-graphite"
    tpl_dark="$BASE/mellow/mellow-graphite-dark"
    name_old="Mellow Graphite"
  else
    tpl_light="$BASE/mellow-compact/mellow-compact-graphite"
    tpl_dark="$BASE/mellow-compact/mellow-compact-graphite-dark"
    name_old="Mellow Compact Graphite"
  fi
  [[ $tone == dark ]] && { tpl_tone=$tpl_dark; name_old+=" dark"; } || tpl_tone=$tpl_light
  panel_color=$PANEL_FILL_LIGHT
  [[ $tone == dark ]] && panel_color=$PANEL_FILL_DARK

  if [[ $scale == 0 ]]; then
    destdir=$variant
    dest="$OUT/$variant/$tdir"
  else
    destdir="$variant-2x"
    dest="$OUT/$variant-2x/$tdir"
  fi

  if [[ -e $dest ]]; then
    if [[ $force == 1 ]]; then
      rm -rf "$dest"
    elif [[ -t 0 ]] && ask_overwrite "$dest"; then
      rm -rf "$dest"
    else
      die "目标已存在：${dest#"$BASE"/}（换名或加 --force）"
    fi
  fi
  [[ -d $BASE/$variant/$tdir ]] && \
    warn "与仓库已发布主题同名：$variant/$tdir；generated/ 内容独立，不影响仓库文件。"

  # 编辑清单（节/键/旧值/新值，每条须恰好命中一次）
  local ip_normal_old='#000000'
  [[ $tone == dark ]] && ip_normal_old='#ffffff'
  EDITS=""
  add_edit Metadata Name "$name_old" "$name_new"
  add_edit InputPanel NormalColor "$ip_normal_old" "$text_color"
  add_edit Menu NormalColor '#000000' "$text_color"
  add_edit InputPanel HighlightCandidateColor '#ffffff' "$hl_text"
  add_edit Menu HighlightCandidateColor '#ffffff' "$hl_text"
  add_edit InputPanel HighlightColor '#ffffff' "$hl_text"
  add_edit InputPanel HighlightBackgroundColor '#a5a5a5' "$accent"
  add_edit 'InputPanel/Background' Color '#ffffff' "$panel_color"
  add_edit 'Menu/Background' Color '#ffffff' "$panel_color"
  add_edit 'InputPanel/Highlight' Color '#ffffff' "$accent"
  add_edit 'Menu/Highlight' Color '#ffffff' "$accent"

  stage="$OUT/.staging-$$"
  rm -rf "$stage"
  mkdir -p "$stage/$variant/$tdir"
  src1x="$stage/$variant/$tdir"
  apply_conf "$tpl_tone/theme.conf" "$src1x/theme.conf" "$EDITS" "$tdir"
  cp "$tpl_tone/panel.svg" "$src1x/panel.svg"
  apply_highlight_svg "$tpl_light/highlight.svg" "$src1x/highlight.svg" "$accent"

  if [[ $scale == 1 ]]; then
    # 与 sync-2x.sh 相同的两步缩放，作用于仅含本主题的 staging 根
    mkdir -p "$stage/$variant-2x"
    cp -R "$src1x" "$stage/$variant-2x/$tdir"
    python3 -I "$TOOLS/scale_theme_conf.py" "$stage/$variant-2x" \
      || die "scale_theme_conf.py 失败"
    python3 -I "$TOOLS/scale_theme_svg.py" "$stage/$variant-2x" \
      || die "scale_theme_svg.py 失败"
  fi

  verify_theme "$src1x" "$( [[ $scale == 1 ]] && echo "$stage/$variant-2x/$tdir" )" \
    "$name_new" "$accent" "$hl_text" "$text_color" "$panel_color"

  mkdir -p "$OUT/$destdir"
  rm -rf "$dest"
  if [[ $scale == 0 ]]; then
    mv "$src1x" "$dest"
  else
    mv "$stage/$variant-2x/$tdir" "$dest"
  fi
  GENERATED="${dest#"$BASE"/}"
  GENERATED_ABS="$dest"
}

# ---------------- 主流程 ----------------

main() {
  local accent_arg="" density_arg="" panel_arg="" scale_arg="" hlt_arg="" \
        text_arg="" name_arg="" force=0
  local hl_src text_src panel_color ratio scale_txt

  while [[ $# -gt 0 ]]; do
    case $1 in
      -c | --highlight) accent_arg=${2:?}; shift 2 ;;
      -d | --density) density_arg=${2:?}; shift 2 ;;
      -p | --panel) panel_arg=${2:?}; shift 2 ;;
      -s | --scale) scale_arg=${2:?}; shift 2 ;;
      --highlight-text) hlt_arg=${2:?}; shift 2 ;;
      --text) text_arg=${2:?}; shift 2 ;;
      -n | --name) name_arg=${2:?}; shift 2 ;;
      -f | --force) force=1; shift ;;
      -h | --help) usage; exit 0 ;;
      *) die "未知参数：$1（-h 查看用法）" ;;
    esac
  done

  echo "== Mellow 主题生成器 =="

  if [[ -n $accent_arg ]]; then
    parse_hex "$accent_arg"
    [[ -n $RET ]] || die "--highlight 无效：请输入 6 位十六进制（如 #AFEEEE）。"
    accent=$RET
  else
    ask_hex_required "1/7 主题色（高亮背景）" \
      $'    用于候选词高亮条与预编辑高亮段底色。\n    格式：六位十六进制，如 #AFEEEE。\n'
    accent=$ACCENT
  fi

  if [[ -n $density_arg ]]; then
    [[ $density_arg == 0 || $density_arg == 1 ]] || die "--density 仅接受 0 或 1"
    density=$density_arg
  else
    ask_choice "2/7 密度（留空=0）" \
      $'    0 · 宽松（mellow 素材）\n    1 · 紧凑（mellow-compact 素材）\n' 0
    density=$RET
  fi

  if [[ -n $panel_arg ]]; then
    [[ $panel_arg == 0 || $panel_arg == 1 ]] || die "--panel 仅接受 0 或 1"
    panel=$panel_arg
  else
    ask_choice "3/7 面板背景（留空=0）" \
      $'    0 · 浅色（面板 #f9f9f9，配深色文字）\n    1 · 深色（面板 #151515，配浅色文字）\n' 0
    panel=$RET
  fi
  tone=light
  [[ $panel == 1 ]] && tone=dark

  if [[ -n $scale_arg ]]; then
    [[ $scale_arg == 0 || $scale_arg == 1 ]] || die "--scale 仅接受 0 或 1"
    scale=$scale_arg
  else
    ask_choice "4/7 缩放方式（按桌面环境选择，留空=0）" \
      $'    0 · 不缩放 —— 使用 1x 素材\n        适用：LowDPI、Wayland HiDPI\n\n    1 · 2x 缩放 —— 使用 2x 素材（几何整体放大一倍）\n        适用：X11 HiDPI（fcitx5 在该环境无原生缩放，以 2x 素材补偿）\n' 0
    scale=$RET
  fi

  if [[ -n $hlt_arg ]]; then
    if [[ ${hlt_arg,,} != auto ]]; then
      parse_hex "$hlt_arg"
      [[ -n $RET ]] || die "--highlight-text 无效：应为 6 位十六进制或 auto。"
      hl_text=$RET; hl_src=指定
    else
      hl_text=$(auto_hl_text "$accent"); hl_src=自动
    fi
  else
    ask_hex_or_auto "5/7 高亮候选词文字颜色" \
      $'    高亮条上候选词的文字颜色，六位十六进制。\n    留空 = 自动 —— 按主题色深浅，在纯黑/纯白中取对比度更高者。\n'
    if [[ -n $RET ]]; then hl_text=$RET; hl_src=指定; else hl_text=$(auto_hl_text "$accent"); hl_src=自动; fi
  fi

  if [[ -n $text_arg ]]; then
    if [[ ${text_arg,,} != auto ]]; then
      parse_hex "$text_arg"
      [[ -n $RET ]] || die "--text 无效：应为 6 位十六进制或 auto。"
      text_color=$RET; text_src=指定
    else
      text_color=$TEXT_AUTO_LIGHT
      [[ $tone == dark ]] && text_color=$TEXT_AUTO_DARK
      text_src=自动
    fi
  else
    ask_hex_or_auto "6/7 一般文字颜色" \
      $'    候选词与预编辑的正常文字颜色，六位十六进制。\n    留空 = 自动 —— 浅色面板 #000000，深色面板 #bcbcbc（同已有主题）。\n'
    if [[ -n $RET ]]; then text_color=$RET; text_src=指定
    else
      text_color=$TEXT_AUTO_LIGHT
      [[ $tone == dark ]] && text_color=$TEXT_AUTO_DARK
      text_src=自动
    fi
  fi

  if [[ $density == 0 ]]; then variant=mellow; else variant=mellow-compact; fi
  panel_color=$PANEL_FILL_LIGHT
  [[ $tone == dark ]] && panel_color=$PANEL_FILL_DARK

  # 主题名：预填完整目录名，用户可整体自由编辑
  tdir_default="$variant-${accent#\#}"
  [[ $tone == dark ]] && tdir_default+="-dark"
  if [[ -n $name_arg ]]; then
    name_arg=${name_arg// /-}
    name_arg=${name_arg,,}
    [[ $name_arg =~ ^[a-z0-9]([a-z0-9-]{0,46}[a-z0-9])?$ ]] \
      || die "--name 无效：仅限小写字母/数字/连字符（不以连字符开头/结尾），长度 ≤ 48。"
    tdir=$name_arg
  else
    ask_name "$tdir_default"
    tdir=$TDIR_IN
  fi
  case $tdir in
    mellow | mellow-2x | mellow-compact | mellow-compact-2x)
      die "主题目录名 $tdir 与仓库变体目录冲突，请换名。" ;;
  esac
  derive_name "$tdir"
  name_new=$NAME_NEW

  [[ $scale == 0 ]] && scale_txt="不缩放（LowDPI / Wayland HiDPI）" || scale_txt="2x 缩放（X11 HiDPI）"
  ratio=$(cratio "$accent" "$hl_text")

  echo
  echo "将生成："
  echo "  主题色（高亮背景）  $accent"
  echo "  密度 / 面板         $( [[ $density == 1 ]] && echo 紧凑 || echo 宽松 ) / $( [[ $tone == dark ]] && echo 深色 || echo 浅色 ) $panel_color"
  echo "  缩放                $scale_txt"
  echo "  高亮候选词文字      $hl_src $hl_text（与主题色对比 $ratio）"
  echo "  一般文字            $text_src $text_color"
  echo "  名称                $name_new（目录 $tdir）"

  generate

  echo
  echo "✓ 生成完成（自检通过）："
  echo "  $GENERATED"
  echo
  echo "安装（LowDPI / Wayland HiDPI 用 1x 不缩放版；X11 HiDPI 用 2x 版）："
  echo "  cp -r \"$GENERATED_ABS\" ~/.local/share/fcitx5/themes/"
  echo "  fcitx5 -r   # 或在 fcitx5 配置工具中切换主题"
  echo
  if [[ $scale == 0 ]]; then
    echo "如需发布：移入 $variant/ 后运行 ./sync-2x.sh（2x 档自动重生成）；"
    echo "          或先以 -s 1 生成 2x 档再分别移入两目录。"
  else
    echo "如需发布：先以 -s 0 生成 1x 档并移入 $variant/，再运行 ./sync-2x.sh；"
    echo "          本 2x 目录可移入 $variant-2x/。"
  fi
}

main "$@"
