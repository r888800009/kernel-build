# kernel-build

透過 GitHub Actions 手動觸發，build 不同組態的 Linux kernel：
**KASAN / no-KASAN / symbol（debug info）**。

Kernel 原始碼不放進此 repo，CI 執行時才 shallow clone 指定版本。

## 完整流程（build → 下載 → QEMU 開機）

```
GitHub Actions 手動觸發 build          ① 見「使用方式」
        │  產出 artifact: kernel-<arch>-<ref>-<variant>
        ▼
./scripts/run-qemu.sh --variant kasan  ② 一鍵完成以下三件事：
        │  ├─ 用 gh 下載該 artifact 到 downloads/   （= fetch-kernel.sh）
        │  ├─ 沒有 rootfs 就自動建一個          （= create-image.sh）
        │  └─ 用 qemu-system-<arch> 開機
        ▼
   serial console 直接登入 guest（--root / --user 選身分）
```

**最短路徑**：build 完成後，本機只要一行
`./scripts/run-qemu.sh --variant kasan` 就會下載並開機，中間步驟都自動處理。
`fetch-kernel.sh` / `create-image.sh` 只有在你想單獨做某一步時才需要直接呼叫。

## 使用方式

1. 把此 repo push 到 GitHub。
2. 到 **Actions → Build Linux Kernel → Run workflow**。
3. 填入參數後執行：

| 參數 | 說明 | 預設 |
|------|------|------|
| `kernel_source` | 來源：`mainline`(torvalds) / `stable`(gregkh) / `custom` | `mainline` |
| `kernel_repo_custom` | 自訂 repo URL（`kernel_source=custom` 時用） | （空）|
| `kernel_ref` | tag/branch/commit；**留空自動抓最新 release tag**；bare 版本號自動補 `v` | （空）|
| `arch` | `x86_64` / `arm64` / `riscv64` | `x86_64` |
| `config_base` | `syzbot`（廣譜，驅動多、編較久）或 `defconfig`（精簡）| `syzbot` |
| `build_kasan` | 是否 build KASAN 版 | ✅ |
| `build_nokasan` | 是否 build no-KASAN 版 | ✅ |
| `build_symbol` | 是否 build symbol 版 | ✅ |

各變體以 matrix 平行編譯，完成後在該次 run 的 **Artifacts** 下載，
每個 artifact 內含 `bzImage`/`Image`、`vmlinux`、`config`、`System.map`、`kernelrelease.txt`。

`kernel_ref` 可填 **tag、branch 或 commit SHA**（workflow 用 fetch + checkout，三者皆可）。

### mainline vs stable/LTS 的來源選擇

mainline（`torvalds/linux`）**只有** `vX.Y` 與 `vX.Y-rcN` 的 tag，**沒有** stable 點版（如
`v6.12.93`）。build stable/LTS 點版時把 `kernel_source` 選成 `stable`：

| 目標 | `kernel_source` | `kernel_ref` 範例 |
|------|-----------------|-------------------|
| mainline / -rc | `mainline` | `v7.3-rc5` 或某個 commit SHA |
| 特定 commit | `mainline`（該 commit 在此 tree） | `ce1e0223d8ad4211275c82a17ed6d43ab81e13d9` |
| stable / LTS 點版 | `stable` | `v6.12.93`（填 `6.12.93` 也會自動補 `v`）|
| 其他 tree | `custom` + `kernel_repo_custom` | 視該 repo 而定 |

## 三個變體差異

| 變體 | 用途 | 重點設定 |
|------|------|----------|
| **nokasan** | 乾淨 baseline / 效能 | 關閉 `KASAN`/`KCOV` |
| **kasan** | 記憶體錯誤偵測 / bug 重現 | `KASAN`、`SLUB_DEBUG` |
| **symbol** | crash 分析 / gdb | 關 `KASAN`、完整 DWARF、`KALLSYMS_ALL`、`GDB_SCRIPTS`；**保留 KASLR** |

組態是 fragment（`configs/*.config`），疊在**基底 config** 之上：
- `config_base=syzbot`：以 syzbot 上游廣譜 config 為基底（大量驅動 `=y` 編進核心），
  變體 fragment 再開/關 KASAN/debug。**驅動需求一律靠此廣譜 config 涵蓋**，不需 out-of-tree 模組。
- `config_base=defconfig`：以 `make defconfig` 為基底（精簡、編最快）。

> 註：syzbot 廣譜 config 目前內建 x86_64；arm64/riscv64 會自動退回 defconfig。

## 本機測試

CI 跑的是同一支腳本，本機也能直接用：

```bash
git clone --depth 1 https://github.com/torvalds/linux.git
VARIANT=kasan TARGET_ARCH=x86_64 SRC_DIR=./linux OUT_DIR=./out \
  ./scripts/build-kernel.sh
```

## 下載 build 好的 kernel 並用 QEMU 執行

`scripts/run-qemu.sh` 會從 GitHub Actions 抓 artifact（透過 `gh`），
必要時自動建一個 Debian rootfs，然後用 QEMU 開機（serial console 直接登入）。

```bash
# 抓最近一次成功 build 的 x86_64 kasan 版，自動建 rootfs 並開機（以一般使用者登入）
./scripts/run-qemu.sh --variant kasan

# 以 root 身分登入
./scripts/run-qemu.sh --variant kasan --root

# 指定某次 run / 架構
./scripts/run-qemu.sh --run-id 123456 --arch arm64 --variant symbol

# 用本機既有的 kernel / rootfs，不經 gh 下載
./scripts/run-qemu.sh --kernel ./downloads/.../bzImage --rootfs ./images/x.img
```

