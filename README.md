# Framework Laptop 12 s2idle 耗電問題：調查記錄與維護筆記

> [!WARNING]
> **This repository is supporting material for a bug report, not a supported fix.**
> The `fw12_rtd3_fix` kernel module alters ACPI runtime state to change NVMe / PCIe
> power management. It was tested only on one Framework Laptop 12 (i5-1334U,
> BIOS 03.07–03.09, Debian 13, kernel 7.1/7.2). It may cause data loss, failure to
> resume, or an unbootable system on any other configuration. Provided AS IS,
> without warranty of any kind (see LICENSE). Use entirely at your own risk.
>
> **本 repo 是 bug report 的佐證資料，不是提供給大家使用的修正方案。** `fw12_rtd3_fix` 會修改
> ACPI 執行期狀態，改變 NVMe／PCIe 的電源管理。它只在一台 Framework Laptop 12 上測試過，
> 在其他環境可能造成資料遺失、無法喚醒或無法開機。本專案依現狀提供，不附任何保證，
> 使用風險自負。

> 調查日期：2026-10-01
> 機器：Framework Laptop 12（13th Gen Intel Core，i5-1334U），BIOS 03.07 → 03.08，Debian 13 / kernel 7.1.13
> 結果：sleep 耗電從每小時 3～5%（一晚約 30%）降到每小時約 1%
> 2026-10-13 更新：kernel 7.2 讓 module 1.0 失效，改版成 1.1（見第 8 節）。目前環境：BIOS 03.09，kernel 7.2.6

## 1. 結論

**根本原因：** BIOS 把 GNVS 變數 `STD3`（Storage RTD3 設定）設成 **1**，不是 2。開機時 `PEG0._INI` 會把它複製到 `\_SB.PC00.PEG0.RD3C`。`RD3C != 2` 會造成兩件事：

1. `PEG0._S0W` 回傳 **0**，所以 kernel 在 s2idle 時必須讓 NVMe 的 CPU 端 PCIe root port（`00:06.0`）**維持在 D0**
2. `PEG0.GPRS` 回傳 0，所以 power resource `PXP` 的 `_OFF`/`_ON` 什麼都不做（不會切掉 SSD 的電源 GPIO）

root port 一直有供電，CPU package 最深只能到 PC3，**完全進不了 S0ix**。

**解法：** 自己寫的 DKMS module `fw12_rtd3_fix`。開機時載入一張只有一個小 method 的 SSDT，用它把 `RD3C` 設成 2，之後 BIOS 原本就有的 RTD3 路徑就會正常運作：root port 和 SSD 在 sleep 時進到 D3cold，package 到 PC10，S0i3 residency 佔 sleep 時間的 99.8%。

BIOS 設定畫面裡**沒有**這個選項。BIOS 03.07、03.08、03.09 都有這個問題。

## 2. 因果鏈

```
BIOS GNVS: STD3 = 1
  └─ PEG0._INI: RD3C = STD3 (= 1)            ← 只在 PEGP 是 NVMe/AHCI 時套用
       ├─ PEGP._DSD: StorageD3Enable = 1     ← STD3 != 0 就會給
       │    └─ nvme driver 走 simple suspend，SSD 進 D3hot
       ├─ PEG0._S0W → 0 (D0)                  ← RD3C != 2
       │    └─ kernel：root port 00:06.0 停在 D0（"PCI PM: Skipped"）
       └─ PEG0.GPRS → 0                       ← RD3C != 2
            └─ PXP._OFF 不切電
  ⇒ root port 和 link 保持供電（只到 L1，沒有 L1.2 或 L2/L3）
  ⇒ CPU package 卡在 PC2/PC3，PC6～PC10 = 0
  ⇒ SLP_S0 / S0ix residency = 0，耗電 3～5%/h
```

關鍵的 ACPI 程式碼在 `acpi/SSDT4.dsl`（SaSsdt，`PEG0._INI` 約第 195～215 行）和 `acpi/SSDT8.dsl`（ADL-P-M，`PEG0._S0W` 約第 1471 行、`PXP` 約第 1508 行、`GPRS` 約第 1590 行）。

