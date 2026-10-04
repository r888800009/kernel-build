#!/usr/bin/env bash
#
# 建立一個可供 QEMU 開機的 Debian rootfs（syzkaller 風格）。
# 產出：$OUT.img（ext4 raw image）
# 內含 root（空密碼）；serial console 自動登入哪個帳號由開機參數 login=<user>
# 決定，非 root 帳號若不存在會在首次開機自動建立（見 run-qemu.sh 的 --root / --user）。
#
# 用法:
#   TARGET_ARCH=x86_64|arm64|riscv64  RELEASE=bookworm  OUT=./images/bookworm \
#   SIZE_MB=2048  ./scripts/create-image.sh
#
# 需求: sudo、debootstrap；跨架構時需 qemu-user-static + binfmt-support。
set -euo pipefail

TARGET_ARCH="${TARGET_ARCH:-x86_64}"
RELEASE="${RELEASE:-bookworm}"
OUT="${OUT:-./images/${RELEASE}-${TARGET_ARCH}}"
SIZE_MB="${SIZE_MB:-2048}"

# 額外要裝進 image 的套件（逗號分隔）
# 用 minbase 只裝最小基底加速，但 minbase 不含 init，必須明確補上
# systemd（開機、serial-getty、networkd）等必要套件。
# 預設不含 gcc/binutils（下載最肥的一組）；需要在 guest 內編譯時設 WITH_DEVTOOLS=1。
PKGS="${PKGS:-systemd-sysv,udev,passwd,sudo,ca-certificates,iproute2,iputils-ping,curl,tar,time,strace,less,psmisc,kmod}"

if [ "${WITH_DEVTOOLS:-0}" = "1" ]; then
  PKGS="$PKGS,gcc,libc6-dev,make"
fi

# Debian mirror。預設用台灣 NCHC 鏡像（較快）；海外環境可覆蓋成
# MIRROR=http://deb.debian.org/debian 或其他較近的鏡像。
MIRROR="${MIRROR:-http://free.nchc.org.tw/debian}"

# TARGET_ARCH -> debian 架構 / qemu-user 名稱
case "$TARGET_ARCH" in
  x86_64)  DEBARCH=amd64   ; QEMUUSER=x86_64  ;;
  arm64)   DEBARCH=arm64   ; QEMUUSER=aarch64 ;;
  riscv64) DEBARCH=riscv64 ; QEMUUSER=riscv64 ;;
  *) echo "不支援的架構: $TARGET_ARCH" >&2; exit 1 ;;
esac

HOSTARCH="$(dpkg --print-architecture 2>/dev/null || echo amd64)"

command -v debootstrap >/dev/null || {
  echo "缺少 debootstrap，請先: sudo apt-get install -y debootstrap" >&2; exit 1; }

OUT_DIR="$(dirname "$OUT")"
mkdir -p "$OUT_DIR"
OUT="$(cd "$OUT_DIR" && pwd)/$(basename "$OUT")"

# chroot 必須放在支援裝置節點的檔案系統上（不能是帶 nodev 的 /tmp，
# 否則 debootstrap 的 test-dev-null 會 Permission denied）。
# 放在輸出目錄旁（通常為一般磁碟）。
CHROOT="$(mktemp -d -p "$OUT_DIR" chroot.XXXXXX)"
trap 'sudo rm -rf "$CHROOT"' EXIT

echo "==> debootstrap $RELEASE ($DEBARCH) 於 $CHROOT"
echo "    首次會下載數百 MB 套件，約需數分鐘（下方會顯示進度）"
echo "    mirror=$MIRROR"
if [ "$DEBARCH" = "$HOSTARCH" ]; then
  sudo debootstrap --variant=minbase --components=main \
    --include="$PKGS" "$RELEASE" "$CHROOT" "$MIRROR"
else
  # 跨架構：first stage + qemu-user-static 做 second stage
  command -v "qemu-$QEMUUSER-static" >/dev/null || {
    echo "跨架構需要 qemu-$QEMUUSER-static，請: sudo apt-get install -y qemu-user-static binfmt-support" >&2
    exit 1; }
  sudo debootstrap --foreign --variant=minbase --arch="$DEBARCH" \
    --components=main --include="$PKGS" "$RELEASE" "$CHROOT" "$MIRROR"
  sudo cp "$(command -v qemu-$QEMUUSER-static)" "$CHROOT/usr/bin/"
  sudo chroot "$CHROOT" /debootstrap/debootstrap --second-stage
fi

echo "==> 設定 image 內系統"
# 空密碼、主機名、一般使用者、serial 自動登入（帳號由 cmdline login= 決定）、網路
sudo tee "$CHROOT/etc/hostname" >/dev/null <<<"syzkaller"

# /etc/hosts：把主機名對到 127.0.1.1，避免 sudo 解析主機名失敗的警告
sudo tee "$CHROOT/etc/hosts" >/dev/null <<'EOF'
127.0.0.1	localhost
127.0.1.1	syzkaller
::1		localhost ip6-localhost ip6-loopback
EOF

