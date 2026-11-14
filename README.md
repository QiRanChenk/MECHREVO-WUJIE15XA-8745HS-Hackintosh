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
| 摄像头 | UVC | ✅ QuickTime / 腾讯会议可用（第三方应用需用 `tools/tcc/tcc-grant.sh` 授权）；Photo Booth 有画面但上下颠倒 |
| 外接显示器 | HDMI / USB-C | ❌ GPU 驱动暂不支持 |
| 睡眠 | — | ✅ 休眠（S4）：点睡眠/合盖后写镜像断电，按电源键恢复到原桌面（需要本仓库的 WujieSleepPolicy + 修改版 nullarc，见下文）。固件无 S3 |
| 指纹 | — | ❌ |

空闲功耗：SoC 封装约 7 W，整机熄屏约 14.5 W（GPU 限频 + 时钟门控后）；看视频约 20–30 W。

## 目录

```
EFI/                 OpenCore 1.0.8 EFI（BOOT + OC）
ACPI-src/            本机 SSDT 源码（.dsl）
patches/             对上游驱动的修改（GPL/BSD 要求公开）
src/WujieXhciIntx/   AMD xHCI 改用 INTx 中断的 kext 源码（免轮询，睡眠唤醒后自动恢复）
src/WujieSleepPolicy/ 睡眠策略 kext 源码：一律休眠、绝不进 S3，并把休眠密钥写入 NVRAM
tools/phxwake/       唤醒后重新初始化核显并恢复显示的常驻服务
tools/tcc/           关闭 AMFI 后给第三方应用授权摄像头/麦克风的脚本
tools/gpuclk/        开机给 780M 限频到 800 MHz（省约 25 W），并调用 gpucg
tools/gpucg/         打开 780M 时钟门控（MGCG/CGCG/CGLS，省约 2 W）
tools/powerbar/      菜单栏显示充放电功耗、SoC 功耗、温度、预计续航，并可选择 CPU 模式（预设 + 无级滑条）
tools/cppc/          CPU 调频服务：开机启用 AMD CPPC，按 powerbar 里选的模式设置能效偏好（需 nullarc PR #21 的 PhxCPPC.kext）
tools/ryzenstat/     读 MSR / 每核功耗的小工具（需本仓库补丁版 CPU kext）
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
5. 睡眠：按下文“睡眠（休眠）”一节配置；不配置的话请 `sudo pmset -a disablesleep 1`（无 S3，直接睡眠后无法唤醒）。
6. 不要直接点系统更新：GPU/网卡驱动与系统版本相关，更新前先备份并确认上游支持。

### boot-args 说明

| 参数 | 作用 |
|---|---|
| `amfi=0x80 amfi_get_out_of_my_way=0x1 -amfipassbeta` | nullarc GPU 用户态组件需要 |
| `phxdebug=1` | nullarc 调试接口（gpuclk 用到） |
| `alcid=21` | SN6140 声卡布局 |
| `ryzenidle=1` | 本仓库补丁版 AMDRyzenCPUPowerManagement：空闲用 `hlt`（0=上游，2=CC6，CC6 会导致画面不刷新且更耗电） |
| `dk=0x8001` | 允许 YT6801 DEXT 绑定被 ACPI 标记为 built-in 的网卡 |
| `phxkick=0 wujiexhci=1` | 关闭 PhxXhciKick 轮询，改由 WujieXhciIntx 把 AMD xHCI 切到 INTx（加载 45 秒后切换，之前自带 2 ms 轮询；`wujiexhci=N` 指定秒数）。回退：删掉 `wujiexhci=1` 并设 `phxkick=2000` |
| `keepsyms=1` | panic 报告带符号。不要日常加 `debug=0x100`：panic 后会停在黑屏上全核空转，一小时耗掉大半电池 |

## 睡眠（休眠）

这台机器的固件没有可用的 S3（DSDT 里 `_S3` 被改名成 `XS3`，强行进 S3 无法唤醒），能用的是休眠：写内存镜像、断电，按电源键后恢复到原来的桌面。实测从内核恢复到桌面画面出现约 2 秒。

| 组成 | 作用 |
|---|---|
| ACPI 补丁 `XS3_` → `_S3_`（config.plist 已含） | 没有 `_S3` 时 macOS 直接拒绝睡眠（`System sleep prevented by kPMPCIUnsupported`）。S3 本身不会被使用 |
| `WujieSleepPolicy.kext`（紧跟 Lilu 注入） | 抢在 X86PlatformPlugin 之前注册睡眠策略：休眠模式开着就“休眠”，否则取消睡眠，绝不选 S3；并在自己下电时把休眠密钥 `IOHibernateRTCVariables` 抄进 NVRAM（PC 没有 Mac 的 RTC 存储，否则 boot.efi 报 `EB|H:FAIL` 后复位） |
| OpenCore `HibernateMode=Auto`、`HibernateSkipsPicker=true` | 把密钥交给 boot.efi，唤醒时不停在启动菜单 |
| `sudo pmset -a hibernatemode 25 standby 0 autopoweroff 0 powernap 0 disablesleep 0` | 立即休眠 |
| 修改版 nullarc（[QiRanChenk/nullarc](https://github.com/QiRanChenk/nullarc) `hibernate-resume` 分支的 PhxBringup + PhxAccel） | 睡眠期间挂起 GPU 提交、唤醒后重绑 VMID、放开 IOFramebuffer 的闸门、重新启用加速器 |
| `WujieSleepPolicy.kext` 唤醒后重跑 `EC0._REG(3,1)` | 休眠时 EC 断过电，回到非 ACPI 模式，不再上报事件：唤醒后合盖没反应、亮度键失效（音量键正常）。固件只在 `_WAK(4)` 里补写 `XSEC = OSEC`，macOS 这条路径走不到 |
| `tools/phxwake`（`sudo ./install.sh`） | 每次唤醒后重跑 GPU 初始化（约 3 秒）并触发上面两步 |

注意：唤醒需要按电源键；不要带 `-v` / `debug=0x100` 测试休眠（入睡时会卡死）；一次失败的睡眠可能让 MT7922 无线网卡失灵，需彻底断电（关机、拔电源、长按电源键 20 秒）才能恢复。

## 本仓库的修改

- **AirportMtkWlan**（上游 [Arxusion/AirportMtkWlan](https://github.com/Arxusion/AirportMtkWlan) `fe9db22`，GPL-3.0）：`mwx_dma_tx_cleanup` 中断与固件下载并发重入导致 double free / 开机卡死，加 `OSCompareAndSwap` 重入保护和下标检查。见 `patches/airportmtkwlan-txcleanup-fix-v2.patch`。构建：`AIRPORT_OS=tahoe ./build-macos.sh Release AirportMtkWlan`。
- **AMDRyzenCPUPowerManagement**（上游 [trulyspinach/SMCAMDProcessor](https://github.com/trulyspinach/SMCAMDProcessor) `029ef3a`，BSD-3）：空闲方式可选（boot-arg `ryzenidle`、运行时 `sysctl debug.ryzenidle`），读取 MSR `C001_0073` 得到 C-state IO 端口。另加 `debug.ryzenidle_port`、特权 user client 选择子 40–45（MSR 读写、xHCI 配置空间/MMIO 读写，调试用）。实测核心空闲合计仅约 0.14 W，CPU 侧已无可省。见 `patches/smcamd-idle-mode.patch`。构建：`xcodebuild -target AMDRyzenCPUPowerManagement -configuration Release MACOSX_DEPLOYMENT_TARGET=12.0 ARCHS=x86_64`。
- **SSDT**：电池（16 位 EC 字段拆字节）、AC 适配器（`_PSR` 绕过 ALIB）、EC/USBX + 亮度键。
- **WujieXhciIntx**（原创，MIT）：AppleUSBXHCI 把非等时传输事件放在 interrupter 1，而 AMD 15b9/15ba/15c0/15c1 只有 1 个 MSI 向量且只由 interrupter 0 触发，所以鼠标键盘事件没有中断（PhxXhciKick 用轮询绕过，2 ms 轮询约多耗 0.4 W，8 ms 鼠标发涩）。本 kext 关掉 MSI、启用 INTx，在控制器 work loop 上挂自己的 filter 中断源，清 `USBSTS.EINT`/`IMAN.IP` 后触发 Apple 的中断源；带中断风暴保护（自动退回 MSI）。运行时开关 `sysctl debug.wujiexhci`，计数 `debug.wujiexhci_irqs/_spurious/_storms`。构建：`src/WujieXhciIntx/build.sh <MacKernelSDK>`。
- **GPU 空闲**：nullarc 没设置 `CP_MEC_DOORBELL_RANGE`，默认范围盖住了图形队列的门铃，第一次敲门铃后 CP 永远报告忙（`GRBM_STATUS 0xa800302c`）。修改版 mesboot 在建队列前写入 Linux 的值（0 / 0x450）。上游 PR #14 有同样的修复。
- **权限弹窗**：为 nullarc 关闭 AMFI 后，tccd 对第三方应用不弹授权窗（日志 `Policy disallows prompt`），用 `tools/tcc/tcc-grant.sh /Applications/XXX.app` 直接写入摄像头/麦克风授权。
- **核显空闲功耗（6.5 W → 约 5 W，Linux 为 4.4 W）**：两处，都在 [QiRanChenk/nullarc](https://github.com/QiRanChenk/nullarc)。
  1. `sdma-unhalt` 分支（上游 PR #24）：nullarc 让 SDMA 引擎一直停机，RLC 等不到它的确认，核显时钟永远不门控。`mesboot` 里解除停机后空闲 6.5 W → 5.8 W。
  2. `gfxoff` 分支的 PhxBringup + boot-arg `phxgfxoff=1`（config.plist 已含）：空闲时让 PMFW 把核显整块断电（GFXOFF），有提交时再上电，空闲约 5 W。没有这版 PhxBringup 时该参数无效果。
- **CPU 调频**：`tools/cppc` + nullarc PR #21 的 `PhxCPPC.kext`，在 `tools/powerbar` 菜单里选模式。
- **GPU 时钟门控**：nullarc 让 `RLC_CGTT_MGCG_OVERRIDE` 保持复位值、CGCG/CGLS 关闭。`tools/gpucg/gpucg.sh all` 按 Linux `gfx_v11_0_update_gfx_clock_gating()` 的顺序打开，SoC 封装空闲 8.8 W → 约 6.8 W，桌面和视频无可见影响。`touch /Users/Shared/gpu/gpucg-off` 可跳过。
- **GPU 限频**：nullarc 让 GFX 时钟固定 2600 MHz；通过 SMU `SetSoftMaxGfxClk(800)` 空闲功耗从约 50 W 降到约 20 W，桌面与视频无可见影响。

## 致谢

[acidanthera](https://github.com/acidanthera)（OpenCore、Lilu、VirtualSMC、AppleALC、NVMeFix、BrightnessKeys、RestrictEvents、VoodooPS2、BlueToolFixup）、[VoodooI2C](https://github.com/VoodooI2C/VoodooI2C)、nullarc（luuumi-dev 等）、[kevin8717/TongFang-7840HS-Hackintosh](https://github.com/kevin8717/TongFang-7840HS-Hackintosh)（本 EFI 的起点，PhxXhciKick 来自该仓库，MIT）、Arxusion、laobamac、trulyspinach、MiniYv、dhinakg。

各第三方组件遵循其各自许可证；本仓库原创部分（SSDT、tools、补丁本身）以 MIT 发布。

---

## English

OpenCore 1.0.8 EFI for the MECHREVO WUJIE15XA (Ryzen 7 8745HS, Radeon 780M) running macOS 26 Tahoe.
Works: 780M Metal acceleration via nullarc (internal panel only), MT7922 Wi-Fi/BT, YT6801 Ethernet (DEXT, `dk=0x8001`), audio, trackpad, battery/AC, brightness keys, NVMe power management.
Sleep works as hibernation (S4): `WujieSleepPolicy.kext`, the ACPI `XS3`->`_S3` patch, OpenCore `HibernateMode=Auto`, the patched nullarc kexts from the `hibernate-resume` branch of QiRanChenk/nullarc and `tools/phxwake`; see the Chinese section above. Not working: S3, external displays, fingerprint.
`PhxBringup.kext`, `AMFIPass.kext` and `SimpleHDA.kext` are not redistributed — download them from upstream (links above).
SMBIOS fields are blank: generate your own for `MacBookPro16,1`.
Source patches for the modified GPL/BSD kexts are in `patches/`.
`WujieXhciIntx.kext` (source in `src/`) switches the AMD xHCI controllers from MSI to legacy INTx so HID events raise interrupts without polling (`phxkick=0 wujiexhci=1`).
`tools/gpucg` enables 780M clock gating (about 2 W less at idle). Do not keep `debug=0x100` for daily use: a panic then halts with all cores spinning and drains the battery.