**一個容易誤解的地方：** 在 S0（s2idle）時，kernel 的 `acpi_dev_pm_get_state()` 只要裝置有 `_PRW` 就**一律**套用 `_S0W`，不會看 sysfs 的 `power/wakeup`。所以把 root port 的 wakeup 關掉沒有用（第三輪實測）。

## 3. 調查過程

| 輪次 | BIOS | 變數 / 修改 | 結果 | 學到的事 |
|---|---|---|---|---|
| 0 | 03.07 | 平常閒置測量 | package 只到 C2/C3 | fluidsynth 一直開著音訊串流，HDA 不會休眠（影響平常閒置的耗電）。外接螢幕和不支援 PSR 的面板讓閒置測量不準，**之後只能靠實際 sleep 來判斷** |
| 1 | 03.07 | 第一次實測 | S0ix = 0，5%/h | 確認沒進 S0ix，sleep 中途也沒有被喚醒 |
| 2 | 03.07 | `warn_on_s0ix_failures` | `CPU did not enter Package C10` | 問題在 CPU 端，PC6 以上全部是 0。排除 MSR 0xE2 限制、GPU RC6 |
| — | 03.08 | Intel S0ixSelftestTool | 發現 root port 00:06.0 停在 D0，link 只有 L1 | 這是關鍵線索 |
| 3 | 03.08 | 關掉 00:06.0 的 wakeup | 沒效果 | 原因見上面「容易誤解的地方」 |
| 4 | 03.08 | 拔掉 SD 卡 + PCI PM debug | 沒效果 | SD 卡不是主因。確認 root port 還是 `Skipped` |
| 5 | 03.08 | GNA（00:08.0）用 setpci 放進 D3 | 沒效果 | GNA 排除 |
| 6 | 03.08 | kprobe `acpi_pm_device_sleep_state` | 00:06.0 回傳 0、NVMe 回傳 3 | **證實是 `_S0W` 把 root port 鎖在 D0** |
| — | 03.08 | 讀 GNVS | `STD3=1`，SSD 的 GPIO 有設定 | 確認強開 RTD3 是安全的 |
| 7 | 03.08 | `nvme.noacpi=1` | **更糟**（只到 PC2，6%/h） | SSD 留在 D0 比 D3hot 更差 |
| 8 | 03.08 | initrd 覆寫 SSDT4（RD3C=2） | **S0i3 99.8%，0.9%/h** | 修正有效 |
| 9 | 03.08 | `fw12_rtd3_fix` module | **S0i3 99.8%，1.2%/h**（有插 SD 卡） | module 方案有效，不需要替換 ACPI table |

## 4. module：`fw12_rtd3_fix`

### 位置
- 原始碼（工作副本）：`module/`
- DKMS 原始碼：`/usr/src/fw12-rtd3-fix-1.1/`
- 1.0 版備份：`module.v1.0-bak/`（使用 `acpi_install_method()`，在 kernel 7.2 上會失敗）
- 編譯產物：`/lib/modules/<kernel>/updates/dkms/fw12_rtd3_fix.ko.xz`

### 檔案
| 檔案 | 用途 |
|---|---|
| `fw12_rtd3_fix.c` | module 本體 |
| `rd3c_method.asl` | 要載入的 SSDT 原始碼，裡面只有 `\_SB.PC00.PEG0.FXRD(Arg0)`：把 `RD3C` 設成 `Arg0`，再回傳設定後的值 |
| `rd3c_method.h` | 上面那張 SSDT 編譯成的 AML byte array（由 xxd 產生） |
| `Makefile` / `dkms.conf` | 編譯和 DKMS 設定 |

