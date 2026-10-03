# kernel-build

透過 GitHub Actions 手動觸發，build 不同組態的 Linux kernel：
**KASAN / no-KASAN / symbol（debug info）**。

Kernel 原始碼不放進此 repo，CI 執行時才 shallow clone 指定版本。

## 使用方式

1. 把此 repo push 到 GitHub。
2. 到 **Actions → Build Linux Kernel → Run workflow**。
3. 填入參數後執行：

| 參數 | 說明 | 預設 |
|------|------|------|
| `kernel_repo` | kernel git repo URL | `torvalds/linux` |
| `kernel_ref` | tag/branch/commit；**留空則自動抓最新 stable release tag** | （空）|
| `arch` | `x86_64` / `arm64` / `riscv64` | `x86_64` |
| `build_kasan` | 是否 build KASAN 版 | ✅ |
| `build_nokasan` | 是否 build no-KASAN 版 | ✅ |
| `build_symbol` | 是否 build symbol 版 | ✅ |

各變體以 matrix 平行編譯，完成後在該次 run 的 **Artifacts** 下載，
每個 artifact 內含 `bzImage`/`Image`、`vmlinux`、`config`、`System.map`、`kernelrelease.txt`。

## 三個變體差異

| 變體 | 用途 | 重點設定 |
|------|------|----------|
| **nokasan** | 乾淨 baseline / 效能 | 只套 `configs/base.config` |
| **kasan** | fuzzing / 記憶體錯誤偵測 | `KASAN`、`KCOV`、`SLUB_DEBUG` |
| **symbol** | crash 分析 / gdb | 完整 DWARF、`KALLSYMS_ALL`、`GDB_SCRIPTS`；**保留 KASLR** 以反映實際位址分布 |

組態定義在 `configs/*.config`（fragment，疊在 `make defconfig` 之上）。

## 本機測試

CI 跑的是同一支腳本，本機也能直接用：

```bash
git clone --depth 1 https://github.com/torvalds/linux.git
VARIANT=kasan TARGET_ARCH=x86_64 SRC_DIR=./linux OUT_DIR=./out \
  ./scripts/build-kernel.sh
```

## 下載 build 好的 kernel 並用 QEMU 執行

`scripts/run-qemu.sh` 會從 GitHub Actions 抓 artifact（透過 `gh`），
必要時自動建一個帶 ssh 的 Debian rootfs，然後用 QEMU 開機。

```bash
# 抓最近一次成功 build 的 x86_64 kasan 版，自動建 rootfs 並開機（serial console）
./scripts/run-qemu.sh --variant kasan

# 指定某次 run / 架構，開機後直接 ssh 進去
./scripts/run-qemu.sh --run-id 123456 --arch arm64 --variant symbol --ssh

# 用本機既有的 kernel / rootfs，不經 gh 下載
./scripts/run-qemu.sh --kernel ./downloads/.../bzImage --rootfs ./images/x.img
```

常用參數：`--arch` `--variant` `--run-id` `--ref` `--kernel` `--rootfs`
`--ssh`（開機後自動 ssh）`--ssh-port` `--mem` `--smp`。離開 QEMU：`Ctrl-A` 再 `X`。

需求：
- `gh`（已 `gh auth login`）— 下載 artifact 用
- `qemu-system-<arch>` — x86_64 有 `/dev/kvm` 會自動用 KVM
- 自動建 rootfs 需 `sudo` + `debootstrap`；跨架構另需 `qemu-user-static binfmt-support`

rootfs 與 ssh 金鑰預設放在 `images/`（已被 gitignore）。

## 結構

```
.github/workflows/build-kernel.yml   # 手動觸發的 build workflow
configs/base.config                  # 所有變體共用（VM/virtio 可開機）
configs/kasan.config                 # KASAN + KCOV
configs/symbol.config                # debug info / 符號
scripts/build-kernel.sh              # 單一變體 build 邏輯
scripts/fetch-kernel.sh              # 用 gh 下載 artifact
scripts/create-image.sh              # 建 Debian rootfs（debootstrap）
scripts/run-qemu.sh                  # 下載 + 建 rootfs + QEMU 開機（主入口）
```
