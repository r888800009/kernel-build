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
| `arch` | `x86_64` 或 `arm64` | `x86_64` |
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

## 結構

```
.github/workflows/build-kernel.yml   # 手動觸發的 build workflow
configs/base.config                  # 所有變體共用（VM/virtio 可開機）
configs/kasan.config                 # KASAN + KCOV
configs/symbol.config                # debug info / 符號
scripts/build-kernel.sh              # 單一變體 build 邏輯
```
