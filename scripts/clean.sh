#!/usr/bin/env bash
#
# clean.sh — 回收构建产物，防止 DerivedData 副本在磁盘上无限累积
#
# 用法:
#   ./scripts/clean.sh            # 默认：删除散落的 DerivedData 副本 + 24 小时前的
#                                 #       .xcresult 测试报告；保留"规范"目录，
#                                 #                                 增量构建不受影响
#   ./scripts/clean.sh --deep     # 额外删除规范 DerivedData、SwiftPM .build、
#                                 #       Rust target / Cargo 缓存（下次全量重编）
#   ./scripts/clean.sh --all      # 在 --deep 之外额外删除 node_modules
#                                 #       （需重新 npm install）
#   ./scripts/clean.sh --dry-run  # 只报告将要删除什么，不动磁盘
#
# 约定:
#   "规范" DerivedData = scripts/ 里 xcodebuild 实际使用的那个（Bonk 是 build/）。
#   规范目录由本脚本从 scripts/*.sh 的 -derivedDataPath 自动解析，
#   不用在两处各写一份路径 —— 路径一多，副本就到处生长。
#   其他任何 DerivedData 目录都是历史遗留的副本，可以安全删除。
#
# 绝不删除: 源码 / 测试 / 资源 / Package.resolved / Podfile.lock /
#           Cartfile.resolved / 规范目录（默认模式）/ 未提交的改动
#
# 兼容 macOS 自带的 bash 3.2（不用关联数组、不用 mapfile）。
#
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT="$PWD"
SELF="$ROOT/scripts/clean.sh"

DEEP=0
ALL=0
DRY=0

usage() { sed -n '2,25p' "$0"; }

for arg in "$@"; do
  case "$arg" in
    --deep)    DEEP=1 ;;
    --all)     DEEP=1; ALL=1 ;;
    --dry-run) DRY=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

hr()  { printf -- '---------------------------------------------------------------\n'; }
say() { printf '  %s\n' "$1"; }

# 目录/文件占用的字节数。永远输出一个整数，调用方可以直接做算术，
# 不会因为 du 失败（权限不足、并发删除）而拿到空串炸掉整段脚本。
size_bytes() {
  local p="$1" kb
  [ -e "$p" ] || { echo 0; return 0; }
  kb=$(du -sk "$p" 2>/dev/null | awk 'NR==1{print $1}')
  case "$kb" in ''|*[!0-9]*) kb=0 ;; esac
  echo $((kb * 1024))
}

