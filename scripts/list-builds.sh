#!/usr/bin/env bash
#
# 查詢 "Build Linux Kernel" 的 GitHub Actions runs 與各自的 artifact 名稱。
# 結果會快取在本機，預設 TTL 內重複查詢不再打 API。
#
# 用法:
#   ./scripts/list-builds.sh                 # 列出最近的 build 與 artifact
#   ./scripts/list-builds.sh --limit 20      # 多列幾筆
#   ./scripts/list-builds.sh --refresh       # 忽略快取、強制重新查
#   ./scripts/list-builds.sh --json          # 輸出原始 JSON（給程式用）
#   ./scripts/list-builds.sh --ttl 60        # 自訂快取有效秒數（預設 600）
#
# 需求: 已登入的 gh CLI、jq。
set -euo pipefail

WORKFLOW="${WORKFLOW:-build-kernel.yml}"
LIMIT="${LIMIT:-10}"
TTL="${TTL:-600}"
CACHE_DIR="${CACHE_DIR:-./downloads/.cache}"
REFRESH=0
AS_JSON=0

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --limit)   LIMIT="$2"; shift 2 ;;
    --ttl)     TTL="$2"; shift 2 ;;
    --refresh) REFRESH=1; shift ;;
    --json)    AS_JSON=1; shift ;;
    -h|--help) usage 0 ;;
    *) echo "未知參數: $1" >&2; usage 1 ;;
  esac
done

command -v gh >/dev/null || { echo "缺少 gh CLI，請先安裝並 gh auth login" >&2; exit 1; }
command -v jq >/dev/null || { echo "缺少 jq，請先安裝" >&2; exit 1; }

mkdir -p "$CACHE_DIR"
# 快取檔名含 workflow 與 limit，避免不同查詢互相覆蓋
CACHE="$CACHE_DIR/builds-${WORKFLOW%.yml}-l${LIMIT}.json"

cache_fresh() {
  [ -f "$CACHE" ] || return 1
  local age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
  [ "$age" -lt "$TTL" ]
}

if [ "$REFRESH" != "1" ] && cache_fresh; then
  echo "== 使用本機快取（${TTL}s 內有效；--refresh 可強制更新）: $CACHE ==" >&2
else
  echo "== 向 GitHub 查詢 runs 與 artifacts... ==" >&2
  runs="$(gh run list --workflow "$WORKFLOW" --limit "$LIMIT" \
    --json databaseId,displayTitle,status,conclusion,createdAt,event)"

  # 逐一補上每個 run 的 artifact（名稱/大小/是否過期）
  out="$(echo "$runs" | jq -c '.[]' | while read -r run; do
    id="$(echo "$run" | jq -r '.databaseId')"
    arts="$(gh api "repos/{owner}/{repo}/actions/runs/$id/artifacts" \
      --jq '[.artifacts[] | {name, mb: ((.size_in_bytes/1048576)|floor), expired}]' 2>/dev/null || echo '[]')"
    echo "$run" | jq --argjson arts "$arts" '. + {artifacts: $arts}'
  done | jq -s '.')"

  tmp="$(mktemp)"
  printf '%s\n' "$out" > "$tmp"
  mv "$tmp" "$CACHE"
  echo "== 已更新快取: $CACHE ==" >&2
fi

if [ "$AS_JSON" = "1" ]; then
  cat "$CACHE"
  exit 0
fi

# 人類可讀的表格
jq -r '
  .[] |
  "─────────────────────────────────────────────" ,
  "run \(.databaseId)   [\(.status)/\(.conclusion // "-")]   \(.createdAt)" ,
  "  \(.displayTitle)" ,
  ( if (.artifacts|length) == 0
    then "  (無 artifact，可能未完成或已過期)"
    else (.artifacts[] | "  • \(.name)  \(.mb)MB\(if .expired then "  [已過期]" else "" end)")
    end )
' "$CACHE"

echo ""
echo "用法：複製 run 編號與 artifact 名稱中的 variant，餵給 run-qemu，例如："
echo "  ./scripts/run-qemu.sh --run-id <RUN> --arch x86_64 --variant kasan"