# DNS：QEMU user-net 的 DNS forwarder 在 10.0.2.3；再加公共備援
sudo tee "$CHROOT/etc/resolv.conf" >/dev/null <<'EOF'
nameserver 10.0.2.3
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF

sudo sed -i '/^root:/ s#^root:[^:]*:#root::#' "$CHROOT/etc/shadow"  # root 空密碼

# serial 自動登入帳號完全由 kernel cmdline 的 login=<user> 決定（run-qemu.sh
# 的 --root / --user <名稱> 會設定它）。getty 直接呼叫這支 wrapper：開機當下
# 讀 /proc/cmdline，若指定的非 root 帳號不存在就「當場建立」（空密碼、sudo 群組），
# 因此用參數切任何帳號都免重建 image、也不需環境變數。
sudo install -d -m755 "$CHROOT/usr/local/sbin"
sudo tee "$CHROOT/usr/local/sbin/autologin-getty" >/dev/null <<'EOF'
#!/bin/sh
# 用法: autologin-getty <tty>
u=root
for tok in $(cat /proc/cmdline); do
  case "$tok" in login=*) u="${tok#login=}" ;; esac
done
if [ "$u" != root ] && ! id "$u" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$u" 2>/dev/null
  passwd -d "$u" >/dev/null 2>&1          # 空密碼
fi
id "$u" >/dev/null 2>&1 || u=root          # 萬一仍失敗則 fallback root
exec /sbin/agetty --autologin "$u" --noclear "$1" 115200 linux
EOF
sudo chmod +x "$CHROOT/usr/local/sbin/autologin-getty"

sudo mkdir -p "$CHROOT/etc/systemd/system/serial-getty@ttyS0.service.d"
sudo tee "$CHROOT/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/usr/local/sbin/autologin-getty %I
EOF

# 網路：直接用 QEMU slirp（user-net）的固定位址設定介面，不依賴 networkd/DHCP。
# slirp 固定給：IP 10.0.2.15/24、gateway 10.0.2.2、DNS 10.0.2.3。
# 這樣最確定；run-qemu.sh 一律使用 user-net，所以位址固定。
sudo tee "$CHROOT/usr/local/sbin/qemu-net" >/dev/null <<'EOF'
#!/bin/sh
# 把第一個非 lo 介面以 slirp 固定位址帶起來
iface=$(ip -o link show 2>/dev/null | awk -F': ' '$2!="lo"{print $2; exit}')
[ -n "$iface" ] || exit 0
ip link set "$iface" up
ip addr show dev "$iface" | grep -q 'inet ' || ip addr add 10.0.2.15/24 dev "$iface"
ip route replace default via 10.0.2.2
EOF
sudo chmod +x "$CHROOT/usr/local/sbin/qemu-net"

sudo tee "$CHROOT/etc/systemd/system/qemu-net.service" >/dev/null <<'EOF'
[Unit]
Description=QEMU slirp networking (static)
Wants=network.target
Before=network.target network-online.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/qemu-net
[Install]
WantedBy=multi-user.target
EOF

# 以直接建立 symlink 的方式啟用服務（不依賴 systemctl --root 在跨發行版 host 的行為）
sudo mkdir -p "$CHROOT/etc/systemd/system/multi-user.target.wants"
sudo ln -sf /etc/systemd/system/qemu-net.service \
  "$CHROOT/etc/systemd/system/multi-user.target.wants/qemu-net.service"

# 停用會搶 CPU / 拖慢開機 / 與除錯無關的噪音服務（用 mask 連到 /dev/null）
for u in systemd-networkd-wait-online.service \
         apt-daily.timer apt-daily-upgrade.timer \
         e2scrub_all.timer e2scrub_reap.service \
         fstrim.timer dpkg-db-backup.timer; do
  sudo ln -sf /dev/null "$CHROOT/etc/systemd/system/$u"
done

# 慢速 TCG 下把 systemd 預設逾時調短，避免 90s 的裝置/服務等待
sudo mkdir -p "$CHROOT/etc/systemd/system.conf.d"
sudo tee "$CHROOT/etc/systemd/system.conf.d/timeout.conf" >/dev/null <<'EOF'
[Manager]
DefaultTimeoutStartSec=30s
DefaultDeviceTimeoutSec=30s
EOF

# fstab：根目錄
sudo tee "$CHROOT/etc/fstab" >/dev/null <<'EOF'
/dev/root / ext4 defaults 0 0
EOF

echo "==> 打包成 ext4 image ($SIZE_MB MB): $OUT.img"
dd if=/dev/zero of="$OUT.img" bs=1M count="$SIZE_MB" status=none
mkfs.ext4 -q -F "$OUT.img"
MNT="$(mktemp -d)"
sudo mount -o loop "$OUT.img" "$MNT"
sudo cp -a "$CHROOT"/. "$MNT"/
sudo umount "$MNT"
rmdir "$MNT"

echo "==> 完成:"
echo "    image: $OUT.img"
echo "    帳號: root（空密碼）；一般使用者由開機參數 login=<user> 指定、首次開機自動建立"
