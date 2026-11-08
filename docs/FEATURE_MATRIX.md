# 功能对照与发布范围

对照依据为项目官方 README / 文档，不以搜索结果数量作为市场占有率。目标是覆盖常见开发流程；每种芯片、接口与高级安全能力都需要独立验证。

| 能力 | 现有工具参考 | 本预览版状态 |
| --- | --- | --- |
| ST-Link SWD 烧录、校验、复位 | stlink / OpenOCD / CubeProgrammer | 已有 OpenOCD，新增 CubeProgrammer 路由 |
| CMSIS-DAP | OpenOCD / pyOCD | 已有 OpenOCD 接入 |
| UART ROM Bootloader 下载 | RYCOM / CubeProgrammer | 新增 CubeProgrammer 接入，待开发板实测 |
| USB DFU | QMK Toolbox / CubeProgrammer | 新增 CubeProgrammer 接入，待开发板实测 |
| 设备列表、指定序列号 | CubeProgrammer / stlink | 新增 CubeProgrammer 列表与后端序列号参数 |
| 复位下连接 | CubeProgrammer / stlink | 新增；NRST/探针/目标配置要求见使用说明 |
| Flash 擦除 | CubeProgrammer / OpenOCD | OpenOCD Bank 0；CubeProgrammer 全片；分别确认 |
| 按地址读取备份 | pystlink / CubeProgrammer | 新增；长度检查与不覆盖保护 |
| 查看选项字节 | CubeProgrammer | 新增只读显示；SWD |
| 文本 / HEX 串口终端 | RYCOM | 新增 8N1、CRLF、计数及保存；虚拟串口回归 |
| GDB、断点、单步、栈帧、变量 | OpenOCD / pyOCD | 保留已有调试模块；符号可见性受 ELF/优化影响 |
| CMake、CubeMX、VS Code 衔接 | 多种工程模板与 IDE | 保留已有功能，修复构建配置识别问题 |
| 用户代码整理 | 本应用特色 | 已有归档，新增 CMake 同步与冲突预检 |
| 引脚/寄存器实例查询 | 芯片手册 / SVD 类工具 | 现有 F1/G4 寄存器表；尚无完整 SVD 导入 |
| 配置复用、命令预览、日志 | 多数开发工具 | 新增可移植连接配置与命令预览，保留日志 |
| J-Link | CubeProgrammer / pyOCD | 暂未集成单独界面，不宣称支持 |
| 外部 Flash loader / QSPI | CubeProgrammer | 暂未集成 loader 选择和初始化流程 |
| 生产批量、多探针并行、自动重试 | 专用量产工具 | 暂未实现；当前每次操作一个设备，可手动指定序列号 |
| SWO / RTT / 实时曲线 | pyOCD / 调试工具 | 暂未实现 |
| CAN / I2C / SPI Bootloader | CubeProgrammer | 暂未集成，需要适配器、协议与硬件验证 |
| RDP/OTP/安全烧写与签名 | CubeProgrammer | 不在此预览版范围，避免仅提供命令入口而缺少完整流程 |
| 全系列/全型号硬件认证 | 需大量硬件测试 | 未完成；不能根据 CubeMX 型号表宣称全部实测 |

## 下一阶段建议

1. 用 G431 和 F103 验证 SWD / 备份 / 调试回归；选择实际支持的板卡分别验证 UART 与 DFU。
2. 加入 SVD 导入和更完整的设备识别；逐步扩充实测芯片清单。
3. 按实际需求增加 J-Link、外部 loader 和单设备重复烧录，再做批量会话管理。
4. 基于已验证的探针接入 RTT / SWO；串口扩展到自选校验位、周期发送和录制。

## 官方资料

- https://github.com/stlink-org/stlink
- https://github.com/openocd-org/openocd
- https://github.com/pyocd/pyOCD
- https://github.com/pavelrevak/pystlink
- https://github.com/qmk/qmk_toolbox
- https://github.com/rymcu/RYCOM
- https://www.st.com/en/development-tools/stm32cubeprog.html
- https://dev.st.com/stm32cube-docs/prog/2.23.0/en/docs/markup/CubeProg_Command_Lines.html