### 運作流程
1. 透過 DMI（`svnFramework`、`pnLaptop12(13thGenIntelCore)`）由 udev **自動載入**，不需要 `modules-load.d`
2. 讀取 `\_SB.PC00.PEG0.RD3C`。如果已經是 2 就不做任何事（例如 BIOS 修正之後，或有載入 cpio override 時）
3. 安全檢查：`PEG0.PEGP.PNVM()` 必須為真（底下是 NVMe），`\SD2P` 和 `\SD2R` 都不能是 0（BIOS 有設定 SSD 的電源/reset GPIO）。**`\PIN.ON/OFF` 完全不檢查 GPIO 編號，如果是 0 會誤動到別的腳位**
4. 把 `rd3c_method_aml` 用 `kmemdup` 複製一份，再用 `acpi_load_table()` 載入（dmesg 會出現 `Host-directed Dynamic ACPI Table Load` 和 `SSDT ... FW12FX RD3CFIX`），接著執行 `FXRD(2)`，並確認回傳值是 2。如果失敗，會把 table 卸載
5. `rmmod` 時執行 `FXRD(原值)` 恢復原狀，再用 `acpi_unload_table()` 把 `FXRD` 從 namespace 移除

**為什麼要 `kmemdup`，而且永遠不釋放：** `acpi_load_table()` 是以 `ACPI_TABLE_ORIGIN_EXTERNAL_VIRTUAL` 安裝 table，ACPICA 會一直保留這個指標，**`acpi_unload_table()` 之後也不會丟掉**。再次 `insmod` 時，ACPICA 會拿新的 table 跟舊的 descriptor 比對，發現內容相同就直接沿用（所以第二次載入不會再印出 `SSDT ...` 那一行）。如果傳的是 module 自己的 static 陣列，`rmmod` 之後這個指標就會指向已釋放的記憶體。每次載入只會留下約 114 bytes。

用到的 kernel API 只有 `acpi_load_table()`、`acpi_unload_table()`、`acpi_evaluate_integer()`、`dmi_check_system()`，都是穩定的 export symbol。

### 常用操作
```bash
# 看狀態
dkms status fw12-rtd3-fix
dmesg | grep fw12_rtd3_fix          # 應該出現 "RD3C 1 -> 2, NVMe root port RTD3 enabled"

# 暫時停用（下次開機前有效）
sudo rmmod fw12_rtd3_fix            # 會把 RD3C 恢復成 1

# 永久停用 / 移除
sudo dkms remove fw12-rtd3-fix/1.1 --all
sudo rm -rf /usr/src/fw12-rtd3-fix-1.1

# 開機出問題時：在 GRUB 按 e，在 linux 行尾加上
#   module_blacklist=fw12_rtd3_fix
```

### 修改 module 後重新安裝
```bash
cd module
# 如果改了 rd3c_method.asl，要重新產生 header：
iasl rd3c_method.asl               # 不要加 -f，有錯誤時就該失敗
{ echo '/* Generated from rd3c_method.asl: iasl rd3c_method.asl && xxd -i -n rd3c_method_aml rd3c_method.aml */'; \
  xxd -i -n rd3c_method_aml rd3c_method.aml | sed 's/^unsigned char/static const unsigned char/; /_len = /d'; } > rd3c_method.h
iasl -d -p /tmp/check rd3c_method.aml && cat /tmp/check.dsl   # 反組譯確認內容

make && sudo insmod fw12_rtd3_fix.ko && sudo rmmod fw12_rtd3_fix   # 先手動測試
# 版本號要一起改（dkms.conf 的 PACKAGE_VERSION、/usr/src 的目錄名稱）
sudo dkms remove fw12-rtd3-fix/<舊版號> --all   # 先移除舊版，避免移除時刪到新版同名的 .ko
sudo mkdir /usr/src/fw12-rtd3-fix-<新版號>
sudo cp fw12_rtd3_fix.c rd3c_method.h rd3c_method.asl Makefile dkms.conf /usr/src/fw12-rtd3-fix-<新版號>/
sudo dkms install fw12-rtd3-fix/<新版號> -k <每個已安裝的 kernel>
```

