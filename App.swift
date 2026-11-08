import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct NavigationItem: Identifiable, Hashable {
    let id: Int
    let title: String
    let icon: String
}

let navigationCatalog = [
    NavigationItem(id:0,title:"烧录工作台",icon:"cable.connector"),
    NavigationItem(id:4,title:"调试",icon:"ant"),
    NavigationItem(id:5,title:"寄存器助手",icon:"list.bullet.rectangle"),
    NavigationItem(id:6,title:"代码整理",icon:"folder.badge.gearshape"),
    NavigationItem(id:1,title:"工程与编译",icon:"square.stack.3d.up"),
    NavigationItem(id:2,title:"工具与固件包",icon:"wrench.and.screwdriver"),
    NavigationItem(id:3,title:"运行日志",icon:"terminal")
]

final class Studio: ObservableObject {
    let debug = DebugSession()
    let terminal = SerialTerminal()
    @Published var settings: Settings
    @Published var projects: [String] = []
    @Published var busy = false
    @Published var status = "就绪 · 选择工程后开始"
    @Published var failed = false
    @Published var log = "STM32 工程配置\n生成 → 编译 → 烧录；所有执行结果显示于此。\n"
    @Published var checks: [String:String] = [:]
    @Published var tab = 0
    @Published var records:[MCURecord] = []
    @Published var modelSearch = ""
    @Published var serialDevices:[SerialDevice] = []
    @Published var artifact:FirmwareArtifact?
    @Published var artifactMessage = "尚未选择固件"
    @Published var outputChoices:[String] = []
    @Published var outputSheet = false
    private var lastCandidateSignature = ""
    private var trackedProject = ""
    @Published var newSheet = false
    @Published var newName = ""
    @Published var mcu = "STM32G431RBTx"
    @Published var flashConfirm = false
    private var runner: Runner?
    let savePath = NSHomeDirectory() + "/Library/Application Support/STM32WorkbenchPreview/settings.json"
    init() {
        settings = Settings.load(savePath); trackedProject = settings.project
        settings.discover(); records = DeviceCatalog.load(settings.cube)
        let saved = settings
        refresh()
        settings.series = saved.series; settings.chipFamily = saved.chipFamily; settings.chipModel = saved.chipModel; settings.pack = saved.pack
        if exists(saved.firmware) { settings.firmware = saved.firmware }; if exists(saved.debugELF) { settings.debugELF = saved.debugELF }; settings.outputDirectory = saved.outputDirectory; settings.followBuildOutputs = saved.followBuildOutputs; selectFamily(); scanSerial(); refreshArtifact(force:true)
        try? fm.createDirectory(atPath:settings.repository,withIntermediateDirectories:true)
        Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in self?.scanSerial(); self?.refreshArtifact(); self?.debug.checkELF() }
    }
    var families:[String] { Array(Set(records.filter{$0.family.hasPrefix(SeriesCatalog.prefix(settings.series))}.map(\.family))).sorted() }
    var matchingModels:[MCURecord] { records.filter { $0.family == settings.chipFamily && (modelSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(modelSearch) || $0.package.localizedCaseInsensitiveContains(modelSearch)) } }
    var menuModels:[MCURecord] {
        var rows = Array(matchingModels.prefix(150))
        if !rows.contains(where:{$0.name == settings.chipModel}), let selected = records.first(where:{$0.name == settings.chipModel}) { rows.insert(selected,at:0) }
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
    func selectFamily() {
        if !families.contains(settings.chipFamily) { settings.chipFamily = families.first ?? "" }
        let models = records.filter{$0.family == settings.chipFamily}
        if !models.contains(where:{$0.name == settings.chipModel}) { settings.chipModel = models.first?.name ?? "" }
        let e = Engine(runner:Runner(log:{_ in}))
        settings.target = e.targetFor(settings.chipFamily,model:settings.chipModel).flatMap { e.openocdFile($0,settings) == nil ? nil : $0 } ?? ""
        if !packs.contains(where:{$0.folder == settings.pack}) { settings.pack = packs.first?.folder ?? "" }
        modelSearch = ""; save()
    }
    func reloadCatalog() { records = DeviceCatalog.load(settings.cube); selectFamily(); status = "已加载 \(records.count) 个 MCU 型号" }
    func scanSerial() {
        DispatchQueue.global(qos:.utility).async {
            let ports = SerialCatalog.scan()
            DispatchQueue.main.async { self.serialDevices = ports; if !self.settings.serialPort.isEmpty && !ports.contains(where:{$0.port == self.settings.serialPort}) { self.settings.serialPort = "" } }
        }
    }
    func identifyIOC() {
        let f = DeviceCatalog.iocValue("Mcu.Family",settings.project), chip = DeviceCatalog.iocValue("Mcu.UserName",settings.project)
        guard !f.isEmpty, !chip.isEmpty else { status = "当前工程无可识别的 .ioc，请手动选择型号"; failed = true; return }
        settings.series = SeriesCatalog.group(f) ?? settings.series; settings.chipFamily = f; settings.chipModel = chip; selectFamily(); status = "从 .ioc 识别：" + chip; failed = false
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
        guard !file.isEmpty else { artifact = nil; artifactMessage = "尚未选择固件"; return }
        guard exists(file) else {
            artifact = nil; artifactMessage = "原固件路径已不存在，请刷新并选择输出"
            if settings.followBuildOutputs { let options = FirmwareArtifact.outputs(settings.build); let signature = options.joined(separator:"|"); if !options.isEmpty && signature != lastCandidateSignature { lastCandidateSignature = signature; outputChoices = options; outputSheet = true } }
            return
        }
        let attributes = try? fm.attributesOfItem(atPath:file)
        if !force, artifact?.file == file, attributes?[.modificationDate] as? Date == artifact?.modified, attributes?[.size] as? UInt64 == artifact?.size { return }
        do {
            artifact = try FirmwareArtifact.inspect(file)
            artifactMessage = settings.followBuildOutputs ? "将烧录新生成的文件（自动跟踪）" : "手动选择的固件（自动刷新文件内容）"
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
        perform("编译工程") { e,c in
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
    func choose(_ key: WritableKeyPath<Settings,String>, directory: Bool = false, title: String = "选择文件", completion:(()->Void)? = nil) {
        let panel = NSOpenPanel(); panel.title = title; panel.canChooseDirectories = directory; panel.canChooseFiles = !directory; panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        if panel.runModal() == .OK, let url = panel.url { settings[keyPath:key] = url.path
            if key == \Settings.firmware { adoptFirmware(url.path,automatic:false) }
            if key == \Settings.debugELF { settings.debugELF = url.path }
            save(); completion?() }
    }
    func append(_ s: String) { log += s; if log.count > 180000 { log = String(log.suffix(150000)) } }
    func perform(_ title: String, _ operation: @escaping (Engine,Settings)throws -> String?) {
        guard !busy else { return }
        if debug.active { failed = true; status = "请先断开调试会话，再执行此操作"; return }
        if terminal.connected && settings.programmerBackend == "CubeProgrammer" && settings.programmerTransport == "UART" {
            failed = true; status = "请先断开串口终端，释放 UART 下载端口"; return
        }
        save(); busy = true; failed = false; status = title + "…"; append("\n━━━━ \(title) ━━━━\n")
        let r = Runner { [weak self] value in DispatchQueue.main.async { self?.append(value) } }; runner = r
        let snapshot = settings
        DispatchQueue.global(qos:.userInitiated).async {
            do {
                let result = try operation(Engine(runner:r),snapshot)
                DispatchQueue.main.async { self.busy = false; self.runner = nil; self.status = title + "成功"; self.append("✓ \(title)成功\n"); self.refreshArtifact(force:true); if let result { self.settings.firmware = result }; if title.contains("生成") { self.selectProject() }; self.save() }
            } catch { let message = error.localizedDescription; DispatchQueue.main.async { self.busy = false; self.runner = nil; self.failed = true; self.status = title + "失败"; self.append("✕ \(message)\n"); self.tab = 3 } }
        }
    }
    func stop() { runner?.cancel(); status = "正在停止…" }
    func inspect() {
        settings.discover(); reloadCatalog(); checks = [:]
        perform("工具检查") { e,s in
            var problems:[String] = []
            for (name,exe) in [("CMake",s.cmake),("Ninja",s.ninja),("ARM GCC",s.compiler),("ARM GDB",s.gdb),("本机 GCC",s.hostGCC),("OpenOCD",s.openocd)] {
                do { let v = try e.runner.run(exe,["--version"],env:s.environment,timeout:15); DispatchQueue.main.async { self.checks[name] = "✓ " + String(v.split(separator:"\n").first ?? "可用") } }
                catch { problems.append(name); DispatchQueue.main.async { self.checks[name] = "✕ 不可用，请重新选择" }; e.runner.log(error.localizedDescription + "\n") }
            }
            let cubeOK = fm.isExecutableFile(atPath:s.cube)
            DispatchQueue.main.async { self.checks["CubeMX"] = cubeOK ? "✓ 已找到可执行程序" : "✕ 未找到 CubeMX" }
            if !cubeOK { problems.append("CubeMX") }
            if fm.isExecutableFile(atPath:s.cubeProgrammer) {
                do {
                    _ = try e.runner.run(s.cubeProgrammer,["-h"],env:s.environment,timeout:15)
                    DispatchQueue.main.async { self.checks["CubeProg CLI"] = "✓ 可用（可选后端）" }
                } catch { DispatchQueue.main.async { self.checks["CubeProg CLI"] = "✕ 无法运行，请重新选择" } }
            } else { DispatchQueue.main.async { self.checks["CubeProg CLI"] = "未安装；UART / DFU 需要此可选后端" } }
            do { try e.validateCompiler(s) } catch { problems.append("ARM 目标检查"); e.runner.log(error.localizedDescription + "\n") }
            if !problems.isEmpty { throw StudioError("以下工具需要处理：" + problems.joined(separator:"、")) }
            return nil
        }
    }
    func importProject() {
        let panel = NSOpenPanel(); panel.title = "导入现有 CubeMX 工程（保留原文件）"; panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform("导入工程") { e,s in let dest = try e.importProject(url.path,s); DispatchQueue.main.async { self.settings.project = dest; self.refresh() }; return nil }
    }
    func organizeUserFiles() {
        perform("代码整理") { e,s in try e.organizeUserFiles(s); return nil }
    }
    func requirePack(_ family:String) -> Bool {
        if !FirmwarePack.available(repository:settings.repository,family:family).isEmpty { return true }
        failed = true; status = "未安装 " + family + " 固件包，已打开官方下载入口"; append(status + "\n"); NSWorkspace.shared.open(FirmwarePack.downloadURL(family)); return false
    }
    func generateCurrent() {
        let family = Engine(runner:Runner(log:{_ in})).family(settings.project)
        guard !family.isEmpty else { failed = true; status = "当前工程没有可识别的 .ioc"; return }
        guard requirePack(family) else { return }
        perform("生成工程") { e,c in try e.generate(c); return nil }
    }
    func create() {
        guard requirePack(settings.chipFamily) else { return }
        let name = newName, chip = settings.chipModel; newSheet = false
        perform("创建并生成工程") { e,s in
            guard SeriesCatalog.accepts(chip,s.series) else { throw StudioError("请填写当前系列的完整 MCU 型号。") }
            let dest = try e.create(root:s.root,series:s.series,name:name); var next = s; next.project = dest
            DispatchQueue.main.async { self.settings.project = dest; self.refresh() }
            try e.generate(next,mcu:chip); return nil
        }
    }
    func openCube() {
        save(); guard fm.isExecutableFile(atPath:settings.cube) else { failed = true; status = "未找到 CubeMX，请在工具链中选择"; tab = 2; return }
        let p = Process(); p.executableURL = URL(fileURLWithPath:settings.cube); p.currentDirectoryURL = URL(fileURLWithPath:settings.cube).deletingLastPathComponent(); p.environment = settings.environment
        if let file = try? Engine(runner:Runner(log:{_ in})).ioc(settings.project) { p.arguments = [file] }
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        do { try p.run(); status = "已打开 CubeMX · 完成芯片配置后保存 .ioc" } catch { failed = true; status = error.localizedDescription }
    }
    func exportLog() { let p = NSSavePanel(); p.nameFieldStringValue = "STM32运行日志.txt"; if p.runModal() == .OK, let u = p.url { do { try log.write(to:u,atomically:true,encoding:.utf8) } catch { status = error.localizedDescription; failed = true } } }
    func resetBuild() {
        perform("重置构建缓存") { _,s in
            guard !s.project.isEmpty else { throw StudioError("请先选择工程。") }
            if exists(s.build) { let moved = s.build + ".previous-" + String(Int(Date().timeIntervalSince1970)); try fm.moveItem(atPath:s.build,toPath:moved) }
            return ""
        }
    }
}

struct Card<Content:View>: View {
    let title: String; let icon: String; @ViewBuilder var content: Content
    var body: some View { VStack(alignment:.leading,spacing:13) { Label(title,systemImage:icon).font(.headline); content }.padding(18).frame(maxWidth:.infinity,alignment:.leading).background(Color(nsColor:.controlBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:12)).overlay(RoundedRectangle(cornerRadius:12).stroke(Color.primary.opacity(0.08))) }
}
struct MainView: View {
    @ObservedObject var s: Studio
    @State private var showingNavigationOrder = false
    var body: some View {
        HStack(spacing:0) {
            VStack(alignment:.leading,spacing:22) {
                HStack { Image(systemName:"cpu").font(.system(size:30)).foregroundStyle(.cyan); VStack(alignment:.leading) { Text("STM32").font(.title2.bold()); Text("macOS 开发工作台").foregroundStyle(.secondary) } }.padding(.top,14)
                Text("开发工作台").font(.caption).foregroundStyle(.secondary)
                ForEach(s.navigationItems) { item in nav(item.title,item.icon,item.id) }
                Spacer()
                Divider()
                Button { showingNavigationOrder = true } label: { Label("调整侧栏顺序",systemImage:"arrow.up.arrow.down").frame(maxWidth:.infinity,alignment:.leading).padding(10) }.buttonStyle(.plain)
                Label("原生 macOS 应用",systemImage:"macwindow").font(.caption).foregroundStyle(.secondary)
                Text("CMake · ARM GCC · GDB\nSWD / UART / USB DFU").font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(22).frame(width:185).background(Color(nsColor:.windowBackgroundColor))
            Divider()
            VStack(spacing:0) {
                HStack {
                    VStack(alignment:.leading,spacing:5) { Text(s.tab == 0 ? "WebCode · STM32 烧录" : s.tab == 1 ? "工程与编译" : s.tab == 2 ? "工具与固件包" : s.tab == 4 ? "在线调试" : s.tab == 5 ? "寄存器助手" : s.tab == 6 ? "代码整理" : "每一步，都有结果").font(.system(size:25,weight:.bold)); Text(s.tab == 0 ? "选择型号与固件，连接开发板，然后烧录。" : s.tab == 1 ? "附加功能 · CubeMX 生成与 ARM GCC 编译" : s.tab == 2 ? "管理本机工具、MCU 数据库与统一固件包目录。" : s.tab == 4 ? "断点、单步、变量与内存 · GDB + OpenOCD" : s.tab == 5 ? "GPIO、USART、I2C、SPI 常用寄存器只读查看" : s.tab == 6 ? "按用户代码前缀整理 C / H 文件到对应目录。" : "实时输出与错误原因，便于检查和保存。").foregroundStyle(.secondary) }
                    Spacer()
                    if s.busy { ProgressView().controlSize(.small); Button("停止") { s.stop() } }
                }.padding(24)
                Divider()
                if s.tab == 0 { flasherView } else if s.tab == 1 { projectView } else if s.tab == 2 { toolsView } else if s.tab == 4 { DebugView(studio:s,debug:s.debug).disabled(s.busy) } else if s.tab == 5 { RegisterView(studio:s,debug:s.debug).disabled(s.busy) } else if s.tab == 6 { organizeView } else { logView }
                Divider()
                HStack { Image(systemName:s.busy ? "hourglass" : s.failed ? "xmark.circle.fill" : "checkmark.circle.fill").foregroundStyle(s.failed ? .red : s.busy ? .orange : .green); Text(s.status).lineLimit(2).font(.callout); Spacer(); if !s.busy { Button("查看日志") { s.tab = 3 }.buttonStyle(.link) } }.padding(14).background(Color(nsColor:.controlBackgroundColor))
            }
        }.background(Color(nsColor:.windowBackgroundColor)).frame(minWidth:1020,minHeight:730)
        .sheet(isPresented:$s.outputSheet) { VStack(alignment:.leading,spacing:14) { Text("选择本次构建固件").font(.title2.bold()); Text("发现多个输出或文件路径发生变化，请明确选择。调试将使用所选文件对应的 ELF。").foregroundStyle(.secondary); ScrollView { VStack(alignment:.leading,spacing:10) { ForEach(s.outputChoices,id:\.self) { file in Button { s.adoptFirmware(file); s.outputSheet = false } label: { Text(file).frame(maxWidth:.infinity,alignment:.leading) } } } }.frame(height:220); Button("取消") { s.outputSheet = false } }.padding(24).frame(width:680) }
        .sheet(isPresented:$s.newSheet) { VStack(alignment:.leading,spacing:18) { Text("创建 STM32 工程").font(.title2.bold()); Text("将在 \(s.settings.series) 下建立工程，并通过 CubeMX 生成 CMake 代码。").foregroundStyle(.secondary); TextField("工程名，例如 MotorControl",text:$s.newName); deviceSelection; Text("型号需与 CubeMX 中一致。生成后请打开 CubeMX 配置引脚和时钟；多核、TrustZone、外部 Flash 工程需按芯片配置。").font(.caption).foregroundStyle(.secondary); HStack { Spacer(); Button("取消") { s.newSheet = false }; Button("创建并生成") { s.create() }.buttonStyle(.borderedProminent).disabled(s.newName.isEmpty) } }.textFieldStyle(.roundedBorder).padding(26).frame(width:490) }
        .alert("将固件写入开发板？",isPresented:$s.flashConfirm) { Button("取消",role:.cancel) {}; Button("开始烧录") { s.perform("烧录并校验") { e,c in try e.program(.flash,c); return nil } } } message: { Text("MCU：\(s.settings.chipModel)\n后端：\(s.settings.programmerBackend)\n接口：\(s.settings.programmerBackend == "OpenOCD" ? "SWD" : s.settings.programmerTransport)\n序列号：\(s.settings.probeSerial.isEmpty ? "未指定" : s.settings.probeSerial)\n固件：\(s.settings.firmware)\n\(s.artifactMessage)\n\(s.artifact?.summary ?? "")\n将覆盖芯片上的现有程序。UART / DFU 完成后需切回正常启动并手动复位。") }
        .sheet(isPresented:$showingNavigationOrder) {
            NavigationOrderView(items:s.navigationItems) { order in s.saveNavigationOrder(order) }
        }
    }
    func nav(_ name:String,_ icon:String,_ n:Int) -> some View { Button { s.tab = n; if n == 1 { s.refresh() } } label:{ Label(name,systemImage:icon).frame(maxWidth:.infinity,alignment:.leading).padding(10).background(s.tab == n ? Color.accentColor.opacity(0.13) : .clear).clipShape(RoundedRectangle(cornerRadius:8)) }.buttonStyle(.plain) }
    var deviceSelection: some View { VStack(alignment:.leading,spacing:9) {
        HStack { Picker("系列",selection:$s.settings.series) { ForEach(SeriesCatalog.groups,id:\.self) { Text($0).tag($0) } }.onChange(of:s.settings.series){_ in s.selectFamily()}; Picker("芯片系列",selection:$s.settings.chipFamily) { if s.families.isEmpty { Text("无数据库").tag("") }; ForEach(s.families,id:\.self){ Text($0).tag($0) } }.onChange(of:s.settings.chipFamily){_ in s.selectFamily()} }
        HStack { TextField("搜索型号 / 封装，例如 F103C8、LQFP48",text:$s.modelSearch).textFieldStyle(.roundedBorder); Text("\(s.matchingModels.count) 个匹配").font(.caption).foregroundStyle(.secondary) }
        Picker("MCU 型号",selection:$s.settings.chipModel) { if s.menuModels.isEmpty { Text("未找到型号，请检查 CubeMX 路径").tag("") }; ForEach(s.menuModels,id:\.name) { Text($0.name + " · " + $0.package).tag($0.name) } }.onChange(of:s.settings.chipModel){_ in let e = Engine(runner:Runner(log:{_ in})); s.settings.target = e.targetFor(s.settings.chipFamily,model:s.settings.chipModel).flatMap { e.openocdFile($0,s.settings) == nil ? nil : $0 } ?? ""; s.save()}
        if s.matchingModels.count > 150 { Text("先显示前 150 项，输入搜索文字可缩小范围。").font(.caption).foregroundStyle(.secondary) }
    } }
    var packSelection: some View { VStack(alignment:.leading,spacing:7) {
        if s.packs.isEmpty { HStack { Label("未安装 \(s.settings.chipFamily) 固件包",systemImage:"exclamationmark.circle").foregroundStyle(.orange); Spacer(); Button("官方下载入口") { NSWorkspace.shared.open(FirmwarePack.downloadURL(s.settings.chipFamily)) } } }
        else { Picker("可用固件包",selection:$s.settings.pack) { ForEach(s.packs,id:\.folder) { Text($0.name).tag($0.folder) } }.onChange(of:s.settings.pack){_ in s.save()} }
    } }
    var flasherView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"01  选择芯片",icon:"cpu") {
            deviceSelection
            HStack { Button("从当前工程 .ioc 识别") { s.identifyIOC() }; Button("刷新型号库") { s.reloadCatalog() }; Spacer(); Text("型号来自本机 CubeMX").font(.caption).foregroundStyle(.secondary) }
            packSelection
        }
        Card(title:"02  下载与存储",icon:"cable.connector") {
            ProgrammerControls(studio:s)
        }
        Card(title:"03  串口终端",icon:"terminal") {
            SerialTerminalView(studio:s,terminal:s.terminal)
        }
    }.padding(24) } }
    var projectView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"01  工程位置",icon:"folder") {
            HStack { Text("总目录").frame(width:70,alignment:.leading); TextField("选择总目录",text:$s.settings.root).textFieldStyle(.roundedBorder).onSubmit{s.refresh()}; Button("选择…") { s.choose(\.root,directory:true,title:"选择 STM32 总目录") { s.refresh() } } }
            HStack { Picker("系列",selection:$s.settings.series) { ForEach(SeriesCatalog.groups,id:\.self) { Text($0 + " · " + (SeriesCatalog.details[$0] ?? "")).tag($0) } }.pickerStyle(.menu).frame(width:360).onChange(of:s.settings.series){ _ in s.refresh() }; Spacer(); Button("刷新") { s.refresh() }; Button("导入工程…") { s.importProject() }; Button("新建工程…") { s.newName = ""; s.selectFamily(); s.newSheet = true } }
            Picker("当前工程",selection:$s.settings.project) { if s.projects.isEmpty { Text("暂无工程，请导入或新建").tag("") }; ForEach(s.projects,id:\.self) { Text(URL(fileURLWithPath:$0).lastPathComponent).tag($0) } }.onChange(of:s.settings.project){_ in s.selectProject()}
            Text("覆盖 " + (SeriesCatalog.details[s.settings.series] ?? s.settings.series)).font(.caption).foregroundStyle(.secondary)
            if s.settings.series == "MPseries" { Text("MP 系列支持工程归类和 CubeMX 配置；Linux 使用专用 SDK，编译/烧录需选择 Cortex-M 子工程及对应芯片配置。").font(.caption).foregroundStyle(.orange) }
            if !s.settings.project.isEmpty { Text(s.settings.project).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
        }
        Card(title:"02  生成与编译",icon:"hammer") {
            HStack { Picker("构建模式",selection:$s.settings.configuration) { Text("Debug").tag("Debug"); Text("Release").tag("Release") }.frame(width:240).onChange(of:s.settings.configuration){_ in s.selectProject()}; Spacer(); Text("CMake + ARM GCC").font(.caption).foregroundStyle(.secondary) }
            HStack(spacing:10) { Button("打开 CubeMX") { s.openCube() }; Button("整理工程目录") { s.perform("整理工程目录") { e,c in try e.organizeProject(c); return nil } }; Button("生成工程") { s.generateCurrent() }; Button("编译工程") { s.compileCurrent() }.buttonStyle(.borderedProminent); Spacer(); Button("打开文件夹") { NSWorkspace.shared.open(URL(fileURLWithPath:s.settings.project)) } }.disabled(s.settings.project.isEmpty)
            Text("已有 .ioc 可直接生成；重新生成前自动备份。新工程请先确认引脚、时钟与固件包。").font(.caption).foregroundStyle(.secondary)
        }
        Card(title:"03  构建结果",icon:"checkmark.seal") {
            HStack {
                Image(systemName:s.failed ? "xmark.circle.fill" : (s.status.contains("成功") ? "checkmark.circle.fill" : "info.circle"))
                    .foregroundStyle(s.failed ? .red : (s.status.contains("成功") ? .green : .secondary))
                Text(s.status)
                Spacer()
            }
            if !s.settings.firmware.isEmpty {
                Label(URL(fileURLWithPath:s.settings.firmware).lastPathComponent,systemImage:"doc.text").textSelection(.enabled)
                if let artifact = s.artifact { Text(artifact.summary).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
            } else { Text("编译成功后会自动选择最新 ELF，并同步到烧录页和调试页。").font(.caption).foregroundStyle(.secondary) }
            let compileDB = path(s.settings.build,"compile_commands.json")
            Label(FileManager.default.fileExists(atPath:compileDB) ? "compile_commands.json 已生成，函数提示可用" : "尚未生成 compile_commands.json，请先执行 CMake 配置", systemImage:FileManager.default.fileExists(atPath:compileDB) ? "checkmark.circle" : "exclamationmark.triangle")
                .font(.caption).foregroundStyle(FileManager.default.fileExists(atPath:compileDB) ? .green : .orange)
        }
        Card(title:"04  烧录到开发板",icon:"cable.connector") {
            HStack { Picker("烧录器",selection:$s.settings.probe) { Text("ST-Link").tag("ST-Link"); Text("CMSIS-DAP").tag("CMSIS-DAP") }.frame(width:230); Spacer(); Text("SWD 速度"); TextField("1000",text:$s.settings.speed).frame(width:65).textFieldStyle(.roundedBorder); Text("kHz").foregroundStyle(.secondary) }
            HStack { Text("芯片目标").frame(width:70,alignment:.leading); TextField("本机无匹配配置，请选择芯片 target .cfg",text:$s.settings.target).textFieldStyle(.roundedBorder); Button("选择…") { s.choose(\.target,title:"选择 OpenOCD 芯片 target 配置") } }
            if s.settings.target.isEmpty { Text("当前工程未识别到本机支持的芯片目标。请先选择匹配的 OpenOCD 配置；新系列可能需要更新 OpenOCD。").font(.caption).foregroundStyle(.orange) }
            HStack { Text("固件文件").frame(width:70,alignment:.leading); TextField("编译成功后自动选择 .elf",text:$s.settings.firmware).textFieldStyle(.roundedBorder); Button("选择…") { s.choose(\.firmware,title:"选择 ELF / HEX 固件") } }
            HStack { Text("完成写入后自动校验并复位。请连接开发板与烧录器。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("烧录并校验") { s.prepareFlash() }.buttonStyle(.borderedProminent).disabled(s.settings.firmware.isEmpty || s.settings.target.isEmpty) }
        }
        HStack {
            Button("配置 VS Code") { s.perform("配置 VS Code") { e,c in try e.configureEditor(c); return nil } }.disabled(s.settings.project.isEmpty)
            Button("重置构建缓存") { s.resetBuild() }.disabled(s.settings.project.isEmpty)
            Spacer()
            Text("自动将 Projects 下的 CMake 文件归位到工程根目录").font(.caption).foregroundStyle(.secondary)
        }
    }.padding(24).disabled(s.busy) } }
    var organizeView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"01  用户代码整理",icon:"folder.badge.gearshape") {
            Text("当前工程：\(s.settings.project.isEmpty ? "未选择工程" : s.settings.project)").font(.callout).textSelection(.enabled)
            Text("整理位置：工程/Core/Src/bsp_c 和 工程/Core/Inc/bsp_h；其他层按相同规则创建对应目录。") .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("开始整理") { s.organizeUserFiles() }.buttonStyle(.borderedProminent).disabled(s.settings.project.isEmpty)
                Button("打开工程文件夹") { NSWorkspace.shared.open(URL(fileURLWithPath:s.settings.project)) }.disabled(s.settings.project.isEmpty)
                Spacer()
            }
        }
        Card(title:"02  当前整理规则",icon:"list.bullet") {
            Text("bsp_*.c → Core/Src/bsp_c/\nbsp_*.h → Core/Inc/bsp_h/\napp_、driver_、drv_、middleware_、service_ 文件按同样方式整理。")
                .font(.system(.body, design:.monospaced)).textSelection(.enabled)
            Text("只处理 Core/Src 和 Core/Inc 直接下的用户文件；main.c、HAL、启动文件和链接脚本不会移动。同名文件不会覆盖，整理前会自动备份。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }.padding(24).disabled(s.busy) } }
    var toolsView: some View { ScrollView { VStack(spacing:16) {
        Card(title:"统一固件包目录",icon:"shippingbox") {
            HStack { TextField("固件包目录",text:$s.settings.repository).textFieldStyle(.roundedBorder); Button("选择…") { s.choose(\.repository,directory:true,title:"选择统一 STM32 固件包目录") { s.selectFamily() } } }
            HStack { Button("创建 / 检查目录") { do { try fm.createDirectory(atPath:s.settings.repository,withIntermediateDirectories:true); s.selectFamily(); s.status = "固件包目录已就绪" } catch { s.failed = true; s.status = error.localizedDescription } }; Button("打开目录") { NSWorkspace.shared.open(URL(fileURLWithPath:s.settings.repository)) }; Spacer(); Button("ST 官方下载") { NSWorkspace.shared.open(FirmwarePack.downloadURL(s.settings.chipFamily)) } }
            packSelection
            Text("解压后的 STM32Cube_FW_系列_V版本 文件夹放入此目录。应用会检查 package.xml 和 Drivers；生成时明确使用所选包。烧录已有固件不需要 HAL 固件包。").font(.caption).foregroundStyle(.secondary)
        }
        Card(title:"本机工具",icon:"wrench.and.screwdriver") {
            tool("CubeMX",\.cube); tool("CMake",\.cmake); tool("ARM GCC",\.compiler); tool("ARM GDB",\.gdb); tool("Ninja",\.ninja); tool("OpenOCD",\.openocd); tool("CubeProg CLI",\.cubeProgrammer); tool("本机 GCC",\.hostGCC)
            Text("STM32 固件使用 ARM GCC（arm-none-eabi-gcc）。本机 GCC/Clang 仅用于环境检查，不能替代交叉编译器。").font(.caption).foregroundStyle(.secondary)
            HStack { Button("自动查找并检查") { s.inspect() }.buttonStyle(.borderedProminent); Spacer(); Button("保存路径") { s.save(); s.status = "工具路径已保存" } }
        }
        Card(title:"当前工程的 CMake 工具链文件",icon:"doc.text") {
            HStack { TextField("构建目录：默认工程/build/STM32Studio-Debug",text:$s.settings.outputDirectory).textFieldStyle(.roundedBorder); Button("选择构建目录…") { s.choose(\.outputDirectory,directory:true,title:"选择需要跟踪的构建输出目录") } }
            Text("记住当前构建目录，自动跟踪 ELF / BIN / HEX 的修改时间、大小和 SHA-256；路径改变或多目标输出时提示选择。").font(.caption).foregroundStyle(.secondary)
            HStack { TextField("默认：工程/cmake/gcc-arm-none-eabi.cmake",text:$s.settings.toolchain).textFieldStyle(.roundedBorder); Button("选择…") { s.choose(\.toolchain,title:"选择 ARM GCC 的 .cmake 工具链文件") } }; Text("更换编译器后，请重置构建缓存。使用独立的 STM32Studio 构建目录，保留工程原有的构建输出。").font(.caption).foregroundStyle(.secondary) }
        Card(title:"本机 CubeMX 芯片数据库",icon:"cpu") { Text(SeriesCatalog.installedFamilies(s.settings.cube).isEmpty ? "选择有效 CubeMX 后读取芯片数据库。" : SeriesCatalog.installedFamilies(s.settings.cube).joined(separator:" · ")).font(.caption).foregroundStyle(.secondary); Text("系列列表覆盖所有 STM32 大类。实际代码生成依赖所选 CubeMX 版本和固件包；烧录依赖工具对具体芯片的支持。").font(.caption).foregroundStyle(.secondary) }
        Card(title:"首次使用",icon:"info.circle") { Text("1. 检查上面的工具路径。CubeMX 请选择可执行文件；.app 内通常位于 Contents/MacOS。\n2. 在 CubeMX 中安装对应 STM32 固件包，并保存 .ioc 配置。\n3. 导入或新建工程 → 生成工程 → 编译 → 烧录。").font(.callout).lineSpacing(7) }
    }.padding(24).disabled(s.busy) } }
    func tool(_ name:String,_ key:WritableKeyPath<Settings,String>) -> some View { VStack(alignment:.leading,spacing:4) { HStack { Text(name).frame(width:85,alignment:.leading); TextField("尚未找到，请选择工具",text:Binding(get:{s.settings[keyPath:key]},set:{s.settings[keyPath:key] = $0})).textFieldStyle(.roundedBorder); Button("选择…") { s.choose(key,title:"选择 \(name) 可执行文件") } }; if let value = s.checks[name] { Text(value).font(.caption).foregroundStyle(value.hasPrefix("✓") ? .green : .red).padding(.leading,93).lineLimit(2) } } }
    var logView: some View { VStack(spacing:12) { HStack { Text("运行输出").font(.headline); Spacer(); Button("保存日志…") { s.exportLog() }; Button("清空") { s.log = "" }.disabled(s.busy) }; ScrollView([.vertical,.horizontal]) { Text(s.log).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading).padding(14) }.background(Color(nsColor:.textBackgroundColor)).clipShape(RoundedRectangle(cornerRadius:10)) }.padding(24) }
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
            Text("调整侧栏顺序").font(.title2.bold())
            Text("拖动项目改变左侧功能排列。保存后下次打开仍会保持。") .foregroundStyle(.secondary)
            List {
                ForEach(items) { item in Label(item.title,systemImage:item.icon) }
                    .onMove { items.move(fromOffsets:$0,toOffset:$1) }
            }.frame(width:360,height:300)
            HStack { Button("恢复默认") { items = navigationCatalog }; Spacer(); Button("取消") { dismiss() }; Button("保存顺序") { onSave(items.map(\.id)); dismiss() }.buttonStyle(.borderedProminent) }
        }.padding(22).frame(width:430,height:420)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var window: NSWindow?
    let studio = Studio()
    func applicationDidFinishLaunching(_ notification: Notification) {
        let menu = NSMenu(), item = NSMenuItem(), sub = NSMenu(); sub.addItem(withTitle:"关于 STM32 工程配置",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:""); sub.addItem(.separator()); sub.addItem(withTitle:"退出 STM32 工程配置",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"); item.submenu = sub; menu.addItem(item)
        let editItem = NSMenuItem(title:"编辑",action:nil,keyEquivalent:""), edit = NSMenu(title:"编辑"); for (name,selector,key) in [("剪切","cut:","x"),("复制","copy:","c"),("粘贴","paste:","v"),("全选","selectAll:","a")] { edit.addItem(withTitle:name,action:Selector(selector),keyEquivalent:key) }; editItem.submenu = edit; menu.addItem(editItem); NSApp.mainMenu = menu
        if let i = CommandLine.arguments.firstIndex(of:"--smoke-tab"), CommandLine.arguments.count > i+1 { studio.tab = Int(CommandLine.arguments[i+1]) ?? 0 }
        let w = NSWindow(contentRect:NSRect(x:0,y:0,width:1140,height:850),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        w.title = "WebCode · STM32 烧录软件 · 预览版"; w.minSize = NSSize(width:1040,height:760); w.contentView = NSHostingView(rootView:MainView(s:studio)); w.center(); w.makeKeyAndOrderFront(nil); window = w
        NSApp.activate(ignoringOtherApps:true)
        if let i = CommandLine.arguments.firstIndex(of:"--smoke-test"), CommandLine.arguments.count > i + 1 {
            let output = CommandLine.arguments[i+1]
            DispatchQueue.main.asyncAfter(deadline:.now() + 2) {
                let report = "windowVisible=\(w.isVisible)\nwindowTitle=\(w.title)\ncontentView=\(String(describing:type(of:w.contentView!)))\nsize=\(w.contentView!.bounds.size)\nprojects=\(self.studio.projects.count)\n"
                try? write(report,path(output,"launch-check.txt"))
                if let view = w.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:bitmap)
                    if let image = bitmap.representation(using:.png,properties:[:]) { try? image.write(to:URL(fileURLWithPath:path(output,"app-preview.png"))) }
                }
                NSApp.terminate(nil)
            }
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication)->Bool { true }
    func applicationShouldTerminate(_ sender:NSApplication)->NSApplication.TerminateReply { if studio.busy { let a = NSAlert(); a.messageText = "操作仍在进行"; a.informativeText = "请等待当前操作完成，或点击停止后再退出。"; a.runModal(); return .terminateCancel }; studio.debug.disconnect(); studio.save(); return .terminateNow }
}
