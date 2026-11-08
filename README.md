# WebCode

一个专门面向 MacBook 的 STM32 烧录软件，使用 SwiftUI / AppKit 构建原生 macOS 界面。将工程生成与编译、SWD / UART / USB DFU 下载、调试、寄存器查看和代码整理放在一个应用中。

当前为私有仓库审核预览版，尚未发布公开 GitHub Release。支持范围取决于本机后端、芯片和探针，不能将型号列表等同于硬件实测清单。

## 目标与特点

WebCode 面向希望在 MacBook 上完成 STM32 开发的学习者和开发者，减少手动配置工具路径、CMake、固件文件与调试器的重复操作。它沿用 CubeMX、ARM GCC、OpenOCD、GDB 和 CubeProgrammer 的能力，用中文原生界面衔接这些工具。

工程生成、编译结果与固件文件可以关联；烧录前显示摘要，支持连接配置复用；失败时保留命令与输出。它适用于单设备开发、学习和调试，暂不定位为量产烧录系统。

## 快速开始

需要 macOS 13 或更新版本，以及 Xcode Command Line Tools。

```sh
xcode-select --install
brew install cmake ninja open-ocd
zsh build.command
open dist/WebCode.app
```

ARM GCC / GDB 请另外安装与宿主架构匹配的 `arm-none-eabi` 工具链。CubeMX 和 CubeProgrammer 从 ST 官方下载安装，应用不附带或重新分发这些软件。

默认构建当前 Mac 的架构：Apple Silicon 上为 arm64，Intel 上为 x86_64。此预览版在 Apple Silicon 本机构建；Intel 硬件尚未验证。应用使用本地临时签名，没有 Developer ID 签名或 Apple 公证。

已有 ELF / HEX / BIN 时，可直接使用烧录页，不需要先创建工程。OpenOCD 烧录需要其支持的目标配置；UART / DFU 需要可用的 STM32CubeProgrammer CLI。

## 功能

| 模块 | 功能 |
| --- | --- |
| 烧录工作台 | OpenOCD + ST-Link / CMSIS-DAP；CubeProgrammer + ST-Link SWD / UART / USB DFU；烧录校验、仅校验、复位、擦除 |
| 下载辅助 | 复位下连接、探针序列号、设备列表、命令预览、连接配置导入导出 |
| 备份 | 按起始地址与字节数读取 BIN；完整性检查；拒绝覆盖已有文件 |
| 串口终端 | 8N1，文本 / HEX 收发，CRLF，收发计数，保存接收数据 |
| 调试 | OpenOCD + GDB，暂停/运行/单步、断点、栈帧、参数/局部变量、监视表达式和内存 |
| 寄存器助手 | F1/G4 内置常用外设寄存器实例，只读，依赖已连接调试会话 |
| 工程与编译 | CubeMX 工程导入、生成、目录整理、CMake + ARM GCC 构建、ELF/BIN/HEX 输出与 VS Code 配置 |
| 代码整理 | 按 bsp/app/driver/drv/middleware/service 前缀归档，并同步 CMake 源文件与头文件目录 |
| 工具与日志 | 工具发现、固件包选择、版本检查、操作输出、日志导出、侧栏排序 |

详见 [各模块使用说明](docs/USER_GUIDE.md)、[功能对照与待完成项](docs/FEATURE_MATRIX.md)、[旧代码检查记录](docs/BUG_REVIEW.md) 和 [本地验证结果](docs/VALIDATION.md)。

## 测试

```sh
zsh build.command
dist/WebCode.app/Contents/MacOS/STM32Studio --programming-test
```

上述测试不连接开发板：检查各接口命令、地址校验、固件变化保护、配置迁移、虚拟串口实际收发，以及代码整理后真实 CMake 构建。

`--self-test` 是原有测试入口，包含本机 CubeMX 数据库和已安装 F1/G4 固件包断言，需要相应本地环境，不作为干净 CI 的必要条件。测试从临时目录运行，不整理真实用户工程，不烧录或擦除已连接开发板。

## 源码

| 文件 | 责任 |
| --- | --- |
| App.swift | 主窗口、工程管理、工具设置、后台操作与日志 |
| Engine.swift | 文件组织、CubeMX/CMake 流程、OpenOCD 基础命令和子进程执行 |
| Programming.swift | 下载后端路由、参数校验、备份、配置与连接建议 |
| ProgrammingView.swift | 下载、配置及备份界面 |
| SerialTerminal.swift | macOS 串口传输与终端界面 |
| DebugSession.swift | GDB/MI 会话与调试视图 |
| RegisterCatalog.swift | 内置寄存器表与查询视图 |
| DeviceCatalog.swift | CubeMX MCU 数据库、固件包与串口枚举 |
| FirmwareArtifact.swift | 固件大小、修改时间和 SHA-256 |
| Tests.swift / ProgrammingTests.swift | 原有环境测试和新增可移植回归测试 |

预览版设置单独保存在 `~/Library/Application Support/STM32WorkbenchPreview/settings.json`，不覆盖旧 App 的设置。导出的连接配置不包含工具绝对路径、工程路径和固件路径。

## 外部项目与分发

本应用调用已安装的工具，没有复制这些项目的实现：

- [OpenOCD](https://github.com/openocd-org/openocd)
- [STM32CubeProgrammer](https://www.st.com/en/development-tools/stm32cubeprog.html) 与 [命令行文档](https://dev.st.com/stm32cube-docs/prog/2.23.0/en/docs/markup/CubeProg_Command_Lines.html)
- [STM32CubeMX](https://www.st.com/en/development-tools/stm32cubemx.html)
- [Arm GNU Toolchain](https://developer.arm.com/Tools%20and%20Software/GNU%20Toolchain)

可参考的同类项目：[stlink](https://github.com/stlink-org/stlink)、[pyOCD](https://github.com/pyocd/pyOCD)、[pystlink](https://github.com/pavelrevak/pystlink)、[QMK Toolbox](https://github.com/qmk/qmk_toolbox)、[RYCOM](https://github.com/rymcu/RYCOM)。这些链接是功能对照来源，不表示二进制兼容或测试背书。

## License 与帮助

本项目原创代码采用 [MIT License](LICENSE)，允许使用、修改和分发，并要求保留版权和许可声明；软件按原样提供，不提供担保。第三方工具和固件包按各自许可证使用，MIT 不会改变它们的许可条件，也不表示可以重新分发 ST 安装包。

安装和操作参见 [使用说明](docs/USER_GUIDE.md)；遇到问题参见 [故障排查与支持](docs/SUPPORT.md)。查看 [更新记录](CHANGELOG.md) 了解本次整合及旧代码修复。审核期间可在私有仓库 Issues 提交问题；未开放公开支持服务。
