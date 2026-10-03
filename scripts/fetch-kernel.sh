#!/usr/bin/env bash
#
# 從 GitHub Actions 下載 build 好的 kernel artifact。
#
# 用法（旗標或環境變數皆可）:
#   ./scripts/fetch-kernel.sh --variant kasan [--arch x86_64] [--run-id N]
#                             [--ref <kernel ref>] [--dest ./downloads]
#   VARIANT=kasan ARCH=x86_64 ./scripts/fetch-kernel.sh
#
# 若不給 run-id，預設抓最近一次成功的 "Build Linux Kernel" workflow run。
# 需求: 已登入的 gh CLI（gh auth login）。
set -euo pipefail

# 預設值（環境變數可覆蓋，旗標再覆蓋環境變數）
VARIANT="${VARIANT:-}"
ARCH="${ARCH:-x86_64}"
DEST="${DEST:-./downloads}"
WORKFLOW="${WORKFLOW:-build-kernel.yml}"
RUN_ID="${RUN_ID:-}"
REF="${REF:-}"

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --variant)  VARIANT="$2"; shift 2 ;;
    --arch)     ARCH="$2"; shift 2 ;;
    --run-id)   RUN_ID="$2"; shift 2 ;;
    --ref)      REF="$2"; shift 2 ;;
    --dest)     DEST="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    *) echo "未知參數: $1" >&2; usage 1 ;;
  esac
done

[ -n "$VARIANT" ] || { echo "需要 --variant (kasan|nokasan|symbol)" >&2; usage 1; }

command -v gh >/dev/null || { echo "缺少 gh CLI，請先安裝並 gh auth login" >&2; exit 1; }

# 找 run id
if [ -z "${RUN_ID:-}" ]; then
  echo "未指定 RUN_ID，找最近一次成功的 run..."
  RUN_ID="$(gh run list --workflow "$WORKFLOW" --status success \
    --limit 1 --json databaseId --jq '.[0].databaseId')"
  [ -n "$RUN_ID" ] || { echo "找不到成功的 run" >&2; exit 1; }
fi
echo "==> 使用 run: $RUN_ID"

# artifact 名稱格式： kernel-<arch>-<ref>-<variant>
# ref 可能不定，用 pattern 比對
PATTERN="kernel-${ARCH}-*-${VARIANT}"
if [ -n "${REF:-}" ]; then
  PATTERN="kernel-${ARCH}-${REF}-${VARIANT}"
fi

mkdir -p "$DEST"
echo "==> 下載 artifact 比對樣式: $PATTERN"
gh run download "$RUN_ID" --pattern "$PATTERN" --dir "$DEST"

# 找出下載到的目錄（gh 會以 artifact 名建子目錄）
ARTDIR="$(find "$DEST" -maxdepth 1 -type d -name "kernel-${ARCH}-*-${VARIANT}" | head -1)"
[ -n "$ARTDIR" ] || { echo "下載後找不到符合的 artifact 目錄" >&2; exit 1; }

echo "==> 下載完成: $ARTDIR"
ls -lh "$ARTDIR"
# 供呼叫端取用
echo "$ARTDIR"
