import Foundation
import SwiftUI
import AppKit

func miQuote(_ s:String) -> String { "\"" + s.replacingOccurrences(of:"\\",with:"\\\\").replacingOccurrences(of:"\"",with:"\\\"").replacingOccurrences(of:"\n",with:"\\n").replacingOccurrences(of:"\r",with:"\\r") + "\"" }
func miText(_ input:String) -> String {
    let bytes = Array(input.utf8); var result:[UInt8] = []; var i = bytes.first == 34 ? 1 : 0
    let end = bytes.last == 34 ? bytes.count - 1 : bytes.count
    while i < end {
        let b = bytes[i]; i += 1
        if b != 92 || i >= end { result.append(b); continue }
        let n = bytes[i]; i += 1
        switch n {
        case 110: result.append(10)
        case 114: result.append(13)
        case 116: result.append(9)
        case 48...55:
            var value = Int(n-48), count = 1
            while i < end && count < 3 && (48...55).contains(bytes[i]) { value = value * 8 + Int(bytes[i]-48); i += 1; count += 1 }
            result.append(UInt8(truncatingIfNeeded:value))
        default: result.append(n)
        }
    }
    return String(decoding:result,as:UTF8.self)
}

final class DebugSession: ObservableObject {
    struct WatchValue: Identifiable, Equatable {
        let id = UUID()
        let expression:String
        var value = "等待读取"
    }
    @Published var active = false
    @Published var connected = false
    @Published var running = false
    @Published var status = "未连接 · 选择带调试符号的 ELF 后连接"
    @Published var log = "调试使用 GDB + OpenOCD。连接后可暂停、单步和查看变量。\n"
    @Published var stack = "连接并暂停后显示 PC / 调用栈"
    @Published var frameInfo = "暂无当前栈帧"
    @Published var registers = "暂无寄存器"
    @Published var arguments = "暂无函数参数"
    @Published var locals = "暂无局部变量"
    @Published var allStackVariables = "暂无全栈变量"
    @Published var globalVariables = "尚未扫描全局 / 静态符号"
    @Published var watches:[WatchValue] = []
    @Published var breakpoints = "暂无断点"
    @Published var memory = "暂无内存数据"
    @Published var stackMemory = "暂无栈内存数据"
    @Published var registerOutput = ""
    @Published var source = ""
    @Published var sourceLine = 0
    @Published var busyCommand = false
    @Published var elfChanged = false
    private var elfFile = ""
    private var elfDate:Date?
    private var server:Process?, debugger:Process?, input:Pipe?
    private var serverPipe:Pipe?, debuggerPipe:Pipe?
    private var serverBuffer = "", debuggerBuffer = ""
    private var serverOutput = ""
    private var nextToken = 0
    private var current:Request?, requests:[Request] = []
    private var transcript = ""
    private var refreshing = false
    private var generation = UUID()
    private struct Request {
        let token:Int; let command:String; let completion:((Bool,String)->Void)?
    }
    func append(_ s:String) { log += s; if log.count > 180000 { log = String(log.suffix(150000)) } }
    func start(_ s:Settings) {
        guard !active else { return }
        guard fm.isExecutableFile(atPath:s.gdb) else { status = "未找到 arm-none-eabi-gdb，请在工具与固件包中选择"; return }
        let elf = s.debugELF.isEmpty ? s.firmware : s.debugELF
        guard exists(elf), elf.lowercased().hasSuffix(".elf") else { status = "调试需要 ELF 文件，HEX/BIN 不含所需符号信息"; return }
        do {
            let engine = Engine(runner:Runner(log:{_ in})); var args = try engine.hardwareArguments(s)
            args += ["-c","bindto 127.0.0.1","-c","gdb_port 3333","-c","tcl_port disabled","-c","telnet_port disabled"]
            elfFile = elf; elfDate = (try? fm.attributesOfItem(atPath:elf)[.modificationDate]) as? Date; elfChanged = false
            active = true; connected = false; running = false; status = "正在启动 OpenOCD…"; generation = UUID(); let session = generation
            serverBuffer = ""; debuggerBuffer = ""; serverOutput = ""
            let p = Process(), pipe = Pipe(); p.executableURL = URL(fileURLWithPath:s.openocd); p.arguments = args; p.environment = s.environment; p.standardOutput = pipe; p.standardError = pipe; p.standardInput = FileHandle.nullDevice
            server = p; serverPipe = pipe
            pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData; if data.isEmpty { handle.readabilityHandler = nil; return }
                let chunk = String(decoding:data,as:UTF8.self)
                DispatchQueue.main.async {
                    guard let self, self.generation == session else { return }; self.append("[OpenOCD] " + chunk); self.serverOutput += chunk
                    if self.serverOutput.contains("Listening on port 3333 for gdb connections"), self.debugger == nil { self.launchGDB(s,session) }
                }
            }
            p.terminationHandler = { [weak self] proc in DispatchQueue.main.async { guard let self, self.generation == session, self.active else { return }; self.fail("OpenOCD 已退出（\(proc.terminationStatus)）。检查探针、芯片目标或 3333 端口占用。") } }
            try p.run()
            DispatchQueue.main.asyncAfter(deadline:.now() + 20) { [weak self] in guard let self, self.generation == session, self.active, !self.connected else { return }; self.fail("连接超时，请检查探针和 OpenOCD 日志。") }
        } catch { fail(error.localizedDescription) }
    }
    private func launchGDB(_ s:Settings,_ session:UUID) {
        let p = Process(), output = Pipe(), input = Pipe(); p.executableURL = URL(fileURLWithPath:s.gdb); p.arguments = ["--nx","--quiet","--interpreter=mi2"]; p.environment = s.environment; p.standardInput = input; p.standardOutput = output; p.standardError = output
        self.input = input; debugger = p; debuggerPipe = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData; if data.isEmpty { handle.readabilityHandler = nil; return }
            let chunk = String(decoding:data,as:UTF8.self)
            DispatchQueue.main.async {
                guard let self, self.generation == session else { return }
                self.debuggerBuffer += chunk
                while let end = self.debuggerBuffer.firstIndex(of:"\n") { let line = String(self.debuggerBuffer[..<end]); self.debuggerBuffer.removeSubrange(...end); self.consume(line) }
            }
        }
        p.terminationHandler = { [weak self] proc in DispatchQueue.main.async { guard let self, self.generation == session, self.active else { return }; self.fail("GDB 已退出（\(proc.terminationStatus)）。") } }
        do {
            try p.run(); status = "正在连接 GDB…"
            send("-gdb-set mi-async on") { ok,_ in if !ok { self.fail("GDB 不支持异步调试") } }
            send("-gdb-set pagination off")
            send("-file-exec-and-symbols " + miQuote(s.debugELF.isEmpty ? s.firmware : s.debugELF)) { ok,result in if !ok { self.fail("ELF 加载失败：" + result) } }
            send("-target-select remote localhost:3333") { ok,result in
                if ok { self.connected = true; self.status = "已连接 · " + s.chipModel; self.console("monitor halt") { _,_ in self.running = false; self.refresh() } }
                else { self.fail("连接目标失败：" + result) }
            }
        } catch { fail(error.localizedDescription) }
    }
    func send(_ command:String,completion:((Bool,String)->Void)? = nil) {
        guard active, debugger?.isRunning == true else { completion?(false,"GDB 未连接"); return }
        nextToken += 1; requests.append(Request(token:nextToken,command:command,completion:completion)); pump()
    }
    private func pump() {
        guard current == nil, !requests.isEmpty else { return }
        let r = requests.removeFirst(); current = r; busyCommand = true; transcript = ""
        append("› " + r.command + "\n")
        do { try input?.fileHandleForWriting.write(contentsOf:Data("\(r.token)\(r.command)\n".utf8)) }
        catch { fail("无法发送 GDB 命令：" + error.localizedDescription) }
    }
    func consume(_ line:String) {
        if line.hasPrefix("~") || line.hasPrefix("@") || line.hasPrefix("&") {
            let text = miText(String(line.dropFirst())); transcript += text; append(text); return
        }
        if line.hasPrefix("*running") { running = true; status = "目标正在运行" }
        if line.hasPrefix("*stopped") {
            running = false; status = "目标已暂停"; append(line + "\n")
            if let regex = try? NSRegularExpression(pattern:"fullname=\"((?:\\\\.|[^\"])*)\""), let match = regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)), let range = Range(match.range(at:1),in:line) { source = miText("\"" + line[range] + "\"") }
            if let regex = try? NSRegularExpression(pattern:"(?:,|\\{)line=\"(\\d+)\""), let match = regex.firstMatch(in:line,range:NSRange(line.startIndex...,in:line)), let range = Range(match.range(at:1),in:line) { sourceLine = Int(line[range]) ?? 0 }
            if connected { refresh() }
        }
        guard let r = current, line.hasPrefix("\(r.token)^") else { if !line.isEmpty && line != "(gdb) " { append(line + "\n") }; return }
        let result = String(line.dropFirst(String(r.token).count+1)), ok = !result.hasPrefix("error")
        append(result + "\n")
        let combined = transcript.isEmpty ? result : transcript
        current = nil; busyCommand = false
        if !ok { status = "调试命令失败，查看下方日志" }
        r.completion?(ok,combined)
        pump()
    }
    func console(_ command:String,completion:((Bool,String)->Void)? = nil) { send("-interpreter-exec console " + miQuote(command),completion:completion) }
    func refresh() {
        guard connected, !running, !refreshing else { return }; refreshing = true
        console("bt") { _,text in self.stack = text }
        console("info frame") { _,text in self.frameInfo = text }
        console("info registers") { _,text in self.registers = text }
        console("info args") { _,text in self.arguments = text }
        console("info locals") { _,text in self.locals = text }
        console("bt full") { _,text in self.allStackVariables = text }
        console("x/64wx $sp") { _,text in self.stackMemory = text }
        refreshWatches()
        console("info breakpoints") { _,text in self.breakpoints = text; self.refreshing = false }
    }
    func resume() { guard connected,!running else{return}; send("-exec-continue") }
    func pause() { guard connected,running else{return}; send("-exec-interrupt --all") }
    func step(_ into:Bool) { guard connected,!running else{return}; send(into ? "-exec-step" : "-exec-next") }
    func instruction() { guard connected,!running else{return}; send("-exec-step-instruction") }
    func reset() { guard connected,!running else{return}; console("monitor reset halt") { ok,_ in if ok { self.running = false; self.refresh() } } }
    func startAtMain() {
        guard connected,!running else{return}
        console("monitor reset halt") { ok,_ in
            guard ok else{return}
            self.send("-break-insert -t main") { ok,_ in if ok { self.send("-exec-continue") } }
        }
    }
    func checkELF() {
        guard active else{return}
        let date = (try? fm.attributesOfItem(atPath:elfFile)[.modificationDate]) as? Date
        elfChanged = date != elfDate
    }
    func download() {
        guard connected,!running else{return}
        send("-file-exec-and-symbols " + miQuote(elfFile)) { ok,_ in
            guard ok else{return}
            self.send("-target-download") { ok,_ in if ok { self.elfDate = (try? fm.attributesOfItem(atPath:self.elfFile)[.modificationDate]) as? Date; self.elfChanged = false; self.reset() } }
        }
    }
    func addBreakpoint(_ location:String) {
        guard connected,!running,!location.trimmingCharacters(in:.whitespaces).isEmpty else{return}
        send("-break-insert " + miQuote(location)) { _,_ in self.refresh() }
    }
    func removeBreakpoint(_ number:String) {
        guard number.range(of:"^[0-9]+$",options:.regularExpression) != nil else { status = "请输入断点编号，例如 1"; return }
        send("-break-delete " + number) { _,_ in self.refresh() }
    }
    func selectFrame(_ number:String) {
        guard connected,!running, number.range(of:"^[0-9]+$",options:.regularExpression) != nil else { status = "栈帧编号应为非负整数，例如 0"; return }
        console("frame " + number) { ok,_ in if ok { self.refresh() } }
    }
    func addWatch(_ expression:String) {
        let value = expression.trimmingCharacters(in:.whitespacesAndNewlines)
        guard connected,!running,!value.isEmpty else { return }
        guard !watches.contains(where: { $0.expression == value }) else { status = "该表达式已在监视列表中"; return }
        watches.append(WatchValue(expression:value)); refreshWatches()
    }
    func removeWatch(_ id:UUID) { watches.removeAll { $0.id == id } }
    func refreshWatches() {
        for watch in watches {
            console("print /x " + watch.expression) { ok,text in
                guard let index = self.watches.firstIndex(where: { $0.id == watch.id }) else { return }
                self.watches[index].value = ok ? text.trimmingCharacters(in:.whitespacesAndNewlines) : "读取失败：" + text.trimmingCharacters(in:.whitespacesAndNewlines)
            }
        }
    }
    func scanGlobalVariables() {
        guard connected,!running else { return }
        console("info variables") { _,text in self.globalVariables = text }
    }
    func readMemory(_ address:String,_ words:String,_ format:String = "w") {
        guard connected,!running else{return}
        guard address.range(of:"^0x[0-9a-fA-F]{1,8}$",options:.regularExpression) != nil, let count = Int(words), (1...256).contains(count) else { status = "内存地址需为十六进制，长度为 1–256 个 32 位字"; return }
        console("x/\(count)\(format)x \(address)") { _,text in self.memory = text }
    }
    func readRegister(_ register: RegisterDefinition) {
        guard connected, !running else { return }
        console("x/wx \(register.address)") { _, text in self.registerOutput = "\(register.name) @ \(register.address)\n\(text)" }
    }
    private func fail(_ message:String) { disconnect(); status = message; append("✕ " + message + "\n") }
    func disconnect() {
        generation = UUID(); active = false; connected = false; running = false; busyCommand = false; refreshing = false
        requests.removeAll(); current = nil
        debuggerPipe?.fileHandleForReading.readabilityHandler = nil; serverPipe?.fileHandleForReading.readabilityHandler = nil
        if let p = debugger, p.isRunning { try? input?.fileHandleForWriting.write(contentsOf:Data("-gdb-exit\n".utf8)); p.terminate() }
        if let p = server, p.isRunning { p.terminate() }
        debugger = nil; server = nil; input = nil; debuggerPipe = nil; serverPipe = nil; status = "已断开调试连接"; append("调试连接已关闭。\n")
    }
    func exportLog() { let panel = NSSavePanel(); panel.nameFieldStringValue = "STM32调试日志.txt"; if panel.runModal() == .OK, let url = panel.url { try? log.write(to:url,atomically:true,encoding:.utf8) } }
}

