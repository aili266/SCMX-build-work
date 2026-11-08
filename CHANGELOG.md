# Changelog

## 0.3.0 — WebCode 私有审核预览版

- 基于原 STM32 macOS 工具整理源码和模块说明，采用 WebCode 名称与 MIT License。
- 保留 OpenOCD、CMake、CubeMX、GDB、寄存器助手、工程整理与侧栏排序。
- 新增 CubeProgrammer SWD / UART / USB DFU 接入、设备列表、序列号、复位下连接。
- 新增 Flash 备份、备份长度检查、只读选项字节、连接配置导入导出与命令预览。
- 新增串口终端，支持 8N1 文本/HEX 收发、CRLF、计数与保存。
- 修复固定构建目录切换 Debug/Release 未重新配置、空固件未拒绝、超时原因不明确及取消与启动之间的竞态。
- 修复用户代码归档后没有同步 CMake 的问题，增加同名冲突预检。
- 新增无硬件回归测试、虚拟串口收发测试和 CI 构建工作流。

新的 CubeProgrammer 下载路径和真实开发板操作尚待硬件验证。本版本不宣称支持所有 STM32 型号或量产场景。
