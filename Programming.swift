import Foundation

enum ProgrammingAction { case connect, flash, verify, reset, erase, backup(String), optionBytes }

struct ProgrammingCommand {
    let executable: String
    let arguments: [String]
}

struct ConnectionPreset: Codable {
    let backend: String
    let transport: String
    let probe: String
    let family: String
    let model: String
    let target: String
    let speed: String
    let mode: String
    let address: String
    init(_ s: Settings) {
        backend = s.programmerBackend; transport = s.programmerTransport; probe = s.probe
        family = s.chipFamily; model = s.chipModel; target = s.target.hasPrefix("/") ? "" : s.target
        speed = s.speed; mode = s.connectionMode; address = s.binaryAddress
    }
    func apply(to s: inout Settings) throws {
        guard ["OpenOCD", "CubeProgrammer"].contains(backend), ["SWD", "UART", "USB DFU"].contains(transport),
              ["ST-Link", "CMSIS-DAP"].contains(probe), ["Normal", "Under Reset"].contains(mode),
              let group = SeriesCatalog.group(family), SeriesCatalog.accepts(model,group),
              model.hasPrefix(family) || (family == "STM32L4+" && model.hasPrefix("STM32L4")),
              !target.hasPrefix("/"), !target.contains(".."), let hz = Int(speed), (50...24000).contains(hz),
              UInt32(address.hasPrefix("0x") ? address.dropFirst(2) : "",radix:16) != nil else {
            throw StudioError("连接配置文件中的型号、接口、地址或速度无效。")
        }
        s.programmerBackend = backend; s.programmerTransport = transport; s.probe = probe
        s.series = group; s.chipFamily = family; s.chipModel = model; s.target = target
        s.speed = speed; s.connectionMode = mode; s.binaryAddress = address
    }
}