**不再需要 `iasl -f`：** 1.0 版用 `acpi_install_method()`，它要求 table header 後面的第一個 opcode 必須是 Method，所以 ASL 裡不能寫 `External()`，只好用 `-f` 硬把有 3 個錯誤的 ASL 編出來。1.1 版改用 `acpi_load_table()` 載入完整的 SSDT，`External()` 和 `Scope()` 都可以正常使用。iasl 會把 External 包在 `If (Zero)` 裡，這是標準的輸出方式。

### kernel 大改版時要檢查的事
- `acpi_load_table`、`acpi_unload_table`、`acpi_evaluate_integer` 是否還有 export：`grep -wE 'acpi_(un)?load_table' /lib/modules/<kernel>/build/Module.symvers`
- `acpi_load_table()` 的行為（ACPICA `tbxfload.c`）。目前：以 `EXTERNAL_VIRTUAL` 安裝，**不複製** table，會保留指標
- DKMS 編譯失敗時，執行 `dkms status`，log 在 `/var/lib/dkms/fw12-rtd3-fix/1.1/build/make.log`
- **dmesg 沒有 `RD3C 1 -> 2` 就代表失效了。** module 失敗時 init 會回傳錯誤，所以 `lsmod` 裡看不到它；也可以看 `/sys/power/suspend_stats/last_hw_sleep`，sleep 後如果是 0 就是沒進 S0ix（第 8 節的事件就是這樣發現的）

## 5. 更新 BIOS 時要做的事

module 不會替換 ACPI table，所以**更新 BIOS 本身不會造成危險**。module 也會先檢查 `RD3C`、`PNVM`、`SD2P/SD2R` 這些物件存在而且值合理才動作。不過更新後還是建議確認：

1. 開機後看 `dmesg | grep fw12_rtd3_fix`：
   - `RD3C is already 2, nothing to do` → **BIOS 已經修好了**，可以考慮移除 module
   - `RD3C 1 -> 2 ...` → 還是需要 module，正常運作中
   - `cannot evaluate ...` → ACPI 物件的名稱或路徑變了，要重新 dump table 並調查（見第 6 節）
2. 跑一輪 sleep 測試，確認 S0ix residency 有增加（見第 6 節）

**cpio override（`/boot/acpi_override.cpio`）是用 BIOS 03.08 的 SSDT4 做的，BIOS 更新後絕對不能再用。** 它現在只是一個沒有用到的檔案，可以刪掉：`sudo rm /boot/acpi_override.cpio`。

## 6. 調查工具與技巧（深入研究時用）

### S0ix 狀態
```bash
D=/sys/kernel/debug/pmc_core                    # 需要 root
cat $D/slp_s0_residency_usec $D/substate_residencies $D/package_cstate_show
cat /sys/power/suspend_stats/total_hw_sleep
echo 1 > /sys/power/pm_debug_messages
echo 1 > /sys/module/intel_pmc_core/parameters/warn_on_s0ix_failures   # resume 時會印出 package C-state
echo 'file drivers/pci/pci-driver.c +p' > /sys/kernel/debug/dynamic_debug/control  # 印出每個 PCI 裝置的 suspend D-state
```
**注意：** 開著螢幕時，因為面板不支援 PSR，package 本來就會卡在淺層狀態，所以**閒置測量不能拿來判斷 S0ix 問題**，一定要實際 sleep。

### 測試腳本
`snap3.sh`～`snap9.sh` 是各輪的測試腳本（用法：`pkexec ./snapN.sh pre`，sleep，然後 `pkexec ./snapN.sh post`）。結果在 `snapN-pre.txt` / `snapN-post.txt`。
- `snap6.sh` / `snap8.sh` / `snap9.sh`：有掛 kprobe，可以看 ACPI 對每個裝置決定的 D-state
- 腳本裡寫死了 scratchpad 路徑 `/tmp/claude-1000/...`，換環境使用時要修改 `OUT=` 那一行

