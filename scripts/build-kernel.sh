#!/usr/bin/env bash
#
# Build 單一變體的 Linux kernel。
#
# 用法:
#   VARIANT=kasan|nokasan|symbol  TARGET_ARCH=x86_64|arm64 \
#   SRC_DIR=./linux  OUT_DIR=./out \
#   ./scripts/build-kernel.sh
#
set -euo pipefail

VARIANT="${VARIANT:?需要 VARIANT (kasan|nokasan|symbol)}"
TARGET_ARCH="${TARGET_ARCH:-x86_64}"
SRC_DIR="${SRC_DIR:-./linux}"
OUT_DIR="${OUT_DIR:-./out}"
JOBS="${JOBS:-$(nproc)}"

# 本 script 所在 repo 的根目錄（用來找 configs/）
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="$REPO_ROOT/configs"

BUILD_DIR="$(cd "$SRC_DIR" && pwd)/build"   # 以 O= 做 out-of-tree build

# --- 架構相關設定 ---
case "$TARGET_ARCH" in
  x86_64)
    export ARCH=x86_64
    IMAGE_REL="arch/x86/boot/bzImage"
    ;;
  arm64)
    export ARCH=arm64
    export CROSS_COMPILE=aarch64-linux-gnu-
    IMAGE_REL="arch/arm64/boot/Image"
    ;;
  *)
    echo "不支援的架構: $TARGET_ARCH" >&2
    exit 1
    ;;
esac

# --- 組出要 merge 的 config fragment 清單 ---
FRAGMENTS=("$CONFIG_DIR/base.config")
case "$VARIANT" in
  nokasan) ;;                                          # 只有 base
  kasan)   FRAGMENTS+=("$CONFIG_DIR/kasan.config") ;;
  symbol)  FRAGMENTS+=("$CONFIG_DIR/symbol.config") ;;
  *) echo "不支援的 VARIANT: $VARIANT" >&2; exit 1 ;;
esac

echo "==> VARIANT=$VARIANT ARCH=$ARCH JOBS=$JOBS"
echo "==> fragments: ${FRAGMENTS[*]}"

cd "$SRC_DIR"

# 1) 產生基礎 defconfig
make O="$BUILD_DIR" ARCH="$ARCH" defconfig

# 2) 疊上 fragment
./scripts/kconfig/merge_config.sh -O "$BUILD_DIR" "$BUILD_DIR/.config" "${FRAGMENTS[@]}"

# 3) 解析相依、補齊預設值
make O="$BUILD_DIR" ARCH="$ARCH" olddefconfig

# 4) 編譯
make O="$BUILD_DIR" ARCH="$ARCH" -j"$JOBS"

# --- 收集產物 ---
DEST="$OUT_DIR/$VARIANT"
mkdir -p "$DEST"
cp -v "$BUILD_DIR/$IMAGE_REL" "$DEST/" 2>/dev/null || true
cp -v "$BUILD_DIR/vmlinux"    "$DEST/" 2>/dev/null || true
cp -v "$BUILD_DIR/.config"    "$DEST/config"
cp -v "$BUILD_DIR/System.map" "$DEST/" 2>/dev/null || true

# 記錄版本資訊
make O="$BUILD_DIR" ARCH="$ARCH" -s kernelrelease > "$DEST/kernelrelease.txt" 2>/dev/null || true

echo "==> 完成，產物位於 $DEST"
ls -lh "$DEST"
