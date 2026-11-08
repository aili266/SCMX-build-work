import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NavigationItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let icon: String
}

let navigationCatalog = [
    NavigationItem(id:0,title:"Flashing",icon:"cable.connector"),
    NavigationItem(id:4,title:"Debug",icon:"ant"),
    NavigationItem(id:5,title:"Register Assistant",icon:"list.bullet.rectangle"),
    NavigationItem(id:6,title:"Code Organization",icon:"folder.badge.gearshape"),
    NavigationItem(id:1,title:"Projects & Build",icon:"square.stack.3d.up"),
    NavigationItem(id:2,title:"Tools & Firmware Packs",icon:"wrench.and.screwdriver"),
    NavigationItem(id:3,title:"Run Log",icon:"terminal")
]

final class Studio: ObservableObject {
    let debug = DebugSession()
    let terminal = SerialTerminal()
    @Published var settings: Settings
    @Published var projects: [String] = []
    @Published var busy = false
    @Published var status = "Ready · Select a project to begin"
    @Published var failed = false
    @Published var log = L10n.string("SCMX-build work\nGenerate → Build → Flash. Execution output appears here.\n")
    @Published var checks: [String:String] = [:]
    @Published var tab = 0
    @Published var records:[MCURecord] = []
    @Published var modelSearch = ""
    @Published var serialDevices:[SerialDevice] = []
    @Published var artifact:FirmwareArtifact?
    @Published var artifactMessage = "No firmware selected"
    @Published var outputChoices:[String] = []
    @Published var outputSheet = false
    private var lastCandidateSignature = ""
    private var trackedProject = ""
    @Published var newSheet = false
    @Published var newName = ""
    @Published var mcu = "STM32G431RBTx"
    @Published var flashConfirm = false
    private var runner: Runner?
    let savePath = NSHomeDirectory() + "/Library/Application Support/SCMXBuildWork/settings.json"
    init() {
        let legacyPath = NSHomeDirectory() + "/Library/Application Support/STM32Studio/settings.json"
        settings = Settings.load(exists(savePath) ? savePath : legacyPath); trackedProject = settings.project
        settings.discover(); records = DeviceCatalog.load(settings.cube)
        let saved = settings
        refresh()
        settings.series = saved.series; settings.chipFamily = saved.chipFamily; settings.chipModel = saved.chipModel; settings.pack = saved.pack
        if exists(saved.firmware) { settings.firmware = saved.firmware }; if exists(saved.debugELF) { settings.debugELF = saved.debugELF }; settings.outputDirectory = saved.outputDirectory; settings.followBuildOutputs = saved.followBuildOutputs; selectFamily(updateSeries:true); scanSerial(); refreshArtifact(force:true)
        try? fm.createDirectory(atPath:settings.repository,withIntermediateDirectories:true)
        Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.scanSerial(); self?.refreshArtifact(); self?.debug.checkELF() }
    }
    var families:[String] { Array(Set(records.map(\.family))).sorted() }
    var matchingModels:[MCURecord] { records.filter { $0.family == settings.chipFamily && (modelSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(modelSearch) || $0.package.localizedCaseInsensitiveContains(modelSearch)) } }
    var menuModels:[MCURecord] {
        var rows = Array(matchingModels.prefix(150))
        if !rows.contains(where:{$0.name == settings.chipModel}), let selected = records.first(where:{$0.name == settings.chipModel && $0.family == settings.chipFamily}) { rows.insert(selected,at:0) }
        return rows
    }
    var packs:[FirmwarePack] { FirmwarePack.available(repository:settings.repository,family:settings.chipFamily) }
    var navigationItems: [NavigationItem] {
        let indexed = Dictionary(uniqueKeysWithValues:navigationCatalog.map { ($0.id, $0) })
        let ordered = settings.navigationOrder.compactMap { indexed[$0] }
        let missing = navigationCatalog.filter { !settings.navigationOrder.contains($0.id) }
        return ordered + missing
    }
    func saveNavigationOrder(_ order: [Int]) {
        settings.navigationOrder = order
        save()
    }
    func selectFamily(updateSeries: Bool = false) {
        if records.isEmpty {
            if updateSeries { settings.series = SeriesCatalog.group(settings.chipFamily) ?? settings.series }
            let engine = Engine(runner:Runner(log:{_ in}))
            settings.target = engine.targetFor(settings.chipFamily,model:settings.chipModel) ?? ""
            save(); return
        }
        if !families.contains(settings.chipFamily) { settings.chipFamily = families.first ?? "" }
        if updateSeries { settings.series = SeriesCatalog.group(settings.chipFamily) ?? settings.series }
        let models = records.filter{$0.family == settings.chipFamily}
        if !models.contains(where:{$0.name == settings.chipModel}) { settings.chipModel = models.first?.name ?? "" }
        let e = Engine(runner:Runner(log:{_ in}))
        settings.target = e.targetFor(settings.chipFamily,model:settings.chipModel).flatMap { e.openocdFile($0,settings) == nil ? nil : $0 } ?? ""
        if !packs.contains(where:{$0.folder == settings.pack}) { settings.pack = packs.first?.folder ?? "" }
        modelSearch = ""; save()
    }
    func reloadCatalog() { records = DeviceCatalog.load(settings.cube); selectFamily(); status = L10n.format("Loaded %lld MCU models",records.count) }
    func scanSerial() {
        DispatchQueue.global(qos:.utility).async {
            let ports = SerialCatalog.scan()
            DispatchQueue.main.async { self.serialDevices = ports; if !self.settings.serialPort.isEmpty && !ports.contains(where:{$0.port == self.settings.serialPort}) { self.settings.serialPort = "" } }
        }
    }
    func identifyIOC() {
        let f = DeviceCatalog.iocValue("Mcu.Family",settings.project), chip = DeviceCatalog.iocValue("Mcu.UserName",settings.project)
        guard !f.isEmpty, !chip.isEmpty else { status = "当前工程无可识别的 .ioc，请手动选择型号"; failed = true; return }
        settings.series = SeriesCatalog.group(f) ?? settings.series; settings.chipFamily = f; settings.chipModel = chip; selectFamily(); status = L10n.string("Detected from .ioc: ") + chip; failed = false
    }
    func adoptFirmware(_ file:String,automatic:Bool = true) {
        settings.firmware = file; settings.followBuildOutputs = automatic
        if file.lowercased().hasSuffix(".elf") { settings.debugELF = file }
        else { let elf = URL(fileURLWithPath:file).deletingPathExtension().appendingPathExtension("elf").path; if exists(elf) { settings.debugELF = elf } }
        refreshArtifact(force:true); save()
    }
    func refreshArtifact(force:Bool = false) {
        guard !busy else{return}
        let file = settings.firmware
        guard !file.isEmpty else { artifact = nil; artifactMessage = "No firmware selected"; return }
        guard exists(file) else {
            artifact = nil; artifactMessage = "Firmware path no longer exists. Refresh and select an output."
            if settings.followBuildOutputs { let options = FirmwareArtifact.outputs(settings.build); let signature = options.joined(separator:"|"); if !options.isEmpty && signature != lastCandidateSignature { lastCandidateSignature = signature; outputChoices = options; outputSheet = true } }
            return
        }
        let attributes = try? fm.attributesOfItem(atPath:file)
        if !force, artifact?.file == file, attributes?[.modificationDate] as? Date == artifact?.modified, attributes?[.size] as? UInt64 == artifact?.size { return }
        do {
            artifact = try FirmwareArtifact.inspect(file)
            artifactMessage = settings.followBuildOutputs ? "New build output selected (tracked automatically)" : "Manually selected firmware (file changes tracked)"
        } catch { artifact = nil; artifactMessage = error.localizedDescription }
    }
    func prepareFlash() {
        refreshArtifact(force:true)
        guard let artifact else { failed = true; status = artifactMessage; return }
        settings.expectedFirmwareHash = artifact.sha256; flashConfirm = true
    }
    func chooseBuildOutput() {
        let options = FirmwareArtifact.outputs(settings.build)
        if options.isEmpty { status = "构建目录中没有 ELF / BIN / HEX"; failed = true; return }
        outputChoices = options; outputSheet = true
    }
    func compileCurrent() {
        perform("Build Project") { e,c in
            let elf = try e.build(c)
            let outputs = FirmwareArtifact.outputs(c.build)
            DispatchQueue.main.async {
                self.settings.debugELF = elf.count == 1 ? elf[0] : ""
                if elf.count > 1 || (c.followBuildOutputs && !c.firmware.isEmpty && !outputs.contains(c.firmware) && canonical(c.firmware).hasPrefix(canonical(c.build) + "/")) {
                    self.outputChoices = outputs; self.outputSheet = true; self.status = "编译成功 · 输出路径改变或存在多个目标，请选择固件"
                } else if let file = elf.first { self.adoptFirmware(file) }
            }
            return nil
        }
    }
    func save() { try? fm.createDirectory(atPath:URL(fileURLWithPath:savePath).deletingLastPathComponent().path,withIntermediateDirectories:true); if let d = try? JSONEncoder().encode(settings) { try? d.write(to:URL(fileURLWithPath:savePath),options:.atomic) } }
    func refresh() {
        let root = path(settings.root,settings.series)
        projects = children(root).filter{var dir:ObjCBool = false; return fm.fileExists(atPath:path(root,$0),isDirectory:&dir) && dir.boolValue && !$0.hasPrefix(".")}.sorted().map{path(root,$0)}
        if !projects.contains(settings.project) { settings.project = projects.first ?? "" }
        selectProject(); selectFamily(); save()
    }
    func selectProject() {
        if trackedProject != settings.project { settings.outputDirectory = ""; trackedProject = settings.project }
        let e = Engine(runner:Runner(log:{_ in}))
        settings.target = e.targetFor(e.family(settings.project)).flatMap { e.openocdFile($0,settings) == nil ? nil : $0 } ?? ""
        settings.firmware = e.firmwareFiles(settings.build).first ?? ""; settings.debugELF = settings.firmware; settings.toolchain = ""
        let family = e.family(settings.project), chip = DeviceCatalog.iocValue("Mcu.UserName",settings.project)
        if !family.isEmpty { settings.chipFamily = family; settings.chipModel = chip }; selectFamily(); save()
    }
    func choose(_ key: WritableKeyPath<Settings,String>, directory: Bool = false, title: String = "Choose File", completion:(()->Void)? = nil) {
        let panel = NSOpenPanel(); panel.title = L10n.string(title); panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { settings[keyPath:key] = url.path
            if key == \Settings.firmware { adoptFirmware(url.path,automatic:false) }
            if key == \Settings.debugELF { settings.debugELF = url.path }
            save(); completion?() }
    }
    func append(_ s: String) { log = LogBuffer.appending(s,to:log) }
    func perform(_ title: String, _ operation: @escaping (Engine,Settings)throws -> String?) {
        guard !busy else { return }
        if debug.active { failed = true; status = "请先断开调试会话，再执行此操作"; return }
        if terminal.connected && settings.programmerBackend == "CubeProgrammer" && settings.programmerTransport == "UART" {
            failed = true; status = "请先断开串口终端，释放 UART 下载端口"; return
        }
        save(); busy = true; failed = false; status = L10n.string(title) + "…"; append("\n━━━━ \(title) ━━━━\n")
        let output = LogOutputCoalescer { [weak self] value in self?.append(value) }
        let r = Runner { value in output.append(value) }; runner = r
        let snapshot = settings
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let result = try operation(Engine(runner:r),snapshot)
                DispatchQueue.main.async { output.finish(); self.busy = false; self.runner = nil; self.status = L10n.string("Completed: ") + L10n.string(title); self.append("✓ " + self.status + "\n"); self.refreshArtifact(force:true); if let result { self.settings.firmware = result }; if title.contains("生成") || title.contains("Generate") { self.selectProject() }; self.save() }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { output.finish(); self.busy = false; self.runner = nil; self.failed = true; self.status = L10n.string("Failed: ") + L10n.string(title); self.append("✕ \(message)\n"); self.tab = 3 } }
        }
    }
    func stop() { runner?.cancel(); status = "Stopping…" }
    func inspect() {
        settings.discover(); reloadCatalog(); checks = [:]
        perform("Check Tools") { e,s in
            var problems:[String] = []
            for (name,exe) in [("CMake",s.cmake),("Ninja",s.ninja),("ARM GCC",s.compiler),("ARM GDB",s.gdb),("Host GCC",s.hostGCC),("OpenOCD",s.openocd)] {
                do { let v = try e.runner.run(exe,["--version"],env:s.environment,timeout:15); DispatchQueue.main.async { self.checks[name] = "✓ " + String(v.split(separator:"\n").first ?? "Available") } }
                catch { problems.append(name); DispatchQueue.main.async { self.checks[name] = "✕ Unavailable. Choose another executable." }; e.runner.log(error.localizedDescription + "\n") }
            }
            let cubeOK = fm.isExecutableFile(atPath:s.cube)
            DispatchQueue.main.async { self.checks["CubeMX"] = cubeOK ? "✓ Executable found" : "✕ CubeMX not found" }
            if !cubeOK { problems.append("CubeMX") }
            if fm.isExecutableFile(atPath:s.cubeProgrammer) {
                do {
                    _ = try e.runner.run(s.cubeProgrammer,["-h"],env:s.environment,timeout:15)
                    DispatchQueue.main.async { self.checks["CubeProg CLI"] = "✓ Available (optional backend)" }
                } catch { DispatchQueue.main.async { self.checks["CubeProg CLI"] = "✕ Cannot run. Choose another executable." } }
            } else { DispatchQueue.main.async { self.checks["CubeProg CLI"] = "Not installed; required for UART / DFU" } }
            do { try e.validateCompiler(s) } catch { problems.append("ARM 目标检查"); e.runner.log(error.localizedDescription + "\n") }
            if !problems.isEmpty { throw StudioError("以下工具需要处理：" + problems.joined(separator:"、")) }
            return nil
        }
    }
    func importProject() {
        let panel = NSOpenPanel(); panel.title = L10n.string("Import CubeMX Project (Keep Original Files)"); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("Import Project") { e,s in let dest = try e.importProject(url.path,s); DispatchQueue.main.async { self.settings.project = dest; self.refresh() }; return nil }
    }
    func organizeUserFiles() {
        perform("Code Organization") { e,s in try e.organizeUserFiles(s); return nil }
    }
    func requirePack(_ family:String) -> Bool {
        if !FirmwarePack.available(repository:settings.repository,family:family).isEmpty { return true }
        failed = true; status = L10n.format("No %@ firmware pack installed. Official downloads opened.",family); append(status + "\n"); NSWorkspace.shared.open(FirmwarePack.downloadURL(family)); return false
    }
    func generateCurrent() {
        let family = Engine(runner:Runner(log:{_ in})).family(settings.project)
        guard !family.isEmpty else { failed = true; status = "当前工程没有可识别的 .ioc"; return }
        guard requirePack(family) else { return }
        perform("Generate Project") { e,c in try e.generate(c); return nil }
    }
    func create() {
        selectFamily(updateSeries:true)
        guard requirePack(settings.chipFamily) else { return }
        let name = newName, chip = settings.chipModel; newSheet = false
        perform("Create and Generate Project") { e,s in
            guard SeriesCatalog.accepts(chip,s.series) else { throw StudioError("请填写当前系列的完整 MCU 型号。") }
            let dest = try e.create(root:s.root,series:s.series,name:name); var next = s; next.project = dest
            DispatchQueue.main.async { self.settings.series = s.series; self.settings.project = dest; self.refresh() }
            try e.generate(next,mcu:chip); return nil
        }
    }
    func openCube() {
        save(); guard fm.isExecutableFile(atPath:settings.cube) else { failed = true; status = "未找到 CubeMX，请在工具链中选择"; tab = 2; return }
        let p = Process(); p.executableURL = URL(fileURLWithPath:settings.cube); p.currentDirectoryURL = URL(fileURLWithPath:settings.cube).deletingLastPathComponent(); p.environment = settings.environment
        if let file = try? Engine(runner:Runner(log:{_ in})).ioc(settings.project) { p.arguments = [file] }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); status = "CubeMX opened · Save the .ioc after device configuration" } catch { failed = true; status = error.localizedDescription }
    }
    func exportLog() { let p = NSSavePanel(); p.nameFieldStringValue = "SCMX-build-work-log.txt"; if p.runModal() == .OK, let u = p.url { do { try log.write(to:u,atomically:true,encoding:.utf8) } catch { status = error.localizedDescription; failed = true } } }
    func resetBuild() {
        perform("Reset Build Cache") { _,s in
            guard !s.project.isEmpty else { throw StudioError("请先选择工程。") }
            if exists(s.build) { let moved = s.build + ".previous-" + String(Int(Date().timeIntervalSince1970)); try fm.moveItem(atPath:s.build,toPath:moved) }
            return ""
        }
    }
}

