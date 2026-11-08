# SCMX-build work User Guide

[English overview](../README.md) | [中文首页](../README.zh-CN.md) | [中文使用说明](USER_GUIDE.md) | [Troubleshooting](SUPPORT.en.md)

## 1. First-Time Setup

1. Open `SCMX-build-work.app` in Finder. Use macOS 13 or later.
2. The default language is English. Choose English or Simplified Chinese at the bottom of the left sidebar or in Tools settings. The choice is saved.
3. Once the main window opens, select the tools below.

This is a standalone native app, not an Xcode extension. Running the packaged app needs no Xcode, Swift compiler, or Apple Command Line Tools. Only building the app from Swift source needs Command Line Tools, not the full Xcode IDE. See [source-build instructions](../README.md#build-the-app-from-source).

If the app will not open, read the system message and [support guide](SUPPORT.en.md). The preview is not notarized; do not disable system protections globally. Apple Silicon is locally validated; Intel is not. There is no public download. A local build exists for private review; a review artifact may be provided after CI validation.

Already have an ELF, HEX, or BIN file? Select the programming tools, then skip to section 5.

## 2. Select Tools

Open Tools and firmware packages, then run automatic discovery/checks. Select tools for the task you need:

| Task | Tools to select |
| --- | --- |
| Compile STM32 firmware | ARM GCC, CMake, Ninja |
| Generate a project | CubeMX and the matching extracted firmware package |
| Program with a probe | OpenOCD; or CubeProgrammer with ST-Link |
| Program over UART or USB DFU | CubeProgrammer's `STM32_Programmer_CLI` |
| Debug | OpenOCD and ARM GDB |

**Success:** the check identifies tool paths and versions. GCC should report target `arm-none-eabi`.

**If a tool is missing:** select the executable, not an installer or the enclosing `.app`. Use Finder's Show Package Contents to find CubeProgrammer's `bin` directory. Use the macOS Arm package on Apple Silicon.

Tools are installed separately, not bundled. STM32 compilation uses ARM GCC, CMake, and Ninja, not Xcode. Homebrew may require Command Line Tools to install packages; the packaged app does not require them to run.

Programming an existing file needs no CubeMX or firmware package. Warnings about other build tools may not affect that task.

<a id="7-projects-and-builds"></a>

## 3. Import or Create a Project

1. Set the overall project directory to a parent folder such as `stm32_project`, not an individual project folder.
2. Select the chip family, then import the project. Import copies files and keeps the original.
3. For a new project, configure pins, clocks, and peripherals in CubeMX, save, then return to the app.

**Success:** the project appears in the list with its path.

**If it is missing:** check the overall directory, import directory, and location of the `.ioc` file.

Choose STM32F1, STM32G4, or another family directly. The app handles internal Fseries/Gseries folders. Select the full chip model; the app can read it from the project's `.ioc`. If the local CubeMX database is unavailable, enter the family and model manually. A listed model is not proof of hardware testing.

## 4. Generate and Build

1. Select the project and click Generate Project.
2. After generation finishes, click Build Project.
3. Select the resulting ELF, HEX, or BIN. If several files appear, confirm which one belongs to your target.

**Success:** the build completes and produces firmware files.

**If it fails:** read the error message and the first build error in the log. Check tool paths and the current project directory. After changing projects or toolchains, reset the build cache if it is incompatible; old output is moved aside and kept.

Back up before using project-directory organization. It handles CubeMX's `Projects` layout. A project containing only an `.ioc` without generated build files is **rejected with a prompt to run Generate Project first**. Organization does not generate those files for you.

Multicore, TrustZone, and MP/Linux projects need separate configuration. In VS Code, open the actual project root. Completion needs a C/C++ extension and a compilation database from successful CMake configuration. Editor debugging needs Cortex-Debug.

<a id="2-programming-workbench"></a>

## 5. Program Firmware

### ST-Link or CMSIS-DAP with OpenOCD

1. Open the programming workbench and select the chip model.
2. Select OpenOCD, the probe, and the matching target `.cfg`. Start at 1000 kHz.
3. Connect power, common ground, SWDIO, and SWCLK. Run the connection check.
4. Select the firmware. For BIN, enter the correct destination address.
5. Use the magnifier to preview the command. Click Program and Verify, check the chip, file, and address, then confirm.

**Success:** the connection check reports core and Flash information; programming reports a verification result. A completed progress bar alone is not proof of success.

**If connection fails:** close other IDEs or debuggers using the probe. Check wiring, power, and target configuration, then try a lower speed. Do not repeatedly erase to recover a connection.

With several probes, enter the intended serial number. Connect-under-reset needs NRST wiring and a compatible probe/target configuration.

### With CubeProgrammer

- **ST-Link:** select CubeProgrammer and SWD. List devices, enter the intended serial number, select firmware, and program. CMSIS-DAP is not available through this backend.
- **UART:** select the actual `/dev/cu.*` port and baud rate. Disconnect the serial terminal first. After programming, restore normal boot settings and reset the board.
- **USB DFU:** enter the chip's system bootloader, connect its USB data port, list devices, and enter USB1/USB2 or the serial number.

**If it fails:** check the interface, port, and boot settings, then read the backend error. Actual CubeProgrammer CLI behavior and board tests for UART/DFU remain unverified.

Use only the UART bootloader pins and boot settings documented for the exact chip. Connect 3.3 V TTL with crossed TX/RX and common ground, never direct RS-232 levels. CubeProgrammer sets even parity for downloading. Not every chip supports USB DFU; the ST-Link USB port is not the MCU's DFU port.

### Verify, Erase and Reset

- Verify-only sends no write or erase command. OpenOCD still resets and halts the target, then resumes it on success.
- OpenOCD erase affects **Bank 0 only** and leaves the target halted.
- CubeProgrammer erase uses **`-e all`**. Read the confirmation before proceeding.
- After any failure or timeout, reconnect and check whether the target is still halted.

Physical-board programming and erase were not tested in this review.

<a id="3-flash-backup-and-option-bytes"></a>

## 6. Read a Backup or Option Bytes

1. Enter the start address in hexadecimal and length in decimal bytes. For example, `0x08000000` and `65536` request 64 KiB.
2. Choose the backup-read action and a new output filename.
3. On success, the app checks the BIN file length.

**If it fails:** check the device memory map, length, and whether the destination already exists. Reads are limited to 16 MiB; numeric checks reject overflow but cannot prove that the address range is valid Flash.

OpenOCD resets and halts for reading, then resumes on success. This is not uninterrupted live capture. Check the target state after a failure. Physical-device reads remain untested.

Option-byte display is available only with CubeProgrammer / SWD. The app does not offer protection removal, RDP changes, OTP writes, or irreversible security configuration.

<a id="4-serial-terminal"></a>

## 7. Use the Serial Terminal

1. Below the programming controls, select the port and baud rate, then connect. The device must also use 8N1 framing.
2. Choose text with optional CRLF line endings, or HEX with complete bytes such as `01 A0 FF`.
3. Click Send or press Enter. Counters show transferred bytes; a reply depends on the device program.

**If no data appears:** check the port, baud rate, wiring, and whether another program owns the port. Reconnect after unplugging the device.

Supported rates are 9600, 19200, 38400, 57600, 115200, and 230400. Text uses UTF-8. Each send is limited to 4096 bytes; partial sends report the actual count.

Only the latest 64 KiB of received data is kept. Save exports those raw bytes, not the full session history. Counters accumulate since the last clear and may exceed the retained data size.

<a id="5-debugging"></a>

## 8. Debug a Program

1. Open Debugging. Select the ELF from this build and the matching OpenOCD target configuration.
2. Connect and pause. On success, inspect the call stack, variables, or memory.
3. Continue, step, step into, reset-and-halt, or run to `main`. Set a breakpoint by function name or `file:line`.
4. Select a stack frame for its arguments and locals. Add watch expressions for array elements or structure members as needed.

**If connection fails:** check OpenOCD and ARM GDB paths. Close programs using the probe or local port `3333`. Selecting CubeProgrammer for programming does not change the debugger's tools.

**If values are missing:** use a Debug build with symbols, preferably `-O0` or `-Og`. Optimized-out or out-of-scope values may be unavailable. Stack-variable inspection cannot turn arbitrary memory into named variables.

Disconnect debugging before other app operations; they are blocked while it is connected. Live target debugging was not tested in this review.

<a id="6-register-assistant"></a>

## 9. Read Registers

1. Connect and pause the chip in Debugging.
2. Open the register assistant. Filter by peripheral and instance, or search by name.
3. Read the selected registers. On success, their values appear.

**If a read fails:** check the model, address, and peripheral clock against the exact device reference manual.

The built-in tables mainly cover common F1/G4 registers, not all STM32 devices. There are no register-write controls, but reading some status registers clears flags.

<a id="8-source-organization"></a>

## 10. Organize Source Files

1. **Make a separate project backup first.** Check that the project root has `CMakeLists.txt`.
2. Put user files in `Core/Src` and `Core/Inc`, for example `bsp_led.c` and `bsp_led.h`.
3. Run source organization. On success, files move into prefix-based folders and CMake references are updated.
4. Review the changes and build again.

For example, `bsp_led.c` moves to `Core/Src/bsp_c/`; its header moves to `Core/Inc/bsp_h/`. Supported prefixes are `bsp`, `app`, `driver`, `drv`, `middleware`, and `service`.

**If there is a conflict:** read the reported path. An existing destination file or a file occupying a required directory stops the operation. Do not overwrite blindly. If build files are missing, run Generate Project first.

The app updates standard paths and writes `cmake/stm32studio-user-files.cmake`. Repeating the operation resynchronizes it. Custom CMake expressions still need review. Automatic backups are in `.stm32studio/backups/`; keep your separate backup too.

<a id="9-tools-profiles-and-logs"></a>

## 11. Profiles, Logs and Help

- **Reuse a connection:** export a profile and import it on another Mac. Re-select tools, ports, and devices. Exports omit local tool, project, firmware and serial-port paths, and device serial numbers.
- **Reorder modules:** use the lower-left sidebar control.
- **An operation fails:** read the error message, then view or save the log. A blank log does not mean success. External tool output may remain in its original language.
- **Report a problem:** include steps, chip and board models, tool versions, and macOS version. Remove username paths, serial numbers, and tokens from logs. Do not upload code or firmware without permission.

Settings are separate from the former app at `~/Library/Application Support/SCMXBuildWork/settings.json`.

The local programming suite passed 137 assertions. Process, log, language-resource checks, and the original self-test also passed. English and Chinese each have 386 matching string keys. These results do not certify boards, remote CI, or every visual UI state.

The log view and text export retain the latest 150,000 to 180,000 UTF-16 units, not the full history. Save important errors before older output is discarded. Serial ports are selected manually; the app refreshes the list every three seconds without opening each port to search for a device.

This is a private review build. Start with project copies. See [support](SUPPORT.en.md) or the [validation record](VALIDATION.md) (Chinese).