**登入身分（開機時切換，不需重建 image）**：image 內含 `root` 與一般使用者
`user`（皆空密碼，`user` 在 sudo 群組）。serial console 自動登入哪個由開機參數決定：

- 預設 → 一般使用者 `user`（適合重現非特權漏洞）
- `--root` → root
- `--user <名稱>` → 指定帳號

原理是 run-qemu.sh 把 `login=<user>` 加進 kernel cmdline，guest 內的
`set-autologin` 服務據此設定 `serial-getty` 的自動登入帳號。

常用參數：`--arch` `--variant` `--run-id` `--ref` `--kernel` `--rootfs`
`--root` / `--user <名稱>` `--devtools`（image 內加 gcc/make/libc-dev，就地編
userspace PoC）`--mem` `--smp`。離開 QEMU：`Ctrl-A` 再 `X`。

### GDB 除錯模式

`--gdb` 會開 QEMU 的 gdbstub 並在開機前暫停，等你用 gdb 連入（最適合搭 `symbol` 版的 `vmlinux`）：

```bash
./scripts/run-qemu.sh --variant symbol --gdb          # 預設 port 1234
# 另開一個終端機：
gdb downloads/kernel-x86_64-*-symbol/vmlinux
(gdb) target remote :1234
(gdb) hbreak start_kernel      # 用硬體中斷點較可靠
(gdb) continue
```

x86 在 `--gdb` 下會自動改用 TCG（KVM 的軟體中斷點不可靠）。KASLR 會讓符號位址偏移，
需要固定位址時加 `--nokaslr`（開機參數，不必重新 build）。`--gdb-port` 可改 port。

### 查詢有哪些 build 與 artifact

`list-builds.sh` 列出最近的 build run 與各自的 artifact 名稱，結果快取在本機
（預設 600 秒內重複查詢免打 API）：

```bash
./scripts/list-builds.sh              # 最近 10 筆
./scripts/list-builds.sh --limit 20   # 多列幾筆
./scripts/list-builds.sh --refresh    # 忽略快取、強制重查
./scripts/list-builds.sh --json       # 原始 JSON（給程式用）
```

輸出會列出每個 run 的編號、狀態、時間與 artifact（`kernel-<arch>-<ref>-<variant>` 及大小），
挑好後把 run 編號與 variant 餵給 `run-qemu.sh`。快取在 `downloads/.cache/`（已 gitignore）。

### 只想下載、不開機

`run-qemu.sh` 已內含下載；若只想單獨抓檔，用 `fetch-kernel.sh`：

```bash
./scripts/fetch-kernel.sh --variant kasan           # 最近一次成功 run
./scripts/fetch-kernel.sh --variant symbol --arch arm64 --run-id 123456
```

artifact 會解壓到 `downloads/kernel-<arch>-<ref>-<variant>/`，內含
`bzImage`/`Image`、`vmlinux`、`System.map`、`config`（最後一行印出該目錄）。
之後要開機，把裡面的 image 路徑丟給 `run-qemu.sh`：

```bash
./scripts/run-qemu.sh --kernel downloads/kernel-x86_64-v6.12-kasan/bzImage
```

### 需求：
- `gh`（已 `gh auth login`）— 下載 artifact 用
- `qemu-system-<arch>` — x86_64 有 `/dev/kvm` 會自動用 KVM
- 自動建 rootfs 需 `sudo` + `debootstrap`；跨架構另需 `qemu-user-static binfmt-support`

rootfs 預設放在 `images/`（已被 gitignore），建好後會快取重用、不會重建。

### rootfs 相關環境變數

| 變數 | 說明 | 預設 |
|------|------|------|
| `MIRROR` | Debian 鏡像；**預設已用台灣 NCHC** | `http://free.nchc.org.tw/debian` |
| `WITH_DEVTOOLS` | 設 `1` 時在 image 內加裝 `gcc/libc6-dev/make`（在 guest 編 reproducer 用） | 關 |
| `RELEASE` | Debian 版本代號 | `bookworm` |
| `SIZE_MB` | image 大小（MB） | `2048` |

海外環境可覆蓋鏡像：`MIRROR=http://deb.debian.org/debian ./scripts/run-qemu.sh --variant kasan`

### 重建 rootfs（重來一次）

rootfs 壞了或想換設定時，先清掉再跑（直接刪整個 `images/` 最保險，
zsh 下對不存在的萬用字元會報錯，故不要用 `images/chroot.*` 這種寫法）：

```bash
sudo rm -rf images
./scripts/run-qemu.sh --variant kasan
```

## 結構

```
.github/workflows/build-kernel.yml   # 手動觸發的 build workflow
configs/base.config                  # 所有變體共用（VM/virtio 可開機）
configs/kasan.config                 # 開 KASAN
configs/nokasan.config               # 關 KASAN/KCOV
configs/symbol.config                # debug info / 符號
scripts/build-kernel.sh              # 單一變體 build 邏輯
scripts/list-builds.sh               # 查詢 runs 與 artifact 名稱（本機快取）
scripts/fetch-kernel.sh              # 用 gh 下載 artifact
scripts/create-image.sh              # 建 Debian rootfs（debootstrap）
scripts/run-qemu.sh                  # 下載 + 建 rootfs + QEMU 開機（主入口）
```