struct Card<Content:View>: View {
    let title: String; let icon: String; @ViewBuilder var content: Content
    var body: some View { VStack(alignment:.leading,spacing:13) { Label(LocalizedStringKey(title),systemImage:icon).font(.headline); content }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.08))) }
}
struct MainView: View {
    @ObservedObject var s: Studio
    @State private var showingNavigationOrder = false
    @ObservedObject private var localization = LocalizationSettings.shared
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:22) {
                HStack { Image(nsImage:NSImage(named:"SCMXBuildWork") ?? NSApp.applicationIconImage).resizable().interpolation(.high).scaledToFit().frame(width:40,height:40); VStack(alignment:.leading) { Text("SCMX-build work").font(.headline).fixedSize(horizontal:false,vertical:true); Text("macOS Workbench").foregroundStyle(.secondary) } }.padding(.top,14)
                Text("Workbench").font(.caption).foregroundStyle(.secondary)
                ForEach(s.navigationItems) { item in nav(item.title,item.icon,item.id) }
                Spacer()
                Divider()
                Button { showingNavigationOrder = true } label: { Label("Reorder Sidebar",systemImage:"arrow.up.arrow.down").frame(maxWidth:.infinity,alignment:.leading).padding(10) }.buttonStyle(.plain)
                languagePicker
                Label("Native macOS App",systemImage:"macwindow").font(.caption).foregroundStyle(.secondary)
                Text("CMake · ARM GCC · GDB\nSWD / UART / USB DFU").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(18).frame(width:226).background(Color(nsColor:.windowBackgroundColor))
            Divider()
            VStack(spacing:0) {
                HStack {
                    VStack(alignment:.leading,spacing:5) { Text(LocalizedStringKey(s.tab == 0 ? "SCMX-build work" : s.tab == 1 ? "Projects & Build" : s.tab == 2 ? "Tools & Firmware Packs" : s.tab == 4 ? "Live Debugging" : s.tab == 5 ? "Register Assistant" : s.tab == 6 ? "Code Organization" : "Run Log")).font(.system(size:25,weight:.bold)); Text(LocalizedStringKey(s.tab == 0 ? "Select a device and firmware, then connect and flash." : s.tab == 1 ? "CubeMX generation and ARM GCC builds" : s.tab == 2 ? "Local tools, MCU database, and firmware pack repository." : s.tab == 4 ? "Breakpoints, stepping, variables, and memory · GDB + OpenOCD" : s.tab == 5 ? "Read-only GPIO, USART, I2C, and SPI register inspection" : s.tab == 6 ? "Organize user C / H files by filename prefix." : "Live output and error details.")).foregroundStyle(.secondary) }
                    Spacer()
                    if s.busy { ProgressView().controlSize(.small); Button("Stop") { s.stop() } }
                }.padding(24)
                Divider()
                if s.tab == 0 { flasherView } else if s.tab == 1 { projectView } else if s.tab == 2 { toolsView } else if s.tab == 4 { DebugView(studio:s,debug:s.debug).disabled(s.busy) } else if s.tab == 5 { RegisterView(studio:s,debug:s.debug).disabled(s.busy) } else if s.tab == 6 { organizeView } else { logView }
                Divider()
                HStack { Image(systemName:s.busy ? "hourglass" : s.failed ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(s.failed ? .red : s.busy ? .orange : .green); Text(LocalizedStringKey(s.status)).lineLimit(2).font(.callout); Spacer(); if !s.busy { Button("View Log") { s.tab = 3 }.buttonStyle(.link) } }.padding(14).background(Color(nsColor:.controlBackgroundColor))
            }
        }.background(Color(nsColor:.windowBackgroundColor)).frame(minWidth:1020,minHeight:730)
        .sheet(isPresented:$s.outputSheet) { VStack(alignment:.leading,spacing:14) { Text("Select Build Firmware").font(.title2.bold()); Text("Multiple outputs or changed paths detected. Select firmware explicitly; debugging uses the matching ELF.").foregroundStyle(.secondary); ScrollView { VStack(alignment:.leading,spacing:10) { ForEach(s.outputChoices,id:\.self) { file in Button { s.adoptFirmware(file); s.outputSheet = false } label: { Text(file).frame(maxWidth:.infinity,alignment:.leading) } } } }.frame(height:220); Button("Cancel") { s.outputSheet = false } }.padding(24).frame(width:680) }
        .sheet(isPresented:$s.newSheet) { VStack(alignment:.leading,spacing:18) { Text("Create STM32 Project").font(.title2.bold()); Text("Create a project under \(s.settings.series) and generate CMake code with CubeMX.").foregroundStyle(.secondary); TextField("Project name, e.g. MotorControl",text:$s.newName); deviceSelection; Text("Use the same device model as CubeMX. Configure pins and clocks after generation; multicore, TrustZone, and external Flash projects require device-specific configuration.").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("Cancel") { s.newSheet = false }; Button("Create and Generate") { s.create() }.buttonStyle(.borderedProminent).disabled(s.newName.isEmpty) } }.textFieldStyle(.roundedBorder).padding(26).frame(width:490) }
        .alert("Flash Firmware to Board?",isPresented:$s.flashConfirm) { Button("Cancel",role:.cancel) {}; Button("Start Flashing") { s.perform("Flash and Verify") { e,c in try e.program(.flash,c); return nil } } } message: { Text("MCU: \(s.settings.chipModel)\nBackend: \(s.settings.programmerBackend)\nTransport: \(s.settings.programmerBackend == "OpenOCD" ? "SWD" : s.settings.programmerTransport)\nSerial: \(s.settings.probeSerial.isEmpty ? L10n.string("Not specified") : s.settings.probeSerial)\nFirmware: \(s.settings.firmware)\n\(L10n.string(s.artifactMessage))\n\(s.artifact?.summary ?? "")\nThis overwrites the program on the device. After UART / DFU, restore normal boot mode and reset manually.") }
        .sheet(isPresented:$showingNavigationOrder) {
            NavigationOrderView(items:s.navigationItems) { order in s.saveNavigationOrder(order) }
        }
        .environment(\.locale,localization.language.locale)
    }
    var languagePicker: some View {
        Picker("Language",selection:$localization.language) {
            ForEach(AppLanguage.allCases) { language in Text(verbatim:language.displayName).tag(language) }
        }.pickerStyle(.menu)
    }
    func nav(_ name:String,_ icon:String,_ n:Int) -> some View { Button { s.tab = n; if n == 1 { s.refresh() } } label:{ Label(LocalizedStringKey(name),systemImage:icon).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(s.tab == n ? Color.accentColor.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain) }
    var deviceSelection: some View { VStack(alignment:.leading,spacing:9) {
        if s.records.isEmpty {
            HStack {
                TextField("Device family, e.g. STM32G4",text:$s.settings.chipFamily)
                    .onChange(of:s.settings.chipFamily) { _ in s.selectFamily(updateSeries:true) }
                TextField("Full model, e.g. STM32G431RBTx",text:$s.settings.chipModel)
                    .onChange(of:s.settings.chipModel) { _ in s.selectFamily(updateSeries:true) }
            }.textFieldStyle(.roundedBorder).onSubmit { s.selectFamily(updateSeries:true) }
        } else {
        Picker("Device Family",selection:$s.settings.chipFamily) { ForEach(s.families,id:\.self){ Text($0).tag($0) } }.onChange(of:s.settings.chipFamily){_ in s.selectFamily(updateSeries:true)}
        HStack { TextField("Search model / package, e.g. F103C8, LQFP48",text:$s.modelSearch).textFieldStyle(.roundedBorder); Text("\(s.matchingModels.count) matches").font(.caption).foregroundStyle(.secondary) }
        Picker("MCU Model",selection:$s.settings.chipModel) { if s.menuModels.isEmpty { Text("No devices found. Check the CubeMX path.").tag("") }; ForEach(s.menuModels,id:\.name) { Text($0.name + " · " + $0.package).tag($0.name) } }.onChange(of:s.settings.chipModel){_ in let e = Engine(runner:Runner(log:{_ in})); s.settings.target = e.targetFor(s.settings.chipFamily,model:s.settings.chipModel).flatMap { e.openocdFile($0,s.settings) == nil ? nil : $0 } ?? ""; s.save()}
        if s.matchingModels.count > 150 { Text("Showing the first 150 results. Search to narrow the list.").font(.caption).foregroundStyle(.secondary) }
        }
    } }
    var packSelection: some View { VStack(alignment:.leading,spacing:7) {
        if s.packs.isEmpty { HStack { Label("No \(s.settings.chipFamily) firmware pack installed",systemImage:"exclamationmark.circle").foregroundStyle(.orange); Spacer(); Button("Official Downloads") { NSWorkspace.shared.open(FirmwarePack.downloadURL(s.settings.chipFamily)) } } }
        else { Picker("Available Firmware Pack",selection:$s.settings.pack) { ForEach(s.packs,id:\.folder) { Text($0.name).tag($0.folder) } }.onChange(of:s.settings.pack){_ in s.save()} }
    } }
    var flasherView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"01  Select Device",icon:"cpu") {
            deviceSelection
            HStack { Button("Detect from Project .ioc") { s.identifyIOC() }; Button("Refresh Device Catalog") { s.reloadCatalog() }; Spacer(); Text("Device catalog from local CubeMX").font(.caption).foregroundStyle(.secondary) }
            packSelection
        }
        Card(title:"02  Programming & Storage",icon:"cable.connector") {
            ProgrammerControls(studio:s)
        }
        Card(title:"03  Serial Terminal",icon:"terminal") {
            SerialTerminalView(studio:s,terminal:s.terminal)
        }
    }.padding(24) } }
    var projectView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"01  Project Location",icon:"folder") {
            HStack { Text("Workspace").frame(width:70,alignment:.leading); TextField("Choose workspace directory",text:$s.settings.root).textFieldStyle(.roundedBorder).onSubmit{s.refresh()}; Button("Choose…") { s.choose(\.root,directory:true,title:"Choose STM32 Workspace") { s.refresh() } } }
            HStack { Picker("Series",selection:Binding(get:{s.settings.series},set:{s.settings.series = $0; s.refresh()})) { ForEach(SeriesCatalog.groups,id:\.self) { Text($0 + " · " + (SeriesCatalog.details[$0] ?? "")).tag($0) } }.pickerStyle(.menu).frame(width:360); Spacer(); Button("Refresh") { s.refresh() }; Button("Import Project…") { s.importProject() }; Button("New Project…") { s.newName = ""; s.selectFamily(updateSeries:true); s.newSheet = true } }
            Picker("Current Project",selection:$s.settings.project) { if s.projects.isEmpty { Text("No projects. Import or create one.").tag("") }; ForEach(s.projects,id:\.self) { Text(URL(fileURLWithPath:$0).lastPathComponent).tag($0) } }.onChange(of:s.settings.project){_ in s.selectProject()}
            Text(L10n.string("Supported devices: ") + (SeriesCatalog.details[s.settings.series] ?? s.settings.series)).font(.caption).foregroundStyle(.secondary)
            if s.settings.series == "MPseries" { Text("MP series supports project organization and CubeMX configuration. Linux requires its SDK; building and flashing require the appropriate Cortex-M subproject and device configuration.").font(.caption).foregroundStyle(.orange) }
            if !s.settings.project.isEmpty { Text(s.settings.project).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        Card(title:"02  Generate & Build",icon:"hammer") {
            HStack { Picker("Build Configuration",selection:$s.settings.configuration) { Text("Debug").tag("Debug"); Text("Release").tag("Release") }.frame(width:240).onChange(of:s.settings.configuration){_ in s.selectProject()}; Spacer(); Text("CMake + ARM GCC").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing:10) { Button("Open CubeMX") { s.openCube() }; Button("Organize Project") { s.perform("Organize Project") { e,c in try e.organizeProject(c); return nil } }; Button("Generate Project") { s.generateCurrent() }; Button("Build Project") { s.compileCurrent() }.buttonStyle(.borderedProminent); Spacer(); Button("Open Folder") { NSWorkspace.shared.open(URL(fileURLWithPath:s.settings.project)) } }.disabled(s.settings.project.isEmpty)
            Text("Generate from an existing .ioc; a backup is created before regeneration. Check pins, clocks, and firmware packs for new projects.").font(.caption).foregroundStyle(.secondary)
        }
        Card(title:"03  Build Results",icon:"checkmark.seal") {
            HStack {
                Image(systemName:s.failed ? "xmark.circle.fill" : ((s.status.contains("成功") || s.status.hasPrefix(L10n.string("Completed: "))) ? "checkmark.circle.fill" : "info.circle"))
                    .foregroundStyle(s.failed ? .red : ((s.status.contains("成功") || s.status.hasPrefix(L10n.string("Completed: "))) ? .green : .secondary))
                Text(LocalizedStringKey(s.status))
                Spacer()
            }
            if !s.settings.firmware.isEmpty {
                Label(URL(fileURLWithPath:s.settings.firmware).lastPathComponent,systemImage:"doc.text").textSelection(.enabled)
                if let artifact = s.artifact { Text(artifact.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } else { Text("After a successful build, the latest ELF is selected for flashing and debugging.").font(.caption).foregroundStyle(.secondary) }
            let compileDB = path(s.settings.build,"compile_commands.json")
            Label(LocalizedStringKey(FileManager.default.fileExists(atPath:compileDB) ? "compile_commands.json is available for code completion" : "No compile_commands.json yet. Configure with CMake first."), systemImage:FileManager.default.fileExists(atPath:compileDB) ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(FileManager.default.fileExists(atPath:compileDB) ? .green : .orange)
        }
        Card(title:"04  Flash to Board",icon:"cable.connector") {
            HStack { Picker("Probe",selection:$s.settings.probe) { Text("ST-Link").tag("ST-Link"); Text("CMSIS-DAP").tag("CMSIS-DAP") }.frame(width:230); Spacer(); Text("SWD Speed"); TextField("1000",text:$s.settings.speed).frame(width:65).textFieldStyle(.roundedBorder); Text("kHz").foregroundStyle(.secondary) }
            HStack { Text("Device Target").frame(width:70,alignment:.leading); TextField("Select a matching device target .cfg",text:$s.settings.target).textFieldStyle(.roundedBorder); Button("Choose…") { s.choose(\.target,title:"Choose OpenOCD Device Target") } }
            if s.settings.target.isEmpty { Text("No supported target detected. Choose a matching OpenOCD configuration; newer families may require an OpenOCD update.").font(.caption).foregroundStyle(.orange) }
            HStack { Text("Firmware File").frame(width:70,alignment:.leading); TextField("ELF selected after a successful build",text:$s.settings.firmware).textFieldStyle(.roundedBorder); Button("Choose…") { s.choose(\.firmware,title:"Choose ELF / HEX Firmware") } }
            HStack { Text("Writes are verified and the target is reset. Connect the board and probe.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Flash and Verify") { s.prepareFlash() }.buttonStyle(.borderedProminent).disabled(s.settings.firmware.isEmpty || s.settings.target.isEmpty) }
        }
        HStack {
            Button("Configure VS Code") { s.perform("Configure VS Code") { e,c in try e.configureEditor(c); return nil } }.disabled(s.settings.project.isEmpty)
            Button("Reset Build Cache") { s.resetBuild() }.disabled(s.settings.project.isEmpty)
            Spacer()
            Text("Move CMake files from Projects to the project root automatically").font(.caption).foregroundStyle(.secondary)
        }
    }.padding(24).disabled(s.busy) } }
    var organizeView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"01  User Code Organization",icon:"folder.badge.gearshape") {
            Text("Current project: \(s.settings.project.isEmpty ? L10n.string("No project selected") : s.settings.project)").font(.callout).textSelection(.enabled)
            Text("Destinations: project/Core/Src/bsp_c and project/Core/Inc/bsp_h, with equivalent folders for other layers.") .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Organize Files") { s.organizeUserFiles() }.buttonStyle(.borderedProminent).disabled(s.settings.project.isEmpty)
                Button("Open Project Folder") { NSWorkspace.shared.open(URL(fileURLWithPath:s.settings.project)) }.disabled(s.settings.project.isEmpty)
                Spacer()
            }
        }
        Card(title:"02  Organization Rules",icon:"list.bullet") {
            Text("bsp_*.c → Core/Src/bsp_c/\nbsp_*.h → Core/Inc/bsp_h/\nThe same rules apply to app_, driver_, drv_, middleware_, and service_ files.")
                .font(.system(.body, design:.monospaced)).textSelection(.enabled)
            Text("Only user files directly inside Core/Src and Core/Inc are moved. main.c, HAL, startup files, and linker scripts remain unchanged. Existing files are never overwritten; a backup is created first.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }.padding(24).disabled(s.busy) } }
    var toolsView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"Settings",icon:"globe") { languagePicker }
        Card(title:"Firmware Pack Repository",icon:"shippingbox") {
            HStack { TextField("Firmware pack directory",text:$s.settings.repository).textFieldStyle(.roundedBorder); Button("Choose…") { s.choose(\.repository,directory:true,title:"Choose STM32 Firmware Pack Repository") { s.selectFamily() } } }
            HStack { Button("Create / Check Directory") { do { try fm.createDirectory(atPath:s.settings.repository,withIntermediateDirectories:true); s.selectFamily(); s.status = "Firmware repository is ready" } catch { s.failed = true; s.status = error.localizedDescription } }; Button("Open Directory") { NSWorkspace.shared.open(URL(fileURLWithPath:s.settings.repository)) }; Spacer(); Button("ST Downloads") { NSWorkspace.shared.open(FirmwarePack.downloadURL(s.settings.chipFamily)) } }
            packSelection
            Text("Place extracted STM32Cube_FW_family_Vversion folders here. package.xml and Drivers are checked, and generation uses the selected pack. Flashing existing firmware does not require a HAL pack.").font(.caption).foregroundStyle(.secondary)
        }
        Card(title:"Local Tools",icon:"wrench.and.screwdriver") {
            tool("CubeMX",\.cube); tool("CMake",\.cmake); tool("ARM GCC",\.compiler); tool("ARM GDB",\.gdb); tool("Ninja",\.ninja); tool("OpenOCD",\.openocd); tool("CubeProg CLI",\.cubeProgrammer); tool("Host GCC",\.hostGCC)
            Text("STM32 firmware uses ARM GCC (arm-none-eabi-gcc). Host GCC/Clang is only for environment checks, not cross-compilation.").font(.caption).foregroundStyle(.secondary)
            HStack { Button("Discover and Check") { s.inspect() }.buttonStyle(.borderedProminent); Spacer(); Button("Save Paths") { s.save(); s.status = "Tool paths saved" } }
        }
        Card(title:"Project CMake Toolchain",icon:"doc.text") {
            HStack { TextField("Build directory: project/build/STM32Studio-Debug by default",text:$s.settings.outputDirectory).textFieldStyle(.roundedBorder); Button("Choose Build Directory…") { s.choose(\.outputDirectory,directory:true,title:"Choose Tracked Build Output Directory") } }
            Text("Track ELF / BIN / HEX modification time, size, and SHA-256 in this build directory. Changed paths or multiple outputs prompt a selection.").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("Default: project/cmake/gcc-arm-none-eabi.cmake",text:$s.settings.toolchain).textFieldStyle(.roundedBorder); Button("Choose…") { s.choose(\.toolchain,title:"Choose ARM GCC .cmake Toolchain") } }; Text("Reset the build cache after changing compilers. A separate STM32Studio build directory preserves existing project outputs.").font(.caption).foregroundStyle(.secondary) }
        Card(title:"Local CubeMX Device Database",icon:"cpu") { Text(LocalizedStringKey(SeriesCatalog.installedFamilies(s.settings.cube).isEmpty ? "Select a valid CubeMX executable to load the device database." : SeriesCatalog.installedFamilies(s.settings.cube).joined(separator:" · "))).font(.caption).foregroundStyle(.secondary); Text("All STM32 series are listed. Code generation depends on CubeMX and firmware pack versions; flashing depends on tool support for the specific device.").font(.caption).foregroundStyle(.secondary) }
        Card(title:"Getting Started",icon:"info.circle") { Text("1. Check tool paths. Select the CubeMX executable, usually inside Contents/MacOS in its .app.\n2. Install the matching STM32 firmware pack and save your .ioc configuration.\n3. Import or create a project → generate → build → flash.").font(.callout).lineSpacing(7) }
    }.padding(24).disabled(s.busy) } }
    func tool(_ name:String,_ key:WritableKeyPath<Settings,String>) -> some View { VStack(alignment:.leading,spacing:4) { HStack { Text(LocalizedStringKey(name)).frame(width:85,alignment:.leading); TextField("Not found. Choose a tool executable.",text:Binding(get:{s.settings[keyPath:key]},set:{s.settings[keyPath:key] = $0})).textFieldStyle(.roundedBorder); Button("Choose…") { s.choose(key,title:"Choose Tool Executable") } }; if let value = s.checks[name] { Text(L10n.string(value)).font(.caption).foregroundStyle(value.hasPrefix("✓") ? .green : .red).padding(.leading,93).lineLimit(2) } } }
    var logView: some View { VStack(spacing:12) { HStack { Text("Run Output").font(.headline); Spacer(); Button("Save Log…") { s.exportLog() }; Button("Clear") { s.log = "" }.disabled(s.busy) }; NativeLogView(text:s.log).frame(maxWidth:.infinity,maxHeight:.infinity).clipShape(RoundedRectangle(cornerRadius:8)) }.padding(24) }
}

