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
                Picker("Backend",selection:$studio.settings.programmerBackend) {
                    Text("OpenOCD").tag("OpenOCD"); Text("STM32CubeProgrammer").tag("CubeProgrammer")
                }
                if studio.settings.programmerBackend == "CubeProgrammer" {
                    Picker("Transport",selection:$studio.settings.programmerTransport) {
                        ForEach(["SWD","UART","USB DFU"],id:\.self) { Text($0).tag($0) }
                    }
                }
            }
            if studio.settings.programmerBackend == "OpenOCD" || studio.settings.programmerTransport == "SWD" {
                HStack {
                    Picker("Probe",selection:$studio.settings.probe) {
                        Text("ST-Link").tag("ST-Link")
                        if studio.settings.programmerBackend == "OpenOCD" { Text("CMSIS-DAP").tag("CMSIS-DAP") }
                    }
                    TextField("Speed (kHz)",text:$studio.settings.speed).frame(width:90)
                    Picker("Connection Mode",selection:$studio.settings.connectionMode) {
                        Text("Normal").tag("Normal"); Text("Under Reset").tag("Under Reset")
                    }
                }
                if studio.settings.programmerBackend == "OpenOCD" {
                    HStack { Text("Target"); TextField("Matching OpenOCD target .cfg",text:$studio.settings.target); Button("Choose…") { studio.choose(\.target,title:"Choose OpenOCD Target") } }
                }
            }
            if studio.settings.programmerBackend == "CubeProgrammer" && studio.settings.programmerTransport == "UART" {
                HStack {
                    Picker("Programming Port",selection:$studio.settings.serialPort) {
                        Text("Select a port").tag(""); ForEach(studio.serialDevices,id:\.port) { Text($0.port).tag($0.port) }
                    }
                    TextField("Baud Rate",text:$studio.settings.baudRate).frame(width:100)
                }
            }
            if studio.settings.programmerBackend == "CubeProgrammer" && studio.settings.programmerTransport == "USB DFU" {
                HStack { Text("DFU Port"); TextField("USB1",text:$studio.settings.dfuPort).frame(width:150) }
            }
            HStack {
                TextField("Probe / DFU serial number (optional)",text:$studio.settings.probeSerial)
                if studio.settings.programmerBackend == "CubeProgrammer" {
                    Button("List Devices") { studio.perform("List Devices") { e,s in try e.listProgrammers(s); return nil } }
                }
                Button("Import Preset…") { importPreset() }; Button("Export Preset…") { exportPreset() }
            }
            HStack { Text("Firmware"); TextField("ELF / HEX / BIN",text:$studio.settings.firmware); Button("Choose…") { studio.choose(\.firmware,title:"Choose Firmware") } }
            if studio.settings.firmware.lowercased().hasSuffix(".bin") {
                HStack { Text("Write Address"); TextField("0x08000000",text:$studio.settings.binaryAddress).frame(width:180) }
            }
            HStack {
                Text(LocalizedStringKey(studio.artifactMessage)).font(.caption).foregroundStyle(.secondary)
                Spacer(); Button("Refresh File") { studio.refreshArtifact(force:true) }; Button("Build Outputs…") { studio.chooseBuildOutput() }
            }
            if let artifact = studio.artifact { Text(artifact.summary).font(.system(size:10,design:.monospaced)).textSelection(.enabled) }
            HStack {
                Button("Test Connection") { run(.connect,"Test Connection") }
                Button("Flash and Verify") { studio.prepareFlash() }.buttonStyle(.borderedProminent).disabled(studio.settings.firmware.isEmpty)
                Button("Verify Only") { run(.verify,"Verify Firmware") }.disabled(studio.settings.firmware.isEmpty)
                Button("Reset and Run") { run(.reset,"Reset and Run") }
                Button("Erase…",role:.destructive) { erase = true }
                Spacer()
                Button { showCommand() } label: { Image(systemName:"text.magnifyingglass") }.help("Preview Flash Command")
            }
            Divider()
            HStack {
                Text("Backup Address"); TextField("0x08000000",text:$studio.settings.backupAddress).frame(width:140)
                Text("Bytes"); TextField("65536",text:$studio.settings.backupLength).frame(width:100)
                Button("Read Backup…") { backup() }
                Spacer()
                Button("Read Option Bytes") { run(.optionBytes,"Read Option Bytes") }
                    .disabled(studio.settings.programmerBackend != "CubeProgrammer" || studio.settings.programmerTransport != "SWD")
            }
        }.textFieldStyle(.roundedBorder).disabled(studio.busy)
        .alert(LocalizedStringKey(studio.settings.programmerBackend == "OpenOCD" ? "Erase Bank 0?" : "Erase Entire Chip?"),isPresented:$erase) {
            Button("Cancel",role:.cancel) {}; Button("Erase",role:.destructive) { run(.erase,"Erase Flash") }
        } message: { Text("Backend: \(studio.settings.programmerBackend)\nDevice: \(studio.settings.chipModel)\nSerial: \(studio.settings.probeSerial.isEmpty ? L10n.string("Not specified") : studio.settings.probeSerial)\nThis deletes the existing program in the selected Flash area.") }
        .sheet(isPresented:$previewVisible) {
            VStack(alignment:.leading,spacing:16) {
                Text("Flash Command Preview").font(.headline)
                ScrollView { Text(preview).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading) }
                Button("Close") { previewVisible = false }
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
        if panel.runModal() == .OK, let url = panel.url { run(.backup(url.path),"Read Backup") }
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
                try preset.apply(to:&studio.settings); studio.save(); studio.status = "Connection preset imported"
            } catch { studio.failed = true; studio.status = error.localizedDescription }
        }
    }
}
