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
#   # 選擇 serial console 自動登入的身分（預設一般使用者）
#   ./scripts/run-qemu.sh --variant kasan            # 以一般使用者 (user) 登入
#   ./scripts/run-qemu.sh --variant kasan --root     # 以 root 登入
#   ./scripts/run-qemu.sh --variant kasan --user bob # 指定其他使用者
#
#   # GDB 模式：QEMU 開機前暫停，等 gdb 連入（建議搭 symbol 版）
#   ./scripts/run-qemu.sh --variant symbol --gdb [--gdb-port 1234] [--nokaslr]
#   然後另開終端機: gdb vmlinux ; (gdb) target remote :1234 ; hbreak start_kernel ; c
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
MEM="${MEM:-2G}"
SMP="${SMP:-2}"
DEST="${DEST:-./downloads}"
IMAGES_DIR="${IMAGES_DIR:-./images}"
EXTRA_APPEND="${EXTRA_APPEND:-}"
GDB=0           # --gdb：開 QEMU gdbstub 並在開機前暫停
GDB_PORT="${GDB_PORT:-1234}"
NOKASLR=0       # --nokaslr：開機參數加 nokaslr（debug 方便）
FORCE=0         # --force：強制重新下載 artifact（預設有快取就重用）
LOGIN="${LOGIN:-user}"   # serial 自動登入的帳號；--root 改成 root

usage() { grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --arch)     ARCH="$2"; shift 2 ;;
    --variant)  VARIANT="$2"; shift 2 ;;
    --run-id)   RUN_ID="$2"; shift 2 ;;
    --ref)      REF="$2"; shift 2 ;;
    --kernel)   KERNEL="$2"; shift 2 ;;
    --rootfs)   ROOTFS="$2"; shift 2 ;;
    --mem)      MEM="$2"; shift 2 ;;
    --smp)      SMP="$2"; shift 2 ;;
    --root)     LOGIN="root"; shift ;;
    --user)     LOGIN="$2"; shift 2 ;;
    --force)    FORCE=1; shift ;;
    --gdb)      GDB=1; shift ;;
    --gdb-port) GDB_PORT="$2"; shift 2 ;;
    --nokaslr)  NOKASLR=1; shift ;;
    -h|--help)  usage 0 ;;
    *) echo "未知參數: $1" >&2; usage 1 ;;
  esac
done

# --- 1) 取得 kernel image ---
if [ -z "$KERNEL" ]; then
  echo "== 下載 kernel artifact =="
  ARTDIR="$(RUN_ID="$RUN_ID" VARIANT="$VARIANT" ARCH="$ARCH" REF="$REF" DEST="$DEST" FORCE="$FORCE" \
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
if [ -z "$ROOTFS" ]; then
  ROOTFS="$IMAGES_DIR/bookworm-${ARCH}.img"
  if [ ! -f "$ROOTFS" ]; then
    echo "== 建立 Debian rootfs（首次會較久）=="
    TARGET_ARCH="$ARCH" OUT="$IMAGES_DIR/bookworm-${ARCH}" "$HERE/create-image.sh"
  fi
fi
[ -f "$ROOTFS" ] || { echo "找不到 rootfs: $ROOTFS" >&2; exit 1; }
echo "== rootfs: $ROOTFS  (serial 自動登入帳號: $LOGIN) =="

# --- 3) 組 QEMU 指令 ---
[ "$NOKASLR" = "1" ] && EXTRA_APPEND="nokaslr $EXTRA_APPEND"
# login=<user> 由 guest 的 set-autologin 讀取，決定 serial console 自動登入哪個帳號
COMMON_APPEND="login=$LOGIN earlyprintk=serial net.ifnames=0 oops=panic panic_on_warn=1 panic=-1 $EXTRA_APPEND"
NET="user,id=net0"

# gdb 模式：開 gdbstub 並在第一道指令前暫停（-S），等 gdb 連入後 continue 才開機
GDB_ARGS=()
if [ "$GDB" = "1" ]; then
  GDB_ARGS=(-gdb "tcp::${GDB_PORT}" -S)
fi

case "$ARCH" in
  x86_64)
    QEMU=qemu-system-x86_64
    ACCEL=(-cpu qemu64); KVM="no"
    if [ -r /dev/kvm ] && [ -w /dev/kvm ]; then ACCEL=(-enable-kvm -cpu host); KVM="yes"; fi
    # gdb 下 KVM 的軟體中斷點不可靠，改用 TCG 以利 source-level debug
    if [ "$GDB" = "1" ]; then ACCEL=(-cpu qemu64); KVM="no(gdb)"; fi
    echo "== 加速: KVM=$KVM =="
    if [ "$KVM" = "no" ]; then
      echo "!! 未使用 KVM，x86 將以 TCG 軟體模擬執行，KASAN 版會非常慢。" >&2
      echo "!! 請確認可讀寫 /dev/kvm（例如: sudo usermod -aG kvm \$USER 後重新登入），" >&2
      echo "!! 或在 host 開啟巢狀虛擬化。" >&2
    fi
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

# 併入 gdbstub 參數（空陣列時安全展開）
QARGS+=(${GDB_ARGS[@]+"${GDB_ARGS[@]}"})

command -v "$QEMU" >/dev/null || { echo "缺少 $QEMU，請安裝對應 qemu-system 套件" >&2; exit 1; }

if [ "$GDB" = "1" ]; then
  # 找 vmlinux（symbol 版含完整 debug info，最適合 gdb）
  VMLINUX=""
  [ -f "$(dirname "$KERNEL")/vmlinux" ] && VMLINUX="$(dirname "$KERNEL")/vmlinux"
  echo "== GDB 模式：QEMU 已暫停，於另一個終端機連線 =="
  echo "   gdb ${VMLINUX:-vmlinux}"
  echo "   (gdb) target remote :$GDB_PORT"
  echo "   (gdb) hbreak start_kernel   # 建議用硬體中斷點 hbreak"
  echo "   (gdb) continue"
  [ "$NOKASLR" = "1" ] || echo "   提示：KASLR 開啟中，符號位址會偏移；需要固定位址可加 --nokaslr"
fi
echo "== 離開 QEMU: Ctrl-A 再按 X =="
echo "+ $QEMU ${QARGS[*]}"

exec "$QEMU" "${QARGS[@]}"