# 绝对化一个相对路径（相对仓库根）
abspath() {
  case "$1" in
    '$ROOT'/*) printf '%s\n' "$ROOT/${1#\$ROOT/}" ;;
    /*)        printf '%s\n' "$1" ;;
    *)         printf '%s\n' "$ROOT/$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. 解析"规范" DerivedData —— 单一事实来源是 scripts/ 里真正传给 xcodebuild 的值
# ---------------------------------------------------------------------------
# 扫描 scripts/*.sh（跳过本文件，免得把自己的扫描用正则当成一条路径），
# 每条 -derivedDataPath 归一化成绝对路径后去重。
scan_derived_data_paths() {
  local script cand var val abs
  for script in "$ROOT"/scripts/*.sh; do
    [ -f "$script" ] || continue
    [ "$script" = "$SELF" ] && continue
    while IFS= read -r cand; do
      [ -n "$cand" ] || continue
      # "$VAR" / "$VAR/sub" 形式：在同一个脚本里找 VAR="..." 的赋值
      if [[ "$cand" =~ ^\$([A-Za-z_][A-Za-z0-9_]*)($|/) ]]; then
        var="${BASH_REMATCH[1]}"
        val=$(grep -hoE "(^|[[:space:]])${var}=[\"']?[^\"'[:space:]]+" "$script" 2>/dev/null |
              head -1 | sed -E "s/.*${var}=[\"']?//")
        [ -n "$val" ] && cand="$val"
      fi
      abs="$(abspath "$cand")"
      printf '%s\t%s\n' "$abs" "$(basename "$script")"
    done < <(grep -hoE '\-derivedDataPath[[:space:]]+[^[:space:]]+' "$script" 2>/dev/null |
              awk '{print $2}' | tr -d "\"'")
  done
}

# 规范目录：本项目的约定是 build/，脚本扫描不到时才回退到这里
DEFAULT_CANONICAL="$ROOT/build"

CAND_LIST="$(scan_derived_data_paths | awk -F'\t' 'NF>=2 && !seen[$1]++')"
CAND_COUNT=0
[ -n "$CAND_LIST" ] && CAND_COUNT="$(printf '%s\n' "$CAND_LIST" | grep -c .)"

if [ "$CAND_COUNT" -gt 1 ]; then
  # 构建入口没有统一 —— 这正是副本到处生长的原因，必须喊出来
  printf 'WARN: scripts/ 里存在 %d 个不同的 -derivedDataPath，请统一成同一个:\n' "$CAND_COUNT" >&2
  printf '%s\n' "$CAND_LIST" | while IFS=$'\t' read -r p src; do
    [ -n "$p" ] || continue
    printf 'WARN:   %s  (%s)\n' "$p" "$src" >&2
  done
fi

CANONICAL=""
if [ "$CAND_COUNT" -ge 1 ]; then
  # 优先选磁盘上真实存在的那个；都不存在就取第一个（下次构建会建出来）
  FIRST=""
  while IFS=$'\t' read -r p src; do
    [ -n "$p" ] || continue
    [ -n "$FIRST" ] || FIRST="$p"
    [ -z "$CANONICAL" ] && [ -d "$p" ] && CANONICAL="$p"
  done < <(printf '%s\n' "$CAND_LIST")
  [ -z "$CANONICAL" ] && CANONICAL="$FIRST"
else
  CANONICAL="$DEFAULT_CANONICAL"
fi

# ---------------------------------------------------------------------------
# 2. 判定一个目录是不是 Xcode DerivedData
# ---------------------------------------------------------------------------
# 名字特征（Slice5DerivedData、AuditDerivedData、DerivedData……）
# + 结构特征（ModuleCache.noindex / Build/Intermediates.noindex /
#   SourcePackages+info.plist）—— 后者能抓到 build2、dd 这类名字里
#   没有 "DerivedData" 的副本。
is_derived_data_dir() {
  local d="$1" base
  base="$(basename "$d")"
  case "$base" in
    *[Dd]erived[Dd]ata*) return 0 ;;
  esac
  [ -d "$d/ModuleCache.noindex" ] && return 0
  [ -d "$d/Build/Intermediates.noindex" ] && return 0
  [ -d "$d/SourcePackages" ] && [ -f "$d/info.plist" ] && return 0
  return 1
}

# 删除一个路径并记账。dry-run 只报告。
# 注意 freed 是全局变量，所有调用方都必须在本 shell 里调用本函数
# （即用进程替换喂 while，而不是用管道 —— 管道会开子 shell，记账就丢了）。
purge() {
  local p="$1" sz
  [ -e "$p" ] || return 0
  # 规范目录在默认模式下必须活着 —— 删了它下一次就得全量重编
  if [ "$DEEP" -eq 0 ] && [ "$p" = "$CANONICAL" ]; then
    say "  保留 $p  (规范目录)"
    return 0
  fi
  sz=$(size_bytes "$p")
  if [ "$DRY" -eq 1 ]; then
    say "  [dry-run] 将删除 $p  ($((sz / 1048576)) MB)"
    freed=$((freed + sz))
    return 0
  fi
  rm -rf "$p" 2>/dev/null
  if [ ! -e "$p" ]; then
    freed=$((freed + sz))
    say "  删除 $p  ($((sz / 1048576)) MB)"
  else
    say "  跳过 $p  (权限不足)"
  fi
}

freed=0

hr
echo "项目:     $ROOT"
echo "规范目录: $CANONICAL"
if [ "$DRY" -eq 1 ]; then
  echo "模式:     dry-run（不删除任何东西）"
elif [ "$ALL" -eq 1 ]; then
  echo "模式:     --all（规范目录 + .build + target + node_modules 全清）"
elif [ "$DEEP" -eq 1 ]; then
  echo "模式:     --deep（规范目录 + .build + target）"
else
  echo "模式:     默认（保留规范目录）"
fi
hr

# ---------------------------------------------------------------------------
# 3. 散落的 DerivedData 副本
# ---------------------------------------------------------------------------
say "扫描散落的 DerivedData 副本..."

# 找法 A：名字里带 DerivedData
# 找法 B：结构特征（抓 build2 / dd / 任意改名的副本）
# 两条找法会命中同一个目录，收集后去重再删除，免得同一个副本被报两次。
STRAY=""
add_stray() { STRAY="$STRAY$1
"; }

while IFS= read -r d; do
  [ -n "$d" ] || continue
  [ "$d" = "$CANONICAL" ] && continue
  [ "$d" = "$ROOT" ] && continue
  is_derived_data_dir "$d" || continue
  add_stray "$d"
done < <(find "$ROOT" \
  \( -name '.git' -o -name 'node_modules' -o -path "$CANONICAL" -o -path "$CANONICAL/*" \) -prune -o \
  -type d -iname '*deriveddata*' -print 2>/dev/null)

while IFS= read -r m; do
  [ -n "$m" ] || continue
  d="$(dirname "$m")"
  [ "$(basename "$d")" = "Build" ] && d="$(dirname "$d")"
  [ "$d" = "$CANONICAL" ] && continue
  [ "$d" = "$ROOT" ] && continue
  is_derived_data_dir "$d" || continue
  add_stray "$d"
done < <(find "$ROOT" \
  \( -name '.git' -o -name 'node_modules' -o -path "$CANONICAL" -o -path "$CANONICAL/*" \) -prune -o \
  -type d \( -name 'ModuleCache.noindex' -o -name 'Intermediates.noindex' \) -print 2>/dev/null)

while IFS= read -r d; do
  [ -n "$d" ] || continue
  purge "$d"
done < <(printf '%s\n' "$STRAY" | sort -u)

# ---------------------------------------------------------------------------
# 4. 过期的 .xcresult 测试报告
# ---------------------------------------------------------------------------
say "扫描 .xcresult 测试报告..."
if [ "$DEEP" -eq 1 ]; then
  # --deep: 不论年龄全部清掉
  xcresult_filter=(-name '*.xcresult')
else
  # 默认: 只删 24 小时前的。-mmin +1440 是精确的 24 小时；
  # -mtime +1 实际是 48 小时起（按整数天算），会把报告多留一天。
  xcresult_filter=(-name '*.xcresult' -mmin +1440)
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  purge "$f"
done < <(find "$ROOT" \
  \( -name '.git' -o -name 'node_modules' -o -name 'SourcePackages' \) -prune -o \
  -type d "${xcresult_filter[@]}" -print 2>/dev/null)

# ---------------------------------------------------------------------------
# 5. --deep: 规范 DerivedData + SwiftPM .build + Rust target / Cargo 缓存
# ---------------------------------------------------------------------------
if [ "$DEEP" -eq 1 ]; then
  say "--deep: 删除规范 DerivedData 与依赖构建缓存"

  # 规范目录本身（默认模式下它是受保护的那一个）
  purge "$CANONICAL"

  # SwiftPM .build
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    purge "$d"
  done < <(find "$ROOT" \
    \( -name '.git' -o -name 'node_modules' \) -prune -o \
    -type d -name '.build' -print 2>/dev/null)

  # Rust / Cargo target 目录。Cargo 会写 CACHEDIR.TAG，用它做判据，
  # 免得把 build/.../PIFCache/target 这种同名目录也当成 Cargo 缓存。
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    [ -f "$d/CACHEDIR.TAG" ] || continue
    purge "$d"
  done < <(find "$ROOT" \
    \( -name '.git' -o -name 'node_modules' \) -prune -o \
    -type d -name 'target' -print 2>/dev/null)
fi

# ---------------------------------------------------------------------------
# 6. --all: node_modules（需重新 npm install）
# ---------------------------------------------------------------------------
if [ "$ALL" -eq 1 ]; then
  say "--all: 删除 node_modules（需重新 npm install）"
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    purge "$d"
  done < <(find "$ROOT" -maxdepth 5 \
    -name '.git' -prune -o \
    -type d -name 'node_modules' -print 2>/dev/null)
fi

hr
printf '共回收: %d MB\n' "$((freed / 1048576))"
if [ "$freed" -ge 1073741824 ]; then
  printf '（约 %.1f GB）\n' "$(awk "BEGIN{print $freed/1073741824}")"
fi
hr