struct NavigationOrderView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var items: [NavigationItem]
    let onSave: ([Int]) -> Void
    init(items: [NavigationItem], onSave: @escaping ([Int]) -> Void) {
        _items = State(initialValue:items)
        self.onSave = onSave
    }
    var body: some View {
        VStack(alignment:.leading,spacing:16) {
            Text("Reorder Sidebar").font(.title2.bold())
            Text("Drag items to reorder the sidebar. The order is saved between launches.") .foregroundStyle(.secondary)
            List {
                ForEach(items) { item in Label(LocalizedStringKey(item.title),systemImage:item.icon) }
                    .onMove { items.move(fromOffsets:$0,toOffset:$1) }
            }.frame(width:360,height:300)
            HStack { Button("Restore Defaults") { items = navigationCatalog }; Spacer(); Button("Cancel") { dismiss() }; Button("Save Order") { onSave(items.map(\.id)); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(22).frame(width:430,height:420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let studio = Studio()
    func applicationDidFinishLaunching(_ notification: Notification) {
        updateLocalizedChrome()
        NotificationCenter.default.addObserver(self,selector:#selector(updateLocalizedChrome),name:LocalizationSettings.didChange,object:nil)
        if let i = CommandLine.arguments.firstIndex(of:"--smoke-tab"), CommandLine.arguments.count > i+1 { studio.tab = Int(CommandLine.arguments[i+1]) ?? 0 }
        let logStress = CommandLine.arguments.contains("--smoke-log-stress")
        if logStress {
            studio.log = ""
            for chunk in LogStressFixture.chunks { studio.append(chunk) }
            studio.failed = true
            studio.status = L10n.string("Failed: ") + L10n.string("Build Project")
            studio.tab = 3
        }
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1140,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = L10n.string("SCMX-build work · Preview"); w.minSize = NSSize(width:1040,height:760); w.contentView = NSHostingView(rootView:MainView(s:studio)); w.center(); w.makeKeyAndOrderFront(nil); window = w
        NSApp.activate(ignoringOtherApps:true)
        if logStress {
            // Exercise clear, truncation, and incremental updates after the native view mounts.
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.2) { self.studio.log = "" }
            for batch in 0..<3 {
                DispatchQueue.main.asyncAfter(deadline:.now() + 0.4 + Double(batch) * 0.2) {
                    let chunks = LogStressFixture.chunks
                    let start = batch * 30
                    let end = batch == 2 ? chunks.count : start + 30
                    for chunk in chunks[start..<end] { self.studio.append(chunk) }
                }
            }
            DispatchQueue.main.asyncAfter(deadline:.now() + 1.1) { self.studio.append(LogStressFixture.tailMarker + "\n") }
        }
        if let i = CommandLine.arguments.firstIndex(of:"--smoke-test"), CommandLine.arguments.count > i + 1 {
            let output = CommandLine.arguments[i+1]
            DispatchQueue.main.asyncAfter(deadline:.now() + 2) {
                var report = "interfaceLanguage=\(LocalizationSettings.shared.language.rawValue)\nlocalizedFlashing=\(L10n.string("Flashing"))\nwindowVisible=\(w.isVisible)\nwindowTitle=\(w.title)\ncontentView=\(String(describing:type(of:w.contentView!)))\nsize=\(w.contentView!.bounds.size)\nprojects=\(self.studio.projects.count)\n"
                if logStress, let root = w.contentView {
                    report += LogViewDiagnostics.report(root:root,source:self.studio.log,outputDirectory:output)
                }
                try? write(report,path(output,"launch-check.txt"))
                if let view = w.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    if let image = bitmap.representation(using:.png,properties:[:]) { try? image.write(to:URL(fileURLWithPath:path(output,"app-preview.png"))) }
                }
                NSApp.terminate(nil)
            }
        }
    }
    @objc private func updateLocalizedChrome() {
        let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu(); sub.addItem(withTitle:L10n.string("About SCMX-build work"),action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:""); sub.addItem(.separator()); sub.addItem(withTitle:L10n.string("Quit SCMX-build work"),action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); item.submenu = sub; menu.addItem(item)
        let editItem = NSMenuItem(title:L10n.string("Edit"),action:nil,keyEquivalent:""), edit = NSMenu(title:L10n.string("Edit")); for (name,selector,key) in [("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] { edit.addItem(withTitle:L10n.string(name),action:Selector(selector),keyEquivalent:key) }; editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        window?.title = L10n.string("SCMX-build work · Preview")
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { if studio.busy { let a = NSAlert(); a.messageText = L10n.string("Operation in Progress"); a.informativeText = L10n.string("Wait for the current operation to finish, or stop it before quitting."); a.runModal(); return .terminateCancel }; studio.debug.disconnect(); studio.save(); return .terminateNow }
}
