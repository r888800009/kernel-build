#!/usr/bin/env bash
#
# 建立一個可供 QEMU 開機的 Debian rootfs（syzkaller 風格）。
# 產出：$OUT.img（ext4 raw image）+ $OUT.id_rsa（ssh 私鑰）
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
PKGS="${PKGS:-systemd-sysv,udev,openssh-server,ca-certificates,curl,tar,time,strace,less,psmisc,kmod}"
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
# serial console 自動登入 root、空密碼、主機名、網路、ssh
sudo tee "$CHROOT/etc/hostname" >/dev/null <<<"syzkaller"

sudo sed -i '/^root:/ s#^root:[^:]*:#root::#' "$CHROOT/etc/shadow"  # 空密碼

# serial tty 自動登入（systemd）
sudo mkdir -p "$CHROOT/etc/systemd/system/serial-getty@ttyS0.service.d"
sudo tee "$CHROOT/etc/systemd/system/serial-getty@ttyS0.service.d/override.conf" >/dev/null <<'EOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I 115200 linux
EOF

# 網路（DHCP，介面名 net.ifnames=0 -> eth0）
# 注意 Match 不要用裸 '*'，否則連 lo 都比對、networkd 會在 loopback 上嘗試 DHCP。
sudo tee "$CHROOT/etc/systemd/network/10-eth.network" >/dev/null <<'EOF'
[Match]
Name=en* eth*
[Network]
DHCP=yes
EOF

# 正確啟用/停用服務（用 systemctl --root 離線操作 chroot 的 unit）
# 啟用：networkd、ssh、serial 自動登入
sudo systemctl --root="$CHROOT" enable systemd-networkd.service ssh.service \
  serial-getty@ttyS0.service 2>/dev/null || true
# 停用會搶 CPU / 拖慢開機 / 與除錯無關的噪音服務。
# 其中 networkd-wait-online 常讓開機卡住；慢速 TCG 下尤其要關。
sudo systemctl --root="$CHROOT" mask \
  systemd-networkd-wait-online.service \
  apt-daily.timer apt-daily-upgrade.timer \
  e2scrub_all.timer e2scrub_reap.service \
  fstrim.timer dpkg-db-backup.timer 2>/dev/null || true

# 慢速 TCG 下把 systemd 預設逾時調短，避免 90s 的裝置/服務等待
sudo mkdir -p "$CHROOT/etc/systemd/system.conf.d"
sudo tee "$CHROOT/etc/systemd/system.conf.d/timeout.conf" >/dev/null <<'EOF'
[Manager]
DefaultTimeoutStartSec=30s
DefaultDeviceTimeoutSec=30s
EOF

# ssh：允許 root 以金鑰登入
sudo mkdir -p "$CHROOT/root/.ssh"
ssh-keygen -q -t rsa -N "" -f "$OUT.id_rsa" <<<y >/dev/null
sudo cp "$OUT.id_rsa.pub" "$CHROOT/root/.ssh/authorized_keys"
sudo tee -a "$CHROOT/etc/ssh/sshd_config" >/dev/null <<'EOF'
PermitRootLogin yes
PubkeyAuthentication yes
PasswordAuthentication yes
PermitEmptyPasswords yes
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
echo "    ssh key: $OUT.id_rsa"
