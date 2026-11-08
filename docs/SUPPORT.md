# SCMX-build work 故障排查与支持

## 运行不了 App

需要 macOS 13 或更新版本，以及与 Mac 芯片一致的构建。预览包仅使用本地临时签名，没有 Developer ID 公证。如系统拒绝打开，可直接从仓库源码本机构建；不要为了运行应用全局关闭系统保护。

## 找不到工具

工具与固件包页选择具体可执行文件。ARM GCC/GDB 要使用 `arm-none-eabi` 版本；CubeMX 与 CubeProgrammer 是不同应用。UART / DFU 需要后者的 CLI。Apple Silicon 与 Intel 的安装包和 Homebrew 默认路径可能不同。

## 烧录连接失败

先确认芯片型号、探针、接口与后端，关闭其他 IDE/调试器。SWD 检查供电、共地、SWDIO/SWCLK；复位下连接需要 NRST。降低速度后再做连接检测，不要自动反复擦除芯片。

UART 检查真实串口、ROM Bootloader 支持的引脚、BOOT 配置及电平；断开终端。USB DFU 检查芯片是否支持、是否进入 Bootloader，连接正确的数据口，然后列出设备确认编号。

## 变量或寄存器看不到

调试需要 ELF 和符号信息，目标需暂停。检查 Debug 编译和优化等级。局部变量只在对应栈帧和作用域内可见；内存字节不一定能恢复成有名字的变量。寄存器表目前主要覆盖 F1/G4，时钟、地址或芯片不匹配时读取可能失败。

## CMake 或 include 报错

打开工程根目录，而不是已移动前的路径。确认 CMakeLists.txt、工具链与源文件实际存在。代码整理后查看 `cmake/stm32studio-user-files.cmake`。复杂自定义引用可能需要人工修改，原文件备份位于 `.stm32studio/backups/`。

固定使用同一构建目录切换 Debug/Release 时，SCMX-build work 会重新配置。换项目或工具链后若 CMake 缓存不兼容，使用重置构建缓存功能；旧输出会移走保留。

## 提交问题

在当前私有仓库 Issues 提供：macOS 版本、Apple Silicon/Intel、SCMX-build work 版本、芯片完整型号、板卡型号、探针及固件版本、后端版本、接口、操作步骤、期望结果与实际结果。

可以附脱敏后的日志。请移除账号、真实用户名路径、设备序列号、访问令牌和不便公开的工程代码。不要上传未经允许的商业固件。

目前没有付费支持、响应时间承诺或完整硬件认证。故障修复与支持清单随验证结果更新。
