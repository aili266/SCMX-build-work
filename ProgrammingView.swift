import SwiftUI
import AppKit

struct ProgrammerControls: View {
    @ObservedObject var studio: Studio
    @State private var erase = false
    @State private var preview = ""
    @State private var previewVisible = false
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("后端",selection:$studio.settings.programmerBackend) {
                    Text("OpenOCD").tag("OpenOCD"); Text("STM32CubeProgrammer").tag("CubeProgrammer")
                }
                if studio.settings.programmerBackend == "CubeProgrammer" {
                    Picker("接口",selection:$studio.settings.programmerTransport) {
                        ForEach(["SWD","UART","USB DFU"],id:\.self) { Text($0).tag($0) }
                    }
                }
            }
            if studio.settings.programmerBackend == "OpenOCD" || studio.settings.programmerTransport == "SWD" {
                HStack {
                    Picker("探针",selection:$studio.settings.probe) {
                        Text("ST-Link").tag("ST-Link")
                        if studio.settings.programmerBackend == "OpenOCD" { Text("CMSIS-DAP").tag("CMSIS-DAP") }
                    }
                    TextField("速度 kHz",text:$studio.settings.speed).frame(width:90)
                    Picker("连接",selection:$studio.settings.connectionMode) {
                        Text("正常").tag("Normal"); Text("复位下连接").tag("Under Reset")
                    }
                }
                if studio.settings.programmerBackend == "OpenOCD" {
                    HStack { Text("目标"); TextField("target/stm32g4x.cfg",text:$studio.settings.target); Button("选择…") { studio.choose(\.target,title:"选择 OpenOCD target") } }
                }
            }
            if studio.settings.programmerBackend == "CubeProgrammer" && studio.settings.programmerTransport == "UART" {
                HStack {
                    Picker("下载串口",selection:$studio.settings.serialPort) {
                        Text("请选择").tag(""); ForEach(studio.serialDevices,id:\.port) { Text($0.port).tag($0.port) }
                    }
                    TextField("波特率",text:$studio.settings.baudRate).frame(width:100)
                }
            }
            if studio.settings.programmerBackend == "CubeProgrammer" && studio.settings.programmerTransport == "USB DFU" {
                HStack { Text("DFU 端口"); TextField("USB1",text:$studio.settings.dfuPort).frame(width:150) }
            }
            HStack {
                TextField("探针 / DFU 序列号（可选）",text:$studio.settings.probeSerial)
                if studio.settings.programmerBackend == "CubeProgrammer" {
                    Button("列出设备") { studio.perform("列出设备") { e,s in try e.listProgrammers(s); return nil } }
                }
                Button("导入配置…") { importPreset() }; Button("导出配置…") { exportPreset() }
            }
            HStack { Text("固件"); TextField("ELF / HEX / BIN",text:$studio.settings.firmware); Button("选择…") { studio.choose(\.firmware,title:"选择固件") } }
            if studio.settings.firmware.lowercased().hasSuffix(".bin") {
                HStack { Text("写入地址"); TextField("0x08000000",text:$studio.settings.binaryAddress).frame(width:180) }
            }
            HStack {
                Text(studio.artifactMessage).font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("刷新文件") { studio.refreshArtifact(force:true) }; Button("构建输出…") { studio.chooseBuildOutput() }
            }
            if let artifact = studio.artifact { Text(artifact.summary).font(.system(size:10,design:.monospaced)).textSelection(.enabled) }
            HStack {
                Button("连接检测") { run(.connect,"连接检测") }
                Button("烧录并校验") { studio.prepareFlash() }.buttonStyle(.borderedProminent).disabled(studio.settings.firmware.isEmpty)
                Button("仅校验") { run(.verify,"校验固件") }.disabled(studio.settings.firmware.isEmpty)
                Button("复位运行") { run(.reset,"复位运行") }
                Button("擦除…",role:.destructive) { erase = true }
                Spacer()
                Button { showCommand() } label: { Image(systemName:"text.magnifyingglass") }.help("预览烧录命令")
            }
            Divider()
            HStack {
                Text("备份起址"); TextField("0x08000000",text:$studio.settings.backupAddress).frame(width:140)
                Text("字节数"); TextField("65536",text:$studio.settings.backupLength).frame(width:100)
                Button("读取备份…") { backup() }
                Spacer()
                Button("读取选项字节") { run(.optionBytes,"读取选项字节") }
                    .disabled(studio.settings.programmerBackend != "CubeProgrammer" || studio.settings.programmerTransport != "SWD")
            }
        }.textFieldStyle(.roundedBorder).disabled(studio.busy)
        .alert(studio.settings.programmerBackend == "OpenOCD" ? "擦除 Bank 0？" : "全片擦除？",isPresented:$erase) {
            Button("取消",role:.cancel) {}; Button("擦除",role:.destructive) { run(.erase,"擦除 Flash") }
        } message: { Text("后端：\(studio.settings.programmerBackend)\n型号：\(studio.settings.chipModel)\n序列号：\(studio.settings.probeSerial.isEmpty ? "未指定" : studio.settings.probeSerial)\n将删除相应 Flash 中的现有程序。") }
        .sheet(isPresented:$previewVisible) {
            VStack(alignment:.leading,spacing:16) {
                Text("烧录命令预览").font(.headline)
                ScrollView { Text(preview).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                Button("关闭") { previewVisible = false }
            }.padding(24).frame(width:680,height:300)
        }
    }
    private func run(_ action:ProgrammingAction,_ title:String) { studio.perform(title) { e,s in try e.program(action,s); return nil } }
    private func showCommand() {
        do {
            let command = try Engine(runner:Runner(log:{_ in})).programmingCommand(.flash,studio.settings)
            preview = ([command.executable] + command.arguments).map(shellWord).joined(separator:" ")
            previewVisible = true
        } catch { studio.failed = true; studio.status = error.localizedDescription }
    }
    private func backup() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "flash-backup.bin"
        if panel.runModal() == .OK, let url = panel.url { run(.backup(url.path),"读取备份") }
    }
    private func exportPreset() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "stm32-connection.json"
        if panel.runModal() == .OK, let url = panel.url {
            do { let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]; try encoder.encode(ConnectionPreset(studio.settings)).write(to:url,options:.atomic) }
            catch { studio.failed = true; studio.status = error.localizedDescription }
        }
    }
    private func importPreset() {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let preset = try JSONDecoder().decode(ConnectionPreset.self,from:Data(contentsOf:url))
                try preset.apply(to:&studio.settings); studio.save(); studio.status = "连接配置已导入"
            } catch { studio.failed = true; studio.status = error.localizedDescription }
        }
    }
}
