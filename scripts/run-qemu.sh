#!/usr/bin/env bash
#
# 抓 kernel artifact（或用本機 image）並以 QEMU 開機。
#
# 常用:
#   # 抓最近一次成功 build 的 x86_64 kasan 版，自動建 rootfs 並開機
#   ./scripts/run-qemu.sh --variant kasan
#
#   # 指定 run / 架構 / 已有 image
#   ./scripts/run-qemu.sh --run-id 123456 --arch arm64 --variant symbol
#   ./scripts/run-qemu.sh --kernel ./downloads/.../bzImage --rootfs ./images/x.img
#
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 預設值
ARCH="x86_64"
VARIANT="nokasan"
RUN_ID=""
REF=""
KERNEL=""
ROOTFS=""
SSH_PORT="${SSH_PORT:-10022}"
MEM="${MEM:-2G}"
SMP="${SMP:-2}"
DEST="${DEST:-./downloads}"
IMAGES_DIR="${IMAGES_DIR:-./images}"
EXTRA_APPEND="${EXTRA_APPEND:-}"
SSH=0           # --ssh：開機後直接 ssh 進去

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)     ARCH="$2"; shift 2 ;;
    --variant)  VARIANT="$2"; shift 2 ;;
    --run-id)   RUN_ID="$2"; shift 2 ;;
    --ref)      REF="$2"; shift 2 ;;
    --kernel)   KERNEL="$2"; shift 2 ;;
    --rootfs)   ROOTFS="$2"; shift 2 ;;
    --ssh-port) SSH_PORT="$2"; shift 2 ;;
    --mem)      MEM="$2"; shift 2 ;;
    --smp)      SMP="$2"; shift 2 ;;
    --ssh)      SSH=1; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "未知參數: $1" >&2; usage 1 ;;
  esac
done

# --- 1) 取得 kernel image ---
if [ -z "$KERNEL" ]; then
  echo "== 下載 kernel artifact =="
  ARTDIR="$(RUN_ID="$RUN_ID" VARIANT="$VARIANT" ARCH="$ARCH" REF="$REF" DEST="$DEST" \
    "$HERE/fetch-kernel.sh" | tail -1)"
  # 依架構挑 image 檔
  case "$ARCH" in
    x86_64) KERNEL="$ARTDIR/bzImage" ;;
    *)      KERNEL="$ARTDIR/Image" ;;
  esac
fi
[ -f "$KERNEL" ] || { echo "找不到 kernel image: $KERNEL" >&2; exit 1; }
echo "== kernel: $KERNEL =="

# --- 2) 取得 / 建立 rootfs ---
SSH_KEY=""
if [ -z "$ROOTFS" ]; then
  ROOTFS="$IMAGES_DIR/bookworm-${ARCH}.img"
  if [ ! -f "$ROOTFS" ]; then
    echo "== 建立 Debian rootfs（首次會較久）=="
    TARGET_ARCH="$ARCH" OUT="$IMAGES_DIR/bookworm-${ARCH}" "$HERE/create-image.sh"
  fi
fi
[ -f "$ROOTFS" ] || { echo "找不到 rootfs: $ROOTFS" >&2; exit 1; }
# 對應的 ssh key（若由本工具建立）
[ -f "${ROOTFS%.img}.id_rsa" ] && SSH_KEY="${ROOTFS%.img}.id_rsa"
echo "== rootfs: $ROOTFS =="

# --- 3) 組 QEMU 指令 ---
COMMON_APPEND="earlyprintk=serial net.ifnames=0 oops=panic panic_on_warn=1 panic=-1 $EXTRA_APPEND"
NET="user,id=net0,hostfwd=tcp:127.0.0.1:${SSH_PORT}-:22"

case "$ARCH" in
  x86_64)
    QEMU=qemu-system-x86_64
    ACCEL=(-cpu qemu64)
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); fi
    QARGS=(
      "${ACCEL[@]}" -m "$MEM" -smp "$SMP"
      -kernel "$KERNEL"
      -append "console=ttyS0 root=/dev/sda rw $COMMON_APPEND"
      -drive file="$ROOTFS",format=raw,if=ide
      -netdev "$NET" -device e1000,netdev=net0
      -nographic -no-reboot
    )
    ;;
  arm64)
    QEMU=qemu-system-aarch64
    QARGS=(
      -machine virt -cpu cortex-a57 -m "$MEM" -smp "$SMP"
      -kernel "$KERNEL"
      -append "console=ttyAMA0 root=/dev/vda rw $COMMON_APPEND"
      -drive file="$ROOTFS",format=raw,if=none,id=hd0 -device virtio-blk-device,drive=hd0
      -netdev "$NET" -device virtio-net-device,netdev=net0
      -nographic -no-reboot
    )
    ;;
  riscv64)
    QEMU=qemu-system-riscv64
    QARGS=(
      -machine virt -m "$MEM" -smp "$SMP"
      -kernel "$KERNEL"
      -append "console=ttyS0 root=/dev/vda rw $COMMON_APPEND"
      -drive file="$ROOTFS",format=raw,if=none,id=hd0 -device virtio-blk-device,drive=hd0
      -netdev "$NET" -device virtio-net-device,netdev=net0
      -nographic -no-reboot
    )
    ;;
  *) echo "不支援的架構: $ARCH" >&2; exit 1 ;;
esac

command -v "$QEMU" >/dev/null || { echo "缺少 $QEMU，請安裝對應 qemu-system 套件" >&2; exit 1; }

if [ -n "$SSH_KEY" ]; then
  echo "== 開機後可用: ssh -i $SSH_KEY -p $SSH_PORT root@127.0.0.1 =="
fi
echo "== 離開 QEMU: Ctrl-A 再按 X =="
echo "+ $QEMU ${QARGS[*]}"

if [ "$SSH" = "1" ] && [ -n "$SSH_KEY" ]; then
  # 背景開機，等 ssh port 通了再連入
  "$QEMU" "${QARGS[@]}" &
  QPID=$!
  trap 'kill $QPID 2>/dev/null || true' EXIT
  echo "== 等待 ssh ($SSH_PORT) 就緒 =="
  for _ in $(seq 1 60); do
    if ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 \
        root@127.0.0.1 true 2>/dev/null; then
      break
    fi
    sleep 2
  done
  ssh -i "$SSH_KEY" -p "$SSH_PORT" -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null root@127.0.0.1
else
  exec "$QEMU" "${QARGS[@]}"
fi
