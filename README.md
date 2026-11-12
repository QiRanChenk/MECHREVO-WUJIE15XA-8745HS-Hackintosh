# MECHREVO WUJIE15XA (Ryzen 7 8745HS) — macOS Tahoe OpenCore EFI

机械革命 无界15XA（R7 8745HS / Radeon 780M）安装 macOS 26 Tahoe 的 OpenCore 1.0.8 EFI。
English summary at the bottom.

> 仅供学习研究。黑苹果不受 Apple 支持，使用风险自负。请勿用于商业用途（GPU 驱动部分为非商业许可）。

## 硬件

| 部件 | 型号 | 状态 |
|---|---|---|
| CPU | AMD Ryzen 7 8745HS (Zen 4, Phoenix) | ✅ 原生内核 + AMDRyzenCPUPowerManagement |
| 核显 | Radeon 780M | ✅ Metal 加速（nullarc，需单独安装）；仅内屏，单一分辨率/刷新率 |
| Wi-Fi / 蓝牙 | MediaTek MT7922 | ✅ AirportMtkWlan（含本仓库竞态修复）+ SimpleMtkBt |
| 有线网卡 | Motorcomm YT6801 | ✅ [yt6801-for-macOS](https://github.com/MiniYv/yt6801-for-macOS) DEXT（系统内安装，需 `dk=0x8001`） |
| 声卡 | Conexant SN6140 | ✅ AppleALC `alcid=21` + SimpleHDA（扬声器、内置麦克风） |
| 触摸板 | I2C HID | ✅ VoodooI2C（多指手势、轻点） |
| 键盘 / 亮度键 | PS/2 | ✅ VoodooPS2 + BrightnessKeys（`SSDT-EC-USBX` 中 `_Q14/_Q15` 转发） |
| 电池 / 电源适配器 | — | ✅ `SSDT-BAT-WUJIE`、`SSDT-AC0-WUJIE` |
| NVMe | 两块第三方 SSD | ✅ NVMeFix + PCIe ASPM L1 |
| 摄像头 | UVC | ⚠️ 能拍照，Photo Booth 预览黑屏 |
| 外接显示器 | HDMI / USB-C | ❌ GPU 驱动暂不支持 |
| 睡眠 | — | ❌ 固件只有 Modern Standby，无 S3；请禁用睡眠 |
| 指纹 | — | ❌ |

空闲整机功耗约 19 W（GPU 限频后），看视频约 20–30 W。

## 目录

```
EFI/                 OpenCore 1.0.8 EFI（BOOT + OC）
ACPI-src/            本机 SSDT 源码（.dsl）
patches/             对上游驱动的修改（GPL/BSD 要求公开）
tools/gpuclk/        开机给 780M 限频到 800 MHz（省约 25 W）
tools/brightkeep/    记住屏幕亮度 + 熄屏时关闭背光
```

## 需要自行下载的文件

以下组件许可证不允许或未声明允许再分发，**仓库里没有**，config.plist 中已保留条目，请下载后放进 `EFI/OC/Kexts/`：

| 文件 | 来源 |
|---|---|
| `PhxBringup.kext` | [luuumi-dev/nullarc](https://github.com/luuumi-dev/nullarc) release（0.4.0）中的 `EFI/OC/Kexts/`，系统内另需按其 INSTALL 安装 PhxAccel 等 |
| `AMFIPass.kext` | [dhinakg/AMFIPass](https://github.com/dhinakg/AMFIPass)（1.4.1） |
| `SimpleHDA.kext` | [laobamac/SimpleHDA](https://github.com/laobamac/SimpleHDA)（1.0.0） |

## SMBIOS

`PlatformInfo > Generic` 中序列号、MLB、UUID、ROM 已清空。请用 [GenSMBIOS](https://github.com/corpnewt/GenSMBIOS) / `macserial` 为 `MacBookPro16,1` 生成自己的，ROM 填本机网卡 MAC。

## 安装要点

1. 安装阶段在 boot-args 加 `-phxbringupoff`，并去掉 `amfi=0x80 amfi_get_out_of_my_way=0x1 -amfipassbeta`（安装器内无 GPU 加速）。
2. 进系统后按 nullarc INSTALL 安装 GPU 部分，再恢复上述 boot-args。
3. EFI 可放在 Windows 的 ESP 上，用 `bcdedit` 或 BIOS 添加 `\EFI\OC\OpenCore.efi` 启动项。
4. 安装 [yt6801-for-macOS](https://github.com/MiniYv/yt6801-for-macOS) 并在系统设置里允许驱动扩展。
5. `sudo pmset -a disablesleep 1`（无 S3，睡眠后无法唤醒）。
6. 不要直接点系统更新：GPU/网卡驱动与系统版本相关，更新前先备份并确认上游支持。

### boot-args 说明

| 参数 | 作用 |
|---|---|
| `amfi=0x80 amfi_get_out_of_my_way=0x1 -amfipassbeta` | nullarc GPU 用户态组件需要 |
| `phxdebug=1` | nullarc 调试接口（gpuclk 用到） |
| `alcid=21` | SN6140 声卡布局 |
| `ryzenidle=1` | 本仓库补丁版 AMDRyzenCPUPowerManagement：空闲用 `hlt`（0=上游，2=CC6，CC6 会导致画面不刷新且更耗电） |
| `dk=0x8001` | 允许 YT6801 DEXT 绑定被 ACPI 标记为 built-in 的网卡 |
| `keepsyms=1 debug=0x100` | 调试：panic 停在屏幕上，日常可删 |

## 本仓库的修改

- **AirportMtkWlan**（上游 [Arxusion/AirportMtkWlan](https://github.com/Arxusion/AirportMtkWlan) `fe9db22`，GPL-3.0）：`mwx_dma_tx_cleanup` 中断与固件下载并发重入导致 double free / 开机卡死，加 `OSCompareAndSwap` 重入保护和下标检查。见 `patches/airportmtkwlan-txcleanup-fix-v2.patch`。构建：`AIRPORT_OS=tahoe ./build-macos.sh Release AirportMtkWlan`。
- **AMDRyzenCPUPowerManagement**（上游 [trulyspinach/SMCAMDProcessor](https://github.com/trulyspinach/SMCAMDProcessor) `029ef3a`，BSD-3）：空闲方式可选（boot-arg `ryzenidle`、运行时 `sysctl debug.ryzenidle`），读取 MSR `C001_0073` 得到 C-state IO 端口。见 `patches/smcamd-idle-mode.patch`。构建：`xcodebuild -target AMDRyzenCPUPowerManagement -configuration Release MACOSX_DEPLOYMENT_TARGET=12.0 ARCHS=x86_64`。
- **SSDT**：电池（16 位 EC 字段拆字节）、AC 适配器（`_PSR` 绕过 ALIB）、EC/USBX + 亮度键。
- **GPU 限频**：nullarc 让 GFX 时钟固定 2600 MHz；通过 SMU `SetSoftMaxGfxClk(800)` 空闲功耗从约 50 W 降到约 20 W，桌面与视频无可见影响。

## 致谢

[acidanthera](https://github.com/acidanthera)（OpenCore、Lilu、VirtualSMC、AppleALC、NVMeFix、BrightnessKeys、RestrictEvents、VoodooPS2、BlueToolFixup）、[VoodooI2C](https://github.com/VoodooI2C/VoodooI2C)、nullarc（luuumi-dev 等）、[kevin8717/TongFang-7840HS-Hackintosh](https://github.com/kevin8717/TongFang-7840HS-Hackintosh)（本 EFI 的起点，PhxXhciKick 来自该仓库，MIT）、Arxusion、laobamac、trulyspinach、MiniYv、dhinakg。

各第三方组件遵循其各自许可证；本仓库原创部分（SSDT、tools、补丁本身）以 MIT 发布。

---

## English

OpenCore 1.0.8 EFI for the MECHREVO WUJIE15XA (Ryzen 7 8745HS, Radeon 780M) running macOS 26 Tahoe.
Works: 780M Metal acceleration via nullarc (internal panel only), MT7922 Wi-Fi/BT, YT6801 Ethernet (DEXT, `dk=0x8001`), audio, trackpad, battery/AC, brightness keys, NVMe power management.
Not working: sleep (no S3 in firmware), external displays, fingerprint.
`PhxBringup.kext`, `AMFIPass.kext` and `SimpleHDA.kext` are not redistributed — download them from upstream (links above).
SMBIOS fields are blank: generate your own for `MacBookPro16,1`.
Source patches for the modified GPL/BSD kexts are in `patches/`.