### dump / 反組譯 ACPI table
```bash
sudo cp /sys/firmware/acpi/tables/{DSDT,SSDT*} ./ ; for f in DSDT SSDT*; do mv $f $f.dat; done
iasl -d DSDT.dat ; for f in SSDT*.dat; do iasl -e DSDT.dat -d $f; done
```
`acpi/` 裡的是 **BIOS 03.08** 的原始 table。

### 讀 GNVS 變數（`gnvs.sh`）
`/dev/mem` 被 `IO_STRICT_DEVMEM` 擋住，所以改從 `/proc/vmallocinfo` 找 ACPICA ioremap GNVS 的虛擬位址（要先暫時把 `kptr_restrict` 設成 1，才看得到真實位址），再用 kprobe 的 `@ADDR` fetcharg 安全讀取。
- **陷阱 1：** `vmallocinfo` 的大小**包含一頁 guard page**，比對範圍時要扣掉 4096
- **陷阱 2：** 一定要用 `OSYS`（偏移 0，應該是 `0x07DF` 這類年份值）驗證，並且讀兩次以上確認值不會變
- **偏移量和 GNVS 位址（`0x448F9018`）只適用於 BIOS 03.08。** 換 BIOS 後，先反組譯新的 DSDT，再用 `./gnvs_offsets.py DSDT.dsl` 重新計算，然後更新 `gnvs.sh` 裡的位址。這個程式遇到 `Offset()` 時會重設位置，其他欄位則依序累加 bit 數；最後如果總長度跟 region 大小對不上，它會直接報錯

### kprobe 看 D-state 決策
```bash
T=/sys/kernel/tracing
echo 'p:s0w/sleepst acpi_pm_device_sleep_state dev=+0(+0(%di)):string dmax=%dx:s32' >> $T/kprobe_events
echo 'r:s0w/sleepst_ret acpi_pm_device_sleep_state ret=$retval:s32' >> $T/kprobe_events
echo 1 > $T/events/s0w/enable
# suspend / resume 之後
grep -A1 'dev="0000:00:06.0"' $T/trace       # ret=0 → D0，ret=4 → D3cold
```
（`struct device` 的第一個成員是 `kobj`，而 `kobj` 的第一個成員就是名稱指標，所以用 `+0(+0(%di))` 就能取得裝置名稱。）

## 7. 其他發現（沒有處理的部分）

- **fluidsynth**（Debian 的 `fluidsynth.service` user service，預設 enabled）會一直開著音訊串流，讓 HDA 無法休眠。這影響的是平常閒置時的耗電，跟 sleep 無關。不需要 MIDI 的話可以執行 `systemctl --user disable --now fluidsynth`
- `spd5118 14-0050: failed to resume`：DDR5 SPD 溫度感測器 driver 的已知問題，不影響耗電，但會讓 `suspend_stats` 的 `failed_resume` 加 1
- `ucsi_acpi ... GET_CABLE_PROPERTY failed`、`ACPI BIOS Error ... RP28.PXSX.WIST`：BIOS 原本就有的錯誤訊息，跟這次的問題無關
- `/boot/acpi_override.cpio`：第八輪測試留下的檔案，GRUB 不會自動載入它，可以刪除

## 8. 2026-10-13：kernel 7.2 讓 module 失效

**症狀：** 蓋上螢幕 sleep 1 小時 39 分，掉了超過 5% 電。`/sys/power/suspend_stats/total_hw_sleep` 是 0，`lsmod` 裡沒有 `fw12_rtd3_fix`。dmesg 顯示：

```
fw12_rtd3_fix: cannot install \_SB.PC00.PEG0.FXRD: AE_BAD_PARAMETER
```

**時間線**（`journalctl _TRANSPORT=kernel --since 2026-10-01`，注意 `journalctl -k` 只會看當次開機）：

| 期間 | kernel | BIOS | module 1.0 |
|---|---|---|---|
| 10/01 22:09 ～ 10/07 09:09 | 7.1.13 | 03.08 | `RD3C 1 -> 2`，正常 |
| 10/07 19:05 ～ 10/13 08:58 | 7.2.6 | 03.08 | `AE_BAD_PARAMETER` |
| 10/13 09:07 起 | 7.2.6 | 03.09 | `AE_BAD_PARAMETER` |

