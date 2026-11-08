# SCMX-build work Troubleshooting and Support

[English overview](../README.md) | [中文首页](../README.zh-CN.md) | [English User Guide](USER_GUIDE.en.md) | [中文故障排查](SUPPORT.md)

This is a private source-review preview, not a hardware-certified release. Apple Silicon arm64 is locally validated; Intel x86_64 and actual CubeProgrammer CLI/board workflows remain unverified. External tool messages may retain their original language regardless of the UI language.

## The App Will Not Open

SCMX-build work is a **standalone native app, not an Xcode extension**. Full Xcode is not required.

### Use a Built App (When Available)

Use macOS 13 or later and a packaged app matching the Mac's architecture. Running the `.app` does not require Xcode, Apple Command Line Tools, or a Swift compiler. There is currently no public Release or public download. A local build exists for private review; a private review artifact may be provided after CI validation, without implying that remote CI has already passed.

The preview has an ad-hoc signature, with no Developer ID signature or Apple notarization. Do not disable system protections globally to open it.

### Build the App From Source

If macOS rejects the preview package, building locally is an alternative. Only compiling the app's Swift source needs Apple Command Line Tools (`xcrun` / `swiftc`), not the full Xcode IDE. See the [source-build instructions](../README.md#build-the-app-from-source).

The output bundle is `dist/SCMX-build-work.app`. Its internal executable is still `Contents/MacOS/STM32Studio`; use that name when running test commands.

## A Tool Is Missing

Compiling STM32 firmware uses **ARM GCC + CMake + Ninja**, not Xcode or Swift. Missing STM32 tools affect their respective workflows, not the ability to launch the packaged app. Homebrew may request Apple Command Line Tools to install or build packages; this is a package-manager dependency, not an app runtime requirement.

Select the concrete executable in the tools and firmware packages module. ARM GCC/GDB must be the `arm-none-eabi` variants. CubeMX and CubeProgrammer are separate applications; UART and DFU require CubeProgrammer's `STM32_Programmer_CLI`. Installer architecture and default Homebrew paths differ between Apple Silicon and Intel. Tools are not bundled.

Missing CubeMX or HAL packages need not prevent programming existing ELF/HEX/BIN files. They are required for project generation. If the MCU database is unavailable, enter the family and full model manually.

## Programming Cannot Connect

Check the exact MCU, probe, interface, and backend. Close other IDEs or debuggers using the probe. For SWD, check power, common ground, SWDIO, and SWCLK. Connect-under-reset also needs NRST and compatible configuration. Lower the speed and run a connection check; do not repeatedly erase as a connection-recovery strategy.

For UART, confirm the real port, supported ROM bootloader pins, boot configuration, and 3.3 V TTL levels. Disconnect the serial terminal first. For DFU, confirm chip support, system bootloader mode, and the correct MCU USB data port, then list devices to verify the identifier.

For BIN files, verify the destination address against the device memory map. OpenOCD erase covers Bank 0 only; CubeProgrammer uses `-e all`. After an error or timeout, the target may remain halted. Reconnect and verify its state rather than assuming it resumed. See the [programming guide](USER_GUIDE.en.md#2-programming-workbench).

## Backup or Option-Byte Read Fails

Check the actual memory map, hexadecimal start address, and decimal byte count. Reads are limited to 16 MiB, address overflow is rejected, and existing output files cannot be overwritten. Choose a fresh filename. A file-size mismatch is not a successful complete backup.

Option-byte display requires CubeProgrammer / SWD. Read protection or backend limitations can prevent reading; this preview does not offer protection removal or security-changing operations. Hardware reads have not been validated in this review.

## Serial Data Is Missing or Invalid

Select the correct port and match the device's baud rate and 8N1 framing. Close any other program using the port. The terminal is not a substitute for the UART bootloader connection, which uses even parity through CubeProgrammer.

HEX input requires complete bytes. Each send is limited to 4096 bytes. The receive view retains only the latest 64 KiB; saving exports that retained raw data, not the entire lifetime of the connection. Reconnect after a device removal. See the [serial guide](USER_GUIDE.en.md#4-serial-terminal).

## Variables or Registers Are Missing

Use a symbol-bearing ELF and halt the target. Check the Debug configuration and optimization level. Locals are visible only within the relevant frame and scope; arbitrary memory cannot necessarily be reconstructed as named variables.

Debugging always requires OpenOCD and ARM GDB, even if programming uses CubeProgrammer. Ensure local port `3333` and the probe are not occupied. Disconnect debugging before starting other app operations.

The register tables mainly cover common F1/G4 peripherals. An incorrect MCU, address, or disabled clock may cause reads to fail. Consult the exact reference manual; some reads clear flags. Complete SVD import and register writes are not provided.

## CMake, Includes or Source Organization Fail

Open the actual project root, not its former location. Confirm `CMakeLists.txt`, toolchain, and source files exist. After source organization, inspect `cmake/stm32studio-user-files.cmake`. Custom CMake expressions may need manual changes. Original-file backups are under `.stm32studio/backups/`.

A destination filename conflict intentionally aborts organization. Resolve it deliberately rather than overwriting. When several build artifacts exist, select the intended firmware explicitly.

Switching Debug/Release in the same build directory triggers reconfiguration. After changing project or toolchain, use the build-cache reset action if the CMake cache is incompatible; old output is moved aside and retained. VS Code completion also needs the relevant extension and a compilation database from successful CMake configuration.

## Profiles, Settings or Logs Look Different

Connection profiles intentionally omit tool, project, firmware and serial-port paths, and device serial numbers. Re-select those values on the destination Mac. Settings are stored separately at `~/Library/Application Support/SCMXBuildWork/settings.json`, without overwriting the former app's settings. Select the UI language at the bottom of the left sidebar or in Tools settings; this does not translate external tool output.

## Reporting an Issue

Collaborators can use the [private repository issue tracker](https://github.com/aili266/SCMX-build-work/issues). Include:

- macOS version, Apple Silicon/Intel, and SCMX-build work version or source revision.
- Full MCU model, board model, probe model and firmware version.
- Backend/tool versions, interface, and relevant connection settings.
- Reproduction steps, expected result, actual result, and redacted logs.

Remove account details, real username paths, device serial numbers, tokens, and confidential source code. Do not upload commercial firmware without permission.

The latest local run passed 34 base checks plus 49 organization conflict assertions and the original self-test. English and Simplified Chinese localization checks each matched 386 keys. Key matching does not establish exhaustive visual validation of the UI.

There is no paid support, response-time guarantee, or comprehensive hardware certification. The [validation record](VALIDATION.md), [feature matrix](FEATURE_MATRIX.md), and [residual-risk review](BUG_REVIEW.md) are currently in Chinese. Local automated success does not establish remote GitHub CI success or physical-board compatibility.