extension Engine {
    func validatedRange(_ s: Settings) throws -> (String, String) {
        let address = s.backupAddress
        guard address.range(of:"^0x[0-9a-fA-F]{1,8}$",options:.regularExpression) != nil,
              let start = UInt64(address.dropFirst(2),radix:16), let size = UInt64(s.backupLength),
              size > 0, size <= 16 * 1024 * 1024, start + size <= 0x1_0000_0000 else {
            throw StudioError("备份地址须为 32 位十六进制；长度填写十进制字节数（1–16777216），且不能超出地址空间。")
        }
        return (address, String(size))
    }
    func programmingCommand(_ action: ProgrammingAction, _ s: Settings) throws -> ProgrammingCommand {
        guard ["Normal", "Under Reset"].contains(s.connectionMode) else { throw StudioError("连接模式无效。") }
        if s.programmerBackend == "OpenOCD" {
            guard ["ST-Link", "CMSIS-DAP"].contains(s.probe) else { throw StudioError("OpenOCD 探针类型无效。") }
            var args = try hardwareArguments(s)
            if !s.probeSerial.isEmpty { args += ["-c", "adapter serial " + tclWord(s.probeSerial)] }
            if s.connectionMode == "Under Reset" {
                args += ["-c", "reset_config srst_only srst_nogate connect_assert_srst"]
            }
            let command: String
            switch action {
            case .connect: command = "init; targets; flash banks; shutdown"
            case .reset: command = "init; reset run; shutdown"
            case .erase: command = "init; reset init; flash erase_sector 0 0 last; shutdown"
            case .flash:
                _ = try flashArguments(s)
                command = "program \(tclWord(s.firmware)) verify reset exit\(try binaryOffset(s))"
            case .verify:
                _ = try flashArguments(s)
                command = "init; reset halt; verify_image \(tclWord(s.firmware))\(try binaryOffset(s)); reset run; shutdown"
            case .backup(let destination):
                let (address,size) = try validatedRange(s)
                command = "init; reset halt; dump_image \(tclWord(destination)) \(address) \(size); reset run; shutdown"
            case .optionBytes: throw StudioError("选项字节查看请切换到 CubeProgrammer / SWD。")
            }
            return ProgrammingCommand(executable:s.openocd,arguments:args + ["-c",command])
        }
        guard s.programmerBackend == "CubeProgrammer" else { throw StudioError("未知烧录后端。") }
        var args = ["-c"]
        switch s.programmerTransport {
        case "SWD":
            guard s.probe == "ST-Link", let speed = Int(s.speed), (50...24000).contains(speed) else {
                throw StudioError("CubeProgrammer 的 SWD 使用 ST-Link，速度范围 50–24000 kHz；CMSIS-DAP 请用 OpenOCD。")
            }
            args += ["port=SWD", "freq=\(speed)", "mode=" + (s.connectionMode == "Under Reset" ? "UR" : "NORMAL")]
            if !s.probeSerial.isEmpty { args.append("sn=" + s.probeSerial) }
        case "UART":
            guard s.serialPort.hasPrefix("/dev/cu.") || s.serialPort.hasPrefix("/dev/tty."),
                  let baud = Int(s.baudRate), (1200...921600).contains(baud) else {
                throw StudioError("请选择 macOS 串口，并填写 1200–921600 的波特率。")
            }
            args += ["port=" + s.serialPort, "br=" + s.baudRate, "P=EVEN"]
        case "USB DFU":
            guard s.dfuPort.range(of:"^USB[1-9][0-9]*$",options:.regularExpression) != nil else { throw StudioError("DFU 端口格式为 USB1、USB2 等。") }
            args += ["port=" + s.dfuPort]
            if !s.probeSerial.isEmpty { args.append("sn=" + s.probeSerial) }
        default: throw StudioError("请选择 SWD、UART 或 USB DFU。")
        }
        switch action {
        case .connect: break
        case .flash, .verify:
            guard exists(s.firmware), ["elf","hex","bin"].contains(URL(fileURLWithPath:s.firmware).pathExtension.lowercased()) else { throw StudioError("请选择存在的 ELF、HEX 或 BIN 文件。") }
            let offset = try binaryOffset(s).trimmingCharacters(in:.whitespaces)
            switch action {
            case .flash:
                args += ["-w",s.firmware]; if !offset.isEmpty { args.append(offset) }
                args += ["-v"]
                if s.programmerTransport == "SWD" { args.append("-rst") }
            default:
                args += ["-v",s.firmware]; if !offset.isEmpty { args.append(offset) }
            }
        case .reset:
            guard s.programmerTransport == "SWD" else { throw StudioError("UART / DFU 下载后请手动切回正常启动并复位。") }
            args += ["-rst"]
        case .erase: args += ["-e","all"]
        case .backup(let destination):
            let (address,size) = try validatedRange(s); args += ["-u",address,size,destination]
        case .optionBytes:
            guard s.programmerTransport == "SWD" else { throw StudioError("选项字节查看仅开放 SWD 连接。") }
            args += ["-ob","displ"]
        }
        return ProgrammingCommand(executable:s.cubeProgrammer,arguments:args)
    }
    func program(_ action: ProgrammingAction, _ s: Settings) throws {
        if case .flash = action {
            let artifact = try FirmwareArtifact.inspect(s.firmware)
            guard s.expectedFirmwareHash.isEmpty || artifact.sha256 == s.expectedFirmwareHash else { throw StudioError("固件在确认后发生变化，请重新确认。") }
            runner.log("固件：\(artifact.file)\nSHA-256：\(artifact.sha256)\n")
        }
        if case .backup(let destination) = action {
            guard !exists(destination) else { throw StudioError("备份目标已存在，请选择新文件名。") }
            let temporary = path(URL(fileURLWithPath:destination).deletingLastPathComponent().path,".stm32-backup-" + UUID().uuidString + ".bin")
            defer { try? fm.removeItem(atPath:temporary) }
            let command = try programmingCommand(.backup(temporary),s)
            _ = try runner.run(command.executable,command.arguments,env:s.environment,timeout:180)
            let attributes = try fm.attributesOfItem(atPath:temporary)
            guard (attributes[.size] as? NSNumber)?.uint64Value == UInt64(s.backupLength) else { throw StudioError("备份长度不符，未保存为完整备份。") }
            try fm.moveItem(atPath:temporary,toPath:destination)
            runner.log("备份已保存：\(destination)\n")
            return
        }
        let command = try programmingCommand(action,s)
        do {
            _ = try runner.run(command.executable,command.arguments,env:s.environment,timeout:180)
        } catch {
            runner.log("\n连接排查：\n" + connectionAdvice(s) + "\n")
            throw error
        }
    }
    func listProgrammers(_ s:Settings) throws {
        _ = try runner.run(s.cubeProgrammer,["-l"],env:s.environment,timeout:30)
    }
    func connectionAdvice(_ s:Settings) -> String {
        if s.programmerBackend == "CubeProgrammer" && !fm.isExecutableFile(atPath:s.cubeProgrammer) {
            return "在工具与固件包中选择 STM32_Programmer_CLI。Apple Silicon 请安装 ST 官方 macOS Arm 包。"
        }
        if s.programmerBackend == "CubeProgrammer" && s.programmerTransport == "UART" {
            return "关闭占用串口的程序；使用 3.3 V UART，TX/RX 交叉并共地；按该型号手册进入系统 Bootloader，核对支持的 USART 引脚。"
        }
        if s.programmerBackend == "CubeProgrammer" && s.programmerTransport == "USB DFU" {
            return "确认芯片支持 ROM USB DFU，按芯片手册进入 Bootloader；使用数据线接芯片 USB 而非 ST-Link USB；先列出设备，再核对 USB 编号和序列号。"
        }
        return "检查目标板供电、共地、SWDIO/SWCLK、探针固件和目标配置；关闭其他调试程序。可降低 SWD 速度；复位下连接需接通 NRST。连接信息不能区分所有封装型号。"
    }
}