失效時間點剛好是換 kernel 那次開機，跟 BIOS 無關。PNVM、SD2P、SD2R 的安全檢查在 03.09 上都還能通過，物件名稱也沒變。所以 **10/07 晚上到 10/13 這段期間，sleep 其實都沒有進 S0ix**。

**根本原因（kernel bug）：**
1. Linux 7.2 的 ACPICA 從 `20251212` 更新到 `20260408`，帶進了一批 parser 邊界檢查（ACPICA commit `cfdc96896`）。其中 `acpi_ps_peek_opcode()` 在 `aml >= parser_state->aml_end` 時會直接回傳 `0xFFFF`
2. 但 `acpi_install_method()`（`drivers/acpi/acpica/nsxfname.c`）裡的 `parser_state` 是 stack 變數，**從來沒有設定 `aml_end`**，所以裡面是垃圾值
3. 第一個 opcode 被讀成 `0xFFFF`，跟 `AML_METHOD_OP` 不符，函式就回傳 `AE_BAD_PARAMETER`。只要在 7.2 上呼叫 `acpi_install_method()`，不管是誰呼叫都會失敗

上游 ACPICA 已經修好了：commit `19429ef91`「Namespace: Initialize ParserState.AmlEnd in AcpiInstallMethod」（Ivan Hu，2026-08-11），收在 ACPICA `20260930` 版，只加了一行 `ParserState.AmlEnd = Buffer + Table->Length;`。截至 2026-10-13，Linux 主線和 stable v7.2.6 都還沒有這一行。這是靠讀原始碼推論出來的，但錯誤碼和失效時間點都完全吻合，而且繞過這個函式之後問題就消失了。

**解法（module 1.1）：** 不再使用 `acpi_install_method()`，改成用 `acpi_load_table()` 載入完整的 SSDT（細節見第 4 節）。這個做法在 7.1、7.2 和之後修好的 kernel 上都能用，所以就算 Linux 合入了上游修正，也不需要改回去。

**驗證（kernel 7.2.6，BIOS 03.09）：**
- `insmod` → `rmmod` → `insmod`：`RD3C 1 -> 2` → `RD3C restored to 1` → `RD3C 1 -> 2`，沒有出現錯誤
- `rtcwake -m freeze -s 600`：sleep 601.5 秒，`last_hw_sleep` 為 597.76 秒（**99.4%**）
- 對 7.1.13 和 7.2.6 用 `W=1` 編譯都沒有警告；DKMS 1.1 兩個 kernel 都已安裝

## 9. 檔案索引

| 路徑 | 內容 |
|---|---|
| `README.md` | 本文件 |
| `bug-report.md` | 給 Framework 的英文 bug report |
| `module/` | `fw12_rtd3_fix` 原始碼（1.1） |
| `module.v1.0-bak/` | 1.0 版原始碼（`acpi_install_method()` 版本，在 kernel 7.2 上會失敗） |
| `acpi/*.dat` | BIOS 03.08 原始 ACPI table |
| `acpi/SSDT4.dsl`、`acpi/SSDT8.dsl` | 反組譯後的關鍵 table |
| `ssdt4.dsl`、`ssdt4.aml`、`acpi_override.cpio` | 第八輪用的 SSDT4 override（**只適用 BIOS 03.08**） |
| `snap*.sh`、`snap*-pre/post.txt` | 第三～九輪的測試腳本和結果（第一、二輪的檔案已在重開機時遺失） |
| `gnvs.sh` | 讀取 GNVS 變數（只適用 BIOS 03.08 的位址和偏移量） |
| `gnvs_offsets.py` | 從反組譯的 DSDT 計算 GNVS 變數的偏移量 |
| `gna.sh`、`acpi.sh` 等 | 其他輔助腳本 |