struct DebugView: View {
    @ObservedObject var studio:Studio
    @ObservedObject var debug:DebugSession
    @State private var breakpoint = "main"
    @State private var deleteNumber = ""
    @State private var address = "0x20000000"
    @State private var words = "16"
    @State private var memoryUnit = "32位"
    @State private var command = "info locals"
    @State private var panel = "调用栈"
    @State private var variableScope = "当前帧"
    @State private var frameNumber = "0"
    @State private var watchExpression = ""
    @State private var downloadConfirm = false
    private var stepItems: [(String, String, Bool)] {
        let hasELF = !studio.settings.debugELF.isEmpty && FileManager.default.fileExists(atPath: studio.settings.debugELF)
        return [
            ("1", "准备带调试符号的 ELF", hasELF),
            ("2", "选择 ST-Link / CMSIS-DAP 和 target 配置", !studio.settings.probe.isEmpty && !studio.settings.target.isEmpty),
            ("3", "点击“连接调试”", debug.connected),
            ("4", "暂停目标后查看调用栈、寄存器、变量或内存", debug.connected && !debug.running),
            ("5", "修改代码后重新编译，并重新载入最新 ELF", hasELF && !debug.elfChanged)
        ]
    }
    var body:some View { ScrollView { VStack(spacing:16) {
        Card(title:"调试步骤",icon:"list.number") {
            VStack(alignment:.leading,spacing:9) {
                ForEach(stepItems,id:\.0) { number, title, done in
                    HStack(spacing:10) {
                        Image(systemName:done ? "checkmark.circle.fill" : "circle").foregroundStyle(done ? .green : .secondary)
                        Text(number).font(.caption.monospacedDigit()).frame(width:18)
                        Text(title).foregroundStyle(done ? .primary : .secondary)
                        Spacer()
                    }
                }
                Text("调试连接只暂停和读取目标，不会自动擦除或烧录。要把新 ELF 写入芯片，请先断开调试，再回到烧录页执行“烧录并校验”。").font(.caption).foregroundStyle(.secondary)
            }
        }
        Card(title:"调试连接",icon:"ant") {
            HStack { Label(studio.settings.chipModel,systemImage:"cpu"); Spacer(); Picker("探针",selection:$studio.settings.probe) { Text("ST-Link").tag("ST-Link"); Text("CMSIS-DAP").tag("CMSIS-DAP") }.frame(width:220).disabled(debug.active) }
            HStack { Text("ELF").frame(width:45); TextField("选择带调试符号的 ELF",text:$studio.settings.debugELF).disabled(debug.active); Button("选择…") { studio.choose(\.debugELF,title:"选择用于调试的 ELF") }.disabled(debug.active) }
            HStack { Text("目标").frame(width:45); TextField("target/stm32f1x.cfg",text:$studio.settings.target).disabled(debug.active); Button("选择…") { studio.choose(\.target,title:"选择调试目标配置") }.disabled(debug.active) }
            HStack { Button(debug.active ? "断开" : "连接调试") { if debug.active { debug.disconnect() } else { studio.save(); debug.start(studio.settings) } }.buttonStyle(.borderedProminent); Label(debug.status,systemImage:debug.connected ? "circle.fill" : "circle").font(.callout).foregroundStyle(debug.connected ? .green : .secondary); Spacer(); Button("保存调试日志…") { debug.exportLog() } }
            if debug.elfChanged { Label("ELF 已被重新编译。请下载更新后的 ELF 或重新连接，避免符号与芯片程序不一致。",systemImage:"exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
            Text("连接时暂停目标，不自动改写 Flash。请确保 ELF 与芯片程序一致；有 Debug 符号才可查看源码行和局部变量。F103/G4 使用同一免费调试链路，COM 无需选择。").font(.caption).foregroundStyle(.secondary)
        }.textFieldStyle(.roundedBorder)
        Card(title:"执行控制",icon:"playpause") {
            HStack { Button("从入口启动") { debug.startAtMain() }.disabled(!debug.connected || debug.running); Button("暂停") { debug.pause() }.disabled(!debug.running); Button("继续") { debug.resume() }.disabled(!debug.connected || debug.running); Button("单步跳过") { debug.step(false) }.disabled(!debug.connected || debug.running); Button("单步进入") { debug.step(true) }.disabled(!debug.connected || debug.running); Button("指令单步") { debug.instruction() }.disabled(!debug.connected || debug.running) }
            HStack { Button("复位并暂停") { debug.reset() }.disabled(!debug.connected || debug.running); Button("下载 ELF 到芯片…") { downloadConfirm = true }.disabled(!debug.connected || debug.running); Spacer(); Button("刷新状态") { debug.refresh() }.disabled(!debug.connected || debug.running) }
            if !debug.source.isEmpty { HStack { Text("\(debug.source):\(debug.sourceLine)").font(.caption).textSelection(.enabled); Spacer(); Button("打开源码") { NSWorkspace.shared.open(URL(fileURLWithPath:debug.source)) } } }
        }
        Card(title:"断点",icon:"stop.circle") {
            HStack { TextField("函数名或 file.c:行号",text:$breakpoint); Button("添加") { debug.addBreakpoint(breakpoint) }; TextField("编号",text:$deleteNumber).frame(width:65); Button("删除") { debug.removeBreakpoint(deleteNumber) } }.textFieldStyle(.roundedBorder).disabled(!debug.connected || debug.running)
            Text(debug.breakpoints).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
        }
        Card(title:"目标状态",icon:"list.bullet.rectangle") {
            Picker("查看",selection:$panel) { Text("调用栈").tag("调用栈"); Text("寄存器 / PC").tag("寄存器"); Text("变量").tag("变量"); Text("监视").tag("监视"); Text("内存").tag("内存") }.pickerStyle(.segmented)
            if panel == "调用栈" {
                HStack { TextField("栈帧",text:$frameNumber).frame(width:80); Button("切换栈帧") { debug.selectFrame(frameNumber) }; Text("0 是当前停下的位置；切换后变量会随该帧刷新。").font(.caption).foregroundStyle(.secondary); Spacer() }.textFieldStyle(.roundedBorder).disabled(!debug.connected || debug.running)
                ScrollView([.vertical,.horizontal]) { VStack(alignment:.leading,spacing:10) { Text(debug.frameInfo).font(.system(size:11,design:.monospaced)); Divider(); Text(debug.stack).font(.system(size:12,design:.monospaced)) }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(height:190)
            } else if panel == "寄存器" {
                Text("暂停时读取通用寄存器与 PC、SP、LR、xPSR。外设寄存器请到“寄存器助手”按地址读取。").font(.caption).foregroundStyle(.secondary)
                ScrollView([.vertical,.horizontal]) { Text(debug.registers).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(height:170)
            } else if panel == "变量" {
                Picker("范围",selection:$variableScope) { Text("当前帧").tag("当前帧"); Text("所有栈帧").tag("所有栈帧"); Text("全局符号").tag("全局符号") }.pickerStyle(.segmented)
                if variableScope == "当前帧" {
                    ScrollView([.vertical,.horizontal]) { VStack(alignment:.leading,spacing:10) { Text("当前栈帧的函数参数").font(.caption).foregroundStyle(.secondary); Text(debug.arguments).font(.system(size:12,design:.monospaced)); Divider(); Text("当前栈帧的局部变量").font(.caption).foregroundStyle(.secondary); Text(debug.locals).font(.system(size:12,design:.monospaced)) }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(height:170)
                } else if variableScope == "所有栈帧" {
                    Text("GDB 的 bt full 输出：每个正在调用的函数及其可用局部变量。").font(.caption).foregroundStyle(.secondary)
                    ScrollView([.vertical,.horizontal]) { Text(debug.allStackVariables).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(height:150)
                } else {
                    HStack { Text("列出 ELF 中可见的全局与静态符号；选择一个名称后加入“监视”可查看它的实时值。").font(.caption).foregroundStyle(.secondary); Spacer(); Button("扫描") { debug.scanGlobalVariables() }.disabled(!debug.connected || debug.running) }
                    ScrollView([.vertical,.horizontal]) { Text(debug.globalVariables).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(height:150)
                }
            } else if panel == "监视" {
                HStack { TextField("变量或表达式，例如 counter、buffer[0]、&handle",text:$watchExpression).onSubmit { debug.addWatch(watchExpression); watchExpression = "" }; Button("添加") { debug.addWatch(watchExpression); watchExpression = "" } }.textFieldStyle(.roundedBorder).disabled(!debug.connected || debug.running)
                ScrollView { VStack(alignment:.leading,spacing:6) { if debug.watches.isEmpty { Text("添加后会在每次暂停、单步或点击“刷新状态”时重新读取。可监视全局变量、结构体成员、数组元素和地址表达式。").font(.caption).foregroundStyle(.secondary) }; ForEach(debug.watches) { watch in HStack(alignment:.top) { Text(watch.expression).font(.system(size:12,design:.monospaced)).frame(width:220,alignment:.leading); Text(watch.value).font(.system(size:12,design:.monospaced)).textSelection(.enabled); Spacer(); Button(role:.destructive) { debug.removeWatch(watch.id) } label: { Image(systemName:"trash") }.buttonStyle(.borderless) } } }.frame(maxWidth:.infinity,alignment:.leading) }.frame(height:160)
            } else {
                HStack { TextField("地址",text:$address); Picker("单位",selection:$memoryUnit) { Text("字节").tag("字节"); Text("半字").tag("半字"); Text("32位").tag("32位") }.frame(width:130); TextField("数量",text:$words).frame(width:65); Button("读取") { debug.readMemory(address,words,memoryUnit == "字节" ? "b" : memoryUnit == "半字" ? "h" : "w") }; Button("读取当前栈") { debug.refresh() } }.textFieldStyle(.roundedBorder).disabled(!debug.connected || debug.running)
                Text("从任意有效地址读取。常见区域：SRAM 0x20000000，Flash 0x08000000；外设地址请以当前芯片参考手册或 SVD 为准。").font(.caption).foregroundStyle(.secondary)
                ScrollView([.vertical,.horizontal]) { VStack(alignment:.leading,spacing:10) { Text("指定地址").font(.caption).foregroundStyle(.secondary); Text(debug.memory).font(.system(size:12,design:.monospaced)); Divider(); Text("当前栈：从 $sp 开始的 64 个 32 位字").font(.caption).foregroundStyle(.secondary); Text(debug.stackMemory).font(.system(size:12,design:.monospaced)) }.textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(height:170)
            }
        }
        Card(title:"GDB 输出与调试日志",icon:"terminal") {
            HStack { TextField("GDB 命令，例如 print counter",text:$command).textFieldStyle(.roundedBorder).onSubmit { debug.console(command) }; Button("执行") { debug.console(command) } }.disabled(!debug.connected || debug.running)
            ScrollView([.vertical,.horizontal]) { Text(debug.log).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading) }.frame(height:170)
        }
    }.padding(24) }.alert("下载 ELF 到芯片？",isPresented:$downloadConfirm) { Button("取消",role:.cancel) {}; Button("下载") { debug.download() } } message: { Text("将用当前 ELF 改写 Flash。请确认固件与 \(studio.settings.chipModel) 匹配。") } }
}
