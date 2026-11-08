import Foundation
import Darwin

struct StudioError: LocalizedError { let message: String; var errorDescription: String? { message }; init(_ s: String) { message = s } }
let fm = FileManager.default
func path(_ root: String, _ tail: String) -> String { URL(fileURLWithPath: root).appendingPathComponent(tail).path }
func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }
func canonical(_ p: String) -> String { URL(fileURLWithPath: (p as NSString).expandingTildeInPath).resolvingSymlinksInPath().standardizedFileURL.path }
func children(_ p: String) -> [String] { (try? fm.contentsOfDirectory(atPath: p)) ?? [] }
func write(_ s: String, _ p: String) throws { try s.write(toFile: p, atomically: true, encoding: .utf8) }
func read(_ p: String) -> String { (try? String(contentsOfFile: p, encoding: .utf8)) ?? "" }
func quoted(_ s: String) throws -> String {
    guard !s.contains("\n"), !s.contains("\r"), !s.contains("\""), !s.contains("\\") else { throw StudioError("路径含 CubeMX 不支持的引号、换行或反斜杠：\(s)") }
    return "\"\(s)\""
}
func shellWord(_ s: String) -> String { "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
func tclWord(_ s: String) -> String { "\"" + s.reduce("") { $0 + ("\\\"$[]".contains($1) ? "\\" : "") + String($1) } + "\"" }

struct SeriesCatalog {
    static let groups = ["Cseries", "Fseries", "Gseries", "Hseries", "Lseries", "Nseries", "Useries", "Wseries", "MPseries"]
    static let details = ["Cseries":"C0 / C5", "Fseries":"F0 / F1 / F2 / F3 / F4 / F7", "Gseries":"G0 / G4 / G5", "Hseries":"H5 / H7 / H7RS / H7P", "Lseries":"L0 / L1 / L4 / L4+ / L5", "Nseries":"N6", "Useries":"U0 / U3 / U5", "Wseries":"WB / WB0 / WBA / WL / WL3 / WL4", "MPseries":"MP1 / MP2"]
    static let examples = ["Cseries":"STM32C031C6Tx", "Fseries":"STM32F103C8Tx", "Gseries":"STM32G431RBTx", "Hseries":"STM32H743ZITx", "Lseries":"STM32L476RGTx", "Nseries":"STM32N657X0HxQ", "Useries":"STM32U575ZITx", "Wseries":"STM32WB55RGVx", "MPseries":"STM32MP157CAAx"]
    static func prefix(_ group: String) -> String { "STM32" + group.replacingOccurrences(of:"series",with:"") }
    static func group(_ family: String) -> String? { groups.first { family.hasPrefix(prefix($0)) } }
    static func accepts(_ chip:String,_ group:String) -> Bool { groups.contains(group) && chip.range(of:"^STM32[A-Z][A-Za-z0-9]+$",options:.regularExpression) != nil && chip.hasPrefix(prefix(group)) }
    static func installedFamilies(_ cube:String) -> [String] {
        guard !cube.isEmpty else { return [] }
        let base = URL(fileURLWithPath:cube).deletingLastPathComponent().path
        let xml = [path(base,"db/mcu/families.xml"),path(base,"../Resources/db/mcu/families.xml")].map(read).joined()
        guard let regex = try? NSRegularExpression(pattern:"<Family Name=\"([^\"]+)\"") else { return [] }
        let ns = xml as NSString
        return regex.matches(in:xml,range:NSRange(location:0,length:ns.length)).map{ns.substring(with:$0.range(at:1))}.sorted()
    }
}

struct Settings: Codable {
    var root = ""
    var series = ""
    var project = ""
    var cube = ""
    var cmake = ""
    var compiler = ""
    var gdb = ""
    var hostGCC = "/usr/bin/gcc"
    var ninja = ""
    var openocd = ""
    var target = ""
    var probe = "ST-Link"
    var configuration = "Debug"
    var firmware = ""
    var speed = "1000"
    var toolchain = ""
    var repository = NSHomeDirectory() + "/STM32Cube/Repository"
    var chipFamily = ""
    var chipModel = ""
    var pack = ""
    var binaryAddress = "0x08000000"
    var serialPort = ""
    var debugELF = ""
    var outputDirectory = ""
    var followBuildOutputs = true
    var expectedFirmwareHash = ""
    var navigationOrder = [0, 4, 5, 6, 1, 2, 3]
    var programmerBackend = "OpenOCD"
    var cubeProgrammer = ""
    var programmerTransport = "SWD"
    var connectionMode = "Normal"
    var probeSerial = ""
    var dfuPort = "USB1"
    var baudRate = "115200"
    var backupAddress = "0x08000000"
    var backupLength = "65536"
    static func load(_ file:String) -> Settings {
        guard let data = try? Data(contentsOf:URL(fileURLWithPath:file)), let saved = try? JSONSerialization.jsonObject(with:data) as? [String:Any], let defaults = try? JSONEncoder().encode(Settings()), var values = try? JSONSerialization.jsonObject(with:defaults) as? [String:Any] else { return Settings() }
        values.merge(saved) { _,new in new }
        guard let merged = try? JSONSerialization.data(withJSONObject:values), let settings = try? JSONDecoder().decode(Settings.self,from:merged) else { return Settings() }
        return settings
    }
    var build: String {
        if !outputDirectory.isEmpty { return outputDirectory }
        guard !project.isEmpty else { return "" }
        return path(project, "build/STM32Studio-\(configuration)")
    }
    var environment: [String:String] {
        var env = ProcessInfo.processInfo.environment
        let dirs = [compiler, cmake, ninja, openocd].filter{ !$0.isEmpty }.map { URL(fileURLWithPath:$0).deletingLastPathComponent().path }
        env["PATH"] = (dirs + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
        env["LC_ALL"] = "en_US.UTF-8"
        return env
    }
    mutating func discover() {
        func first(_ p: [String]) -> String { p.first { fm.isExecutableFile(atPath: $0) } ?? "" }
        if !cmake.isEmpty && !fm.isExecutableFile(atPath: cmake) { cmake = "" }
        if !ninja.isEmpty && !fm.isExecutableFile(atPath: ninja) { ninja = "" }
        if !openocd.isEmpty && !fm.isExecutableFile(atPath: openocd) { openocd = "" }
        if !compiler.isEmpty && !fm.isExecutableFile(atPath: compiler) { compiler = "" }
        if !gdb.isEmpty && !fm.isExecutableFile(atPath: gdb) { gdb = "" }
        if !cube.isEmpty && !fm.isExecutableFile(atPath: cube) { cube = "" }
        if cmake.isEmpty { cmake = first(["/opt/homebrew/bin/cmake", "/usr/local/bin/cmake", "/Applications/CMake.app/Contents/bin/cmake"]) }
        if ninja.isEmpty { ninja = first(["/opt/homebrew/bin/ninja", "/usr/local/bin/ninja"]) }
        if openocd.isEmpty { openocd = first(["/opt/homebrew/bin/openocd", "/usr/local/bin/openocd"]) }
        if !cubeProgrammer.isEmpty && !fm.isExecutableFile(atPath:cubeProgrammer) { cubeProgrammer = "" }
        if cubeProgrammer.isEmpty {
            let relative = "STMicroelectronics/STM32Cube/STM32CubeProgrammer/STM32CubeProgrammer.app/Contents/MacOs/bin/STM32_Programmer_CLI"
            cubeProgrammer = first([path("/Applications",relative), path(NSHomeDirectory() + "/Applications",relative),
                "/Applications/STM32CubeProgrammer.app/Contents/MacOs/bin/STM32_Programmer_CLI",
                "/Applications/STMicroelectronics/STM32Cube/STM32CubeProgrammer/bin/STM32_Programmer_CLI"])
        }
        if compiler.isEmpty {
            let base = NSHomeDirectory() + "/Tools/arm-gnu"
            compiler = first(children(base).sorted().reversed().map{path(base, $0 + "/bin/arm-none-eabi-gcc")} + ["/opt/homebrew/bin/arm-none-eabi-gcc", "/usr/local/bin/arm-none-eabi-gcc"])
        }
        if gdb.isEmpty { gdb = first([path(URL(fileURLWithPath:compiler).deletingLastPathComponent().path,"arm-none-eabi-gdb"),"/opt/homebrew/bin/arm-none-eabi-gdb","/usr/local/bin/arm-none-eabi-gdb"]) }
        if cube.isEmpty || !fm.isExecutableFile(atPath:cube) {
            let home = NSHomeDirectory()
            let folders = [home + "/Downloads", home + "/Desktop"]
            let extractedInstallations = folders.flatMap { folder in
                children(folder).filter { $0.hasPrefix("STM32CubeMX") }.sorted().reversed().map { item in
                    path(folder, item + "/MX/STM32CubeMX")
                }
            }
            cube = first([
                "/Applications/STM32CubeMX.app/Contents/MacOS/STM32CubeMX",
                "/Applications/STMicroelectronics/STM32CubeMX.app/Contents/MacOS/STM32CubeMX"
            ] + extractedInstallations)
        }
    }
}

struct Engine {
    let runner: Runner
    private func requireProject(_ project: String) throws {
        guard !project.isEmpty else { throw StudioError("请先选择工程。") }
    }
    func ioc(_ project: String) throws -> String {
        try requireProject(project)
        let files = children(project).filter{$0.lowercased().hasSuffix(".ioc")}
        guard files.count == 1 else { throw StudioError(files.isEmpty ? "工程中没有 .ioc 文件。请导入 CubeMX 工程，或先用 CubeMX 保存芯片配置。" : "工程内有多个 .ioc 文件，请保留当前使用的一份配置。") }
        return path(project, files[0])
    }
    func family(_ p: String) -> String {
        guard let f = try? ioc(p) else { return "" }
        return read(f).components(separatedBy: .newlines).first{$0.hasPrefix("Mcu.Family=")}?.components(separatedBy:"=").last ?? ""
    }
    func targetFor(_ family: String, model:String = "") -> String? {
        if model.hasPrefix("STM32H7R") || model.hasPrefix("STM32H7S") || model.hasPrefix("STM32H7P") { return nil }
        let map = ["STM32F0":"stm32f0x", "STM32F1":"stm32f1x", "STM32F2":"stm32f2x", "STM32F3":"stm32f3x", "STM32F4":"stm32f4x", "STM32F7":"stm32f7x", "STM32G0":"stm32g0x", "STM32G4":"stm32g4x", "STM32H5":"stm32h5x", "STM32H7":"stm32h7x", "STM32L0":"stm32l0", "STM32L1":"stm32l1", "STM32L4":"stm32l4x", "STM32L4+":"stm32l4x", "STM32L5":"stm32l5x", "STM32U5":"stm32u5x", "STM32WB":"stm32wbx", "STM32WL":"stm32wlx", "STM32C0":"stm32c0x", "STM32U0":"stm32u0x"]
        return map[family].map { "target/\($0).cfg" }
    }
    func openocdFile(_ name:String,_ s:Settings) -> String? {
        guard !name.isEmpty else { return nil }
        if name.hasPrefix("/") { return exists(name) ? name : nil }
        let executable = URL(fileURLWithPath:canonical(s.openocd)).deletingLastPathComponent().deletingLastPathComponent().path
        let roots = [ProcessInfo.processInfo.environment["OPENOCD_SCRIPTS"] ?? "",path(executable,"share/openocd/scripts"),"/opt/homebrew/share/openocd/scripts","/usr/local/share/openocd/scripts"].filter{!$0.isEmpty}
        return roots.map{path($0,name)}.first{exists($0)}
    }
    func validateSeries(_ s: Settings) throws {
        guard SeriesCatalog.groups.contains(s.series) else { throw StudioError("系列无效。") }
        let f = family(s.project)
        if !f.isEmpty && !f.hasPrefix(SeriesCatalog.prefix(s.series)) { throw StudioError("芯片 \(f) 与选择的 \(s.series) 不一致，请切换系列。") }
    }
    func normalizeToolchain(_ project: String) throws {
        try requireProject(project)
        let file = path(project,"cmake/gcc-arm-none-eabi.cmake")
        guard exists(file) else { return }
        var text = read(file)
        let replacements = [
            ("set(CMAKE_C_COMPILER                ${TOOLCHAIN_PREFIX}gcc)", "if(NOT CMAKE_C_COMPILER)\n    set(CMAKE_C_COMPILER ${TOOLCHAIN_PREFIX}gcc)\nendif()"),
            ("set(CMAKE_ASM_COMPILER              ${CMAKE_C_COMPILER})", "if(NOT CMAKE_ASM_COMPILER)\n    set(CMAKE_ASM_COMPILER ${CMAKE_C_COMPILER})\nendif()"),
            ("set(CMAKE_CXX_COMPILER              ${TOOLCHAIN_PREFIX}g++)", "if(NOT CMAKE_CXX_COMPILER)\n    set(CMAKE_CXX_COMPILER ${TOOLCHAIN_PREFIX}g++)\nendif()"),
            ("set(CMAKE_LINKER                    ${TOOLCHAIN_PREFIX}g++)", "if(NOT CMAKE_LINKER)\n    set(CMAKE_LINKER ${TOOLCHAIN_PREFIX}g++)\nendif()"),
            ("set(CMAKE_OBJCOPY                   ${TOOLCHAIN_PREFIX}objcopy)", "if(NOT CMAKE_OBJCOPY)\n    set(CMAKE_OBJCOPY ${TOOLCHAIN_PREFIX}objcopy)\nendif()"),
            ("set(CMAKE_SIZE                      ${TOOLCHAIN_PREFIX}size)", "if(NOT CMAKE_SIZE)\n    set(CMAKE_SIZE ${TOOLCHAIN_PREFIX}size)\nendif()")
        ]
        for (old, new) in replacements { text = text.replacingOccurrences(of: old, with: new) }
        try write(text,file)
    }
    func syncFirmwarePackage(_ file: String, _ folder: String) throws {
        let base = URL(fileURLWithPath: folder).lastPathComponent
        let display = base.replacingOccurrences(of: "STM32Cube_FW_", with: "STM32Cube FW_")
        var lines = read(file).components(separatedBy: .newlines)
        var firmwareFound = false
        var customFound = false
        var underRootFound = false
        var toolchainLocationFound = false
        for index in lines.indices {
            if lines[index].hasPrefix("ProjectManager.FirmwarePackage=") {
                lines[index] = "ProjectManager.FirmwarePackage=\(display)"
                firmwareFound = true
            }
            if lines[index].hasPrefix("ProjectManager.CustomerFirmwarePackage=") {
                lines[index] = "ProjectManager.CustomerFirmwarePackage=\(folder)"
                customFound = true
            }
            if lines[index].hasPrefix("ProjectManager.UnderRoot=") {
                lines[index] = "ProjectManager.UnderRoot=true"
                underRootFound = true
            }
            if lines[index].hasPrefix("ProjectManager.ToolChainLocation=") {
                lines[index] = "ProjectManager.ToolChainLocation="
                toolchainLocationFound = true
            }
        }
        if !firmwareFound { lines.append("ProjectManager.FirmwarePackage=\(display)") }
        if !customFound { lines.append("ProjectManager.CustomerFirmwarePackage=\(folder)") }
        if !underRootFound { lines.append("ProjectManager.UnderRoot=true") }
        if !toolchainLocationFound { lines.append("ProjectManager.ToolChainLocation=") }
        try write(lines.joined(separator: "\n"), file)
        runner.log("已同步固件包配置：\(display)\n")
    }
    func backup(_ p: String) throws {
        try requireProject(p)
        let dest = path(p, ".stm32studio/backups/" + UUID().uuidString)
        try fm.createDirectory(atPath: dest, withIntermediateDirectories: true)
        for name in children(p) where ![".stm32studio", "build", ".git"].contains(name) { try fm.copyItem(atPath:path(p,name),toPath:path(dest,name)) }
        runner.log("已备份现有工程：\(dest)\n")
    }
    func create(root: String, series: String, name: String) throws -> String {
        guard !root.isEmpty, exists(root) else { throw StudioError("请先选择已存在的 STM32 总目录。") }
        guard SeriesCatalog.groups.contains(series), name.range(of:"^[A-Za-z][A-Za-z0-9_-]{0,63}$",options:.regularExpression) != nil else { throw StudioError("工程名请使用英文字母开头的字母、数字、下划线或短横线，最长 64 位。") }
        let dest = path(root, series + "/" + name)
        guard !exists(dest) else { throw StudioError("同名工程已存在，不会覆盖：\(dest)") }
        try fm.createDirectory(atPath:dest,withIntermediateDirectories:true); return dest
    }
    func importProject(_ source: String, _ s: Settings) throws -> String {
        guard !s.root.isEmpty, exists(s.root) else { throw StudioError("请先选择已存在的 STM32 总目录。") }
        try requireProject(source)
        let src = canonical(source), dest = canonical(path(s.root,s.series + "/" + URL(fileURLWithPath:source).lastPathComponent))
        guard exists(path(src,"CMakeLists.txt")) || children(src).contains(where:{$0.hasSuffix(".ioc")}) else { throw StudioError("请选择含 .ioc 或 CMakeLists.txt 的工程根目录。") }
        var check = s; check.project = src; try validateSeries(check)
        if src == dest { return dest }
        guard !dest.hasPrefix(src + "/"), !exists(dest) else { throw StudioError("目标已存在，或总目录位于源工程内部，无法安全导入。") }
        try fm.createDirectory(atPath:dest,withIntermediateDirectories:true)
        do { for name in children(src) where !["build", ".stm32studio", ".git"].contains(name) { try fm.copyItem(atPath:path(src,name),toPath:path(dest,name)) } }
        catch { throw StudioError("导入未完成：\(error.localizedDescription)。源工程仍保留。目标目录：\(dest)") }
        runner.log("已复制工程到 \(dest)；原工程保留。\n"); return dest
    }
    func organizeUserFiles(_ s: Settings) throws {
        try requireProject(s.project)
        let src = path(s.project, "Core/Src")
        let inc = path(s.project, "Core/Inc")
        guard exists(src) || exists(inc) else { throw StudioError("当前工程没有 Core/Src 或 Core/Inc，无法整理用户代码。") }
        guard exists(path(s.project,"CMakeLists.txt")) else { throw StudioError("请先生成或整理根目录 CMake 工程，再整理用户代码。") }
        let prefixes = ["bsp", "app", "driver", "drv", "middleware", "service"]
        var moves: [(String, String)] = []
        for prefix in prefixes {
            if exists(src) {
                for name in children(src) where name.hasPrefix(prefix + "_") && name.lowercased().hasSuffix(".c") {
                    moves.append((path(src, name), path(s.project, "Core/Src/\(prefix)_c/\(name)")))
                }
            }
            if exists(inc) {
                for name in children(inc) where name.hasPrefix(prefix + "_") && name.lowercased().hasSuffix(".h") {
                    moves.append((path(inc, name), path(s.project, "Core/Inc/\(prefix)_h/\(name)")))
                }
            }
        }
        guard !moves.isEmpty else {
            try backup(s.project)
            try synchronizeUserCMake(s,prefixes:prefixes)
            runner.log("没有需要移动的用户文件，已同步现有分类目录的 CMake。\n")
            return
        }
        for (from,to) in moves {
            guard !exists(to) else { throw StudioError("目标已有同名文件，未移动任何文件：\(to)") }
            guard !from.contains(";"), !from.contains("\n"), !from.contains("\""), !from.contains("$") else { throw StudioError("文件名含不支持的 CMake 字符：\(from)") }
        }
        try backup(s.project)
        // Update CubeMX's explicit source paths before generating the user fragment.
        let cmakeFiles = [path(s.project,"CMakeLists.txt")] + ((fm.enumerator(atPath:path(s.project,"cmake"))?.allObjects as? [String]) ?? [])
            .filter { $0.hasSuffix(".cmake") || $0.hasSuffix("CMakeLists.txt") }.map { path(s.project,"cmake/" + $0) }
        for file in cmakeFiles {
            var content = read(file)
            for (from,to) in moves {
                let relativeFrom = String(from.dropFirst(s.project.count + 1))
                let relativeTo = String(to.dropFirst(s.project.count + 1))
                content = content.replacingOccurrences(of:relativeFrom,with:relativeTo)
            }
            try write(content,file)
        }
        var moved = 0
        var skipped = 0
        for (from, to) in moves {
            if exists(to) { skipped += 1; runner.log("跳过同名文件：\(to)\n"); continue }
            try fm.createDirectory(atPath: URL(fileURLWithPath: to).deletingLastPathComponent().path, withIntermediateDirectories: true)
            try fm.moveItem(atPath: from, toPath: to)
            moved += 1
            runner.log("已整理：\(from) → \(to)\n")
        }
        runner.log("代码整理完成：移动 \(moved) 个文件，跳过 \(skipped) 个同名文件。\n")
        try synchronizeUserCMake(s,prefixes:prefixes)
    }
    func synchronizeUserCMake(_ s:Settings,prefixes:[String]) throws {
        try requireProject(s.project)
        let top = path(s.project,"CMakeLists.txt")
        var sources:[String] = [], includes:[String] = []
        for prefix in prefixes {
            let source = "Core/Src/\(prefix)_c", include = "Core/Inc/\(prefix)_h"
            if exists(path(s.project,source)) {
                sources += children(path(s.project,source)).filter { $0.lowercased().hasSuffix(".c") }.map { source + "/" + $0 }
            }
            if exists(path(s.project,include)) { includes.append(include) }
        }
        for name in sources + includes {
            guard !name.contains(";"), !name.contains("\n"), !name.contains("\""), !name.contains("$"), !name.contains("\\") else { throw StudioError("文件名含不支持的 CMake 字符：\(name)") }
        }
        var fragment = "# Managed by STM32 Workbench. Regenerated by code organization.\n"
        if !sources.isEmpty { fragment += "target_sources(${CMAKE_PROJECT_NAME} PRIVATE\n" + sources.sorted().map { "    \"${CMAKE_CURRENT_LIST_DIR}/../\($0)\"" }.joined(separator:"\n") + "\n)\n" }
        if !includes.isEmpty { fragment += "target_include_directories(${CMAKE_PROJECT_NAME} PRIVATE\n" + includes.sorted().map { "    \"${CMAKE_CURRENT_LIST_DIR}/../\($0)\"" }.joined(separator:"\n") + "\n)\n" }
        try fm.createDirectory(atPath:path(s.project,"cmake"),withIntermediateDirectories:true)
        try write(fragment,path(s.project,"cmake/stm32studio-user-files.cmake"))
        let marker = "include(\"${CMAKE_CURRENT_LIST_DIR}/cmake/stm32studio-user-files.cmake\")"
        if !read(top).contains(marker) { try write(read(top) + "\n" + marker + "\n",top) }
        runner.log("已同步用户 C 文件与头文件目录到 CMake。\n")
    }
    func organizeProject(_ s: Settings) throws {
        try requireProject(s.project)
        let root = s.project
        let nested = path(root,"Projects")
        if !exists(path(root,"CMakeLists.txt")) && !exists(path(nested,"CMakeLists.txt")) {
            guard (try? ioc(root)) != nil else {
                throw StudioError("当前工程没有 CMakeLists.txt，也没有可用的 .ioc 文件，无法整理。请先导入 CubeMX 工程。")
            }
            throw StudioError("当前工程缺少 CMakeLists.txt，不能仅凭 .ioc 或已有的部分 Core/Drivers 文件确认源码完整。整理不会生成或补写源码；请明确使用“生成工程”（Generate Project）生成完整工程后重试。未修改任何文件。")
        }
        guard !exists(path(root,"CMakeLists.txt")), exists(path(nested,"CMakeLists.txt")) else {
            runner.log("工程目录已经是根目录 CMake 结构，跳过整理。\n")
            try configureEditor(s)
            return
        }
        let candidates = ["CMakeLists.txt", "CMakePresets.json", "cmake"] + children(nested).filter { $0.hasSuffix(".s") || $0.hasSuffix(".ld") }
        let moves = candidates.filter { exists(path(nested,$0)) }
        for name in moves {
            let destination = path(root,name)
            guard !exists(destination) else { throw StudioError("整理目标已存在，未移动任何文件：\(destination)") }
        }
        try backup(root)
        for name in moves {
            try fm.moveItem(atPath:path(nested,name),toPath:path(root,name))
        }
        let driverCMake = path(root,"cmake/stm32cubemx/CMakeLists.txt")
        if exists(driverCMake) {
            var text = read(driverCMake)
            // All generated project-root paths move together, including middleware.
            for anchor in ["${CMAKE_CURRENT_SOURCE_DIR}", "${CMAKE_CURRENT_LIST_DIR}"] {
                text = text.replacingOccurrences(of:anchor + "/../../../",with:anchor + "/../../")
            }
            try write(text,driverCMake)
        }
        try normalizeToolchain(root)
        try configureEditor(s)
        runner.log("已将 Projects 下的 CMake 工程整理到根目录，并修正相对路径。\n")
    }
    func generate(_ s: Settings, mcu: String? = nil) throws {
        guard exists(s.project), !s.project.isEmpty else { throw StudioError("请先选择工程。") }
        try validateSeries(s)
        var script = ""
        var configFile = path(s.project,URL(fileURLWithPath:s.project).lastPathComponent + ".ioc")
        if let mcu {
            guard SeriesCatalog.accepts(mcu,s.series) else { throw StudioError("请输入与当前系列一致的完整 MCU 型号，例如 STM32G431RBTx。") }
            guard let record = DeviceCatalog.cubeRecords(s.cube).first(where:{$0.name == mcu}), !record.package.isEmpty else { throw StudioError("本机 CubeMX 数据库中未找到此型号，请更新 CubeMX 或重新选择 MCU。") }
            let projectName = URL(fileURLWithPath:s.project).lastPathComponent
            let seed = "#MicroXplorer Configuration settings - do not modify\nFile.Version=6\nMcu.Family=\(record.family)\nMcu.Name=\(record.databaseName)\nMcu.Package=\(record.package)\nMcu.UserName=\(record.name)\nMcu.IP0=NVIC\nMcu.IP1=RCC\nMcu.IP2=SYS\nMcu.IPNb=3\nMcu.PinsNb=0\nProjectManager.ProjectName=\(projectName)\nProjectManager.ProjectFileName=\(projectName).ioc\nProjectManager.TargetToolchain=CMake\nProjectManager.UnderRoot=true\nProjectManager.ToolChainLocation=\nProjectManager.MainLocation=Core/Src\nProjectManager.LibraryCopy=1\nProjectManager.CoupleFile=true\nProjectManager.KeepUserCode=true\n"
            try write(seed,configFile)
            script += "config load \(try quoted(configFile))\n"
        } else { let file = try ioc(s.project); configFile = file; try backup(s.project); script += "config load \(try quoted(file))\n" }
        let name = URL(fileURLWithPath:configFile).deletingPathExtension().lastPathComponent
        let selectedFamily = mcu == nil ? family(s.project) : s.chipFamily
        let available = FirmwarePack.available(repository:s.repository,family:selectedFamily)
        let selectedPack = available.first(where:{$0.folder == s.pack}) ?? available.first
        guard let selectedPack else { throw StudioError("缺少 \(selectedFamily) 固件包。请在固件包目录中安装官方包，再生成工程。官方下载入口：\(FirmwarePack.downloadURL(selectedFamily).absoluteString)") }
        try syncFirmwarePackage(configFile, selectedPack.folder)
        script += "project setCustomFWPath \(try quoted(selectedPack.folder))\n"
        runner.log("使用固件包：\(selectedPack.folder)\n")
        script += "project name \(try quoted(name))\nproject toolchain CMake\nproject compiler GCC\nproject generate\nexit\n"
        let temp = path(NSTemporaryDirectory(),UUID().uuidString + ".mx")
        try write(script,temp); defer { try? fm.removeItem(atPath:temp) }
        let started = Date()
        let out = try runner.run(s.cube,["-q",temp],cwd:URL(fileURLWithPath:s.cube).deletingLastPathComponent().path,env:s.environment,timeout:900)
        let cm = path(s.project,"CMakeLists.txt")
        let nestedCM = path(s.project,"Projects/CMakeLists.txt")
        let generatedCMake = exists(cm) || exists(nestedCM)
        let toolchain = exists(path(s.project,"cmake/gcc-arm-none-eabi.cmake")) ? path(s.project,"cmake/gcc-arm-none-eabi.cmake") : path(s.project,"Projects/cmake/gcc-arm-none-eabi.cmake")
        let date = (try? fm.attributesOfItem(atPath:toolchain)[.modificationDate]) as? Date ?? .distantPast
        let generationFailed = out.contains("Code generation failed") || out.contains("Generation failed")
        guard generatedCMake, date >= started.addingTimeInterval(-2), exists(toolchain), !generationFailed else { throw StudioError("CubeMX 未成功更新完整 CMake 工程。请查看日志，在 CubeMX 中安装芯片固件包并完成必要的登录，然后重试。") }
        try organizeProject(s)
        try normalizeToolchain(s.project)
        if exists(path(s.project,"cmake/stm32studio-user-files.cmake")) {
            try synchronizeUserCMake(s,prefixes:["bsp","app","driver","drv","middleware","service"])
        }
        try configureEditor(s)
        runner.log("CubeMX 已生成 CMake 工程，并已写入自动配置的 VS Code 文件。\n")
    }
    func validateCompiler(_ s: Settings) throws {
        let triple = try runner.run(s.compiler,["-dumpmachine"],env:s.environment,timeout:15).trimmingCharacters(in:.whitespacesAndNewlines)
        guard triple == "arm-none-eabi" else { throw StudioError("选中的编译器目标为 \(triple)。STM32 需要 arm-none-eabi-gcc；macOS 的 GCC/Clang 只能编译本机程序。") }
        let dir = URL(fileURLWithPath:s.compiler).deletingLastPathComponent().path
        for tool in ["arm-none-eabi-g++","arm-none-eabi-objcopy","arm-none-eabi-size"] { guard fm.isExecutableFile(atPath:path(dir,tool)) else { throw StudioError("ARM 工具链不完整，缺少 \(tool)。") } }
    }
    func configureBuild(_ s: Settings) throws {
        try requireProject(s.project)
        let project = canonical(s.project), build = canonical(s.build)
        guard (s.project as NSString).isAbsolutePath, (s.build as NSString).isAbsolutePath,
              build != "/", build != project, !project.hasPrefix(build + "/"),
              !exists(path(build,"CMakeLists.txt")) else {
            throw StudioError("请使用独立的绝对路径构建目录，不能使用工程根目录、其上级目录或其他源码工程目录。未清除任何文件。")
        }
        try fm.createDirectory(atPath:s.build,withIntermediateDirectories:true)
        let signature = buildSignature(s)
        let sigPath = path(s.build,".toolchain-signature")
        let cachePath = path(s.build,"CMakeCache.txt")
        let needsConfigure = !exists(cachePath) || read(sigPath) != signature
        guard needsConfigure else { return }
        try runner.check()
        // Preflight both entries and cache ownership before deleting either one.
        var removable:[String] = []
        for (name,type) in [("CMakeCache.txt",FileAttributeType.typeRegular),("CMakeFiles",FileAttributeType.typeDirectory)] {
            let item = path(build,name)
            guard exists(item) || (try? fm.destinationOfSymbolicLink(atPath:item)) != nil else { continue }
            let attributes = try fm.attributesOfItem(atPath:item)
            guard attributes[.type] as? FileAttributeType == type, canonical(item) == item else {
                throw StudioError("构建缓存不是预期的普通文件/目录，或包含符号链接，未清除任何文件：\(item)。请选择新的独立构建目录。")
            }
            removable.append(item)
        }
        if !removable.isEmpty {
            let cache = read(cachePath).components(separatedBy:.newlines)
            func cacheValue(_ name:String) -> String? {
                let prefix = name + ":INTERNAL="
                return cache.first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            }
            guard let source = cacheValue("CMAKE_HOME_DIRECTORY"), let output = cacheValue("CMAKE_CACHEFILE_DIR"),
                  (source as NSString).isAbsolutePath, (output as NSString).isAbsolutePath,
                  canonical(source) == project, canonical(output) == build else {
                throw StudioError("无法确认 CMake 缓存属于当前工程及构建目录，未清除任何文件。请选择新的独立构建目录。")
            }
            for item in removable { try fm.removeItem(atPath:item) }
        }
        runner.log(removable.isEmpty ? "首次编译，配置 CMake…\n" : "检测到工具链或配置改变，已清除 CMakeCache.txt / CMakeFiles，重新配置 CMake…\n")
        let tc = s.toolchain.isEmpty ? path(s.project,"cmake/gcc-arm-none-eabi.cmake") : s.toolchain
        let bin = URL(fileURLWithPath:s.compiler).deletingLastPathComponent().path
        _ = try runner.run(s.cmake,["-S",s.project,"-B",s.build,"-G","Ninja","-DCMAKE_MAKE_PROGRAM=\(s.ninja)","-DCMAKE_BUILD_TYPE=\(s.configuration)","-DCMAKE_TOOLCHAIN_FILE=\(tc)","-DCMAKE_C_COMPILER=\(s.compiler)","-DCMAKE_CXX_COMPILER=\(path(bin,"arm-none-eabi-g++"))","-DCMAKE_ASM_COMPILER=\(s.compiler)","-DCMAKE_EXPORT_COMPILE_COMMANDS=ON"],cwd:s.project,env:s.environment)
        try write(signature,sigPath)
    }
    func build(_ s: Settings) throws -> [String] {
        try requireProject(s.project)
        try validateSeries(s)
        guard exists(path(s.project,"CMakeLists.txt")) else { throw StudioError("当前目录缺少 CMakeLists.txt，请先生成 CMake 工程。多核、TrustZone 或 MP 工程请导入对应 Cortex-M 子工程；Linux/设备树不能用 ARM GCC 直接编译。") }
        try validateCompiler(s)
        let tc = s.toolchain.isEmpty ? path(s.project,"cmake/gcc-arm-none-eabi.cmake") : s.toolchain
        guard exists(tc) else { throw StudioError("未找到 ARM CMake 工具链文件，请选择 gcc-arm-none-eabi.cmake。") }
        try configureBuild(s)
        let bin = URL(fileURLWithPath:s.compiler).deletingLastPathComponent().path
        _ = try runner.run(s.cmake,["--build",s.build,"--parallel","\(min(ProcessInfo.processInfo.activeProcessorCount,8))"],cwd:s.project,env:s.environment)
        let files = firmwareFiles(s.build)
        guard !files.isEmpty else { throw StudioError("编译命令完成，但未找到 .elf 固件。请检查工程的输出格式。") }
        for file in files {
            let base = URL(fileURLWithPath:file).deletingPathExtension().path
            _ = try runner.run(path(bin,"arm-none-eabi-objcopy"),["-O","binary",file,base + ".bin"],env:s.environment,timeout:30)
            _ = try runner.run(path(bin,"arm-none-eabi-objcopy"),["-O","ihex",file,base + ".hex"],env:s.environment,timeout:30)
        }
        runner.log("已生成 ELF / BIN / HEX：\n" + FirmwareArtifact.outputs(s.build).joined(separator:"\n") + "\n"); return files
    }
    func firmwareFiles(_ p: String) -> [String] {
        guard !p.isEmpty else { return [] }
        guard let en = fm.enumerator(atPath:p) else { return [] }
        return en.allObjects.compactMap{$0 as? String}.filter{$0.hasSuffix(".elf") && !$0.contains("CMakeFiles/")}.map{path(p,$0)}.sorted()
    }
    func buildSignature(_ s:Settings) -> String {
        let tc = s.toolchain.isEmpty ? path(s.project,"cmake/gcc-arm-none-eabi.cmake") : s.toolchain
        return [canonical(s.project),canonical(s.compiler),canonical(tc),s.ninja,s.configuration].joined(separator:"\n")
    }
    func flashArguments(_ s: Settings) throws -> [String] {
        guard !s.chipFamily.isEmpty, SeriesCatalog.accepts(s.chipModel,s.series), s.chipModel.hasPrefix(s.chipFamily) || s.chipFamily == "STM32L4+" else { throw StudioError("请先选择系列和具体 MCU 型号。") }
        guard exists(s.firmware), ["elf","hex","bin"].contains(URL(fileURLWithPath:s.firmware).pathExtension.lowercased()) else { throw StudioError("请选择 ELF、HEX 或 BIN 固件。") }
        guard let speed = Int(s.speed), (50...24000).contains(speed) else { throw StudioError("SWD 速度请填写 50–24000 kHz。") }
        guard s.target.hasSuffix(".cfg"), !s.target.isEmpty else { throw StudioError("请选择匹配芯片的 OpenOCD target .cfg 文件。") }
        guard openocdFile(s.target,s) != nil else { throw StudioError("本机 OpenOCD 未找到芯片配置：\(s.target)。请安装支持该芯片的 OpenOCD，或选择厂商提供的 target .cfg；不能沿用其他系列的配置。") }
        let known = targetFor(s.chipFamily,model:s.chipModel)
        if let known, s.target.hasPrefix("target/"), known != s.target { throw StudioError("OpenOCD 目标与所选芯片不一致，应使用 \(known)。") }
        let offset = try binaryOffset(s)
        return ["-f",s.probe == "ST-Link" ? "interface/stlink.cfg" : "interface/cmsis-dap.cfg","-f",openocdFile(s.target,s) ?? s.target,"-c","adapter speed \(speed)","-c","program \(tclWord(s.firmware)) verify reset exit\(offset)"]
    }
    func binaryOffset(_ s:Settings) throws -> String {
        guard URL(fileURLWithPath:s.firmware).pathExtension.lowercased() == "bin" else { return "" }
        guard s.binaryAddress.range(of:"^0x[0-9A-Fa-f]{1,8}$",options:.regularExpression) != nil, UInt32(s.binaryAddress.dropFirst(2),radix:16) != nil else { throw StudioError("BIN 需要有效的 32 位十六进制写入地址，例如 0x08000000。") }
        return " " + s.binaryAddress
    }
    func hardwareArguments(_ s:Settings) throws -> [String] {
        guard !s.chipFamily.isEmpty, SeriesCatalog.accepts(s.chipModel,s.series), !s.target.isEmpty,
              let target = openocdFile(s.target,s), let speed = Int(s.speed), (50...24000).contains(speed) else { throw StudioError("请选择 MCU、有效 OpenOCD target 和 SWD 速度。") }
        if let known = targetFor(s.chipFamily,model:s.chipModel), s.target.hasPrefix("target/"), known != s.target { throw StudioError("芯片配置不匹配，应使用 \(known)。") }
        return ["-f",s.probe == "ST-Link" ? "interface/stlink.cfg" : "interface/cmsis-dap.cfg","-f",target,"-c","adapter speed \(speed)"]
    }
    func hardware(_ action:String,_ s:Settings) throws {
        var args = try hardwareArguments(s)
        let command:String
        switch action {
        case "连接检测": command = "init; targets; flash banks; shutdown"
        case "复位运行": command = "init; reset run; shutdown"
        case "擦除 Flash Bank 0": command = "init; reset init; flash erase_sector 0 0 last; shutdown"
        case "校验固件":
            _ = try flashArguments(s)
            command = "init; reset halt; verify_image \(tclWord(s.firmware))\(try binaryOffset(s)); reset run; shutdown"
        default: throw StudioError("未知硬件操作。")
        }
        args += ["-c",command]
        _ = try runner.run(s.openocd,args,env:s.environment,timeout:180)
    }
    func flash(_ s: Settings) throws {
        let artifact = try FirmwareArtifact.inspect(s.firmware)
        guard s.expectedFirmwareHash.isEmpty || s.expectedFirmwareHash == artifact.sha256 else { throw StudioError("固件在确认后发生变化，请刷新文件信息并重新确认烧录。") }
        runner.log("将烧录当前文件：\(artifact.file)\n\(artifact.summary)\n完整 SHA-256：\(artifact.sha256)\n")
        _ = try runner.run(s.openocd,try flashArguments(s),env:s.environment,timeout:180)
    }
    func configureEditor(_ s: Settings) throws {
        try requireProject(s.project)
        try normalizeToolchain(s.project)
        let folder = path(s.project,".vscode")
        if exists(folder) { let bak = path(s.project,".stm32studio/vscode-" + UUID().uuidString); try fm.createDirectory(atPath:URL(fileURLWithPath:bak).deletingLastPathComponent().path,withIntermediateDirectories:true); try fm.copyItem(atPath:folder,toPath:bak) }
        try fm.createDirectory(atPath:folder,withIntermediateDirectories:true)
        let toolchain = s.toolchain.isEmpty ? path(s.project,"cmake/gcc-arm-none-eabi.cmake") : s.toolchain
        let compilerDir = URL(fileURLWithPath:s.compiler).deletingLastPathComponent().path
        let configureCommand = "if [ ! -f \(shellWord(path(s.build,"CMakeCache.txt"))) ]; then \(shellWord(s.cmake)) -S \"${workspaceFolder}\" -B \(shellWord(s.build)) -G Ninja -DCMAKE_MAKE_PROGRAM=\(shellWord(s.ninja)) -DCMAKE_BUILD_TYPE=\(shellWord(s.configuration)) -DCMAKE_TOOLCHAIN_FILE=\(shellWord(toolchain)) -DCMAKE_C_COMPILER=\(shellWord(s.compiler)) -DCMAKE_CXX_COMPILER=\(shellWord(path(compilerDir,"arm-none-eabi-g++"))) -DCMAKE_ASM_COMPILER=\(shellWord(s.compiler)) -DCMAKE_EXPORT_COMPILE_COMMANDS=ON; else echo 'CMake 已配置，跳过配置阶段'; fi"
        let configure: [String:Any] = ["label":"STM32: Configure (首次自动)","type":"process","command":"/bin/zsh","args":["-lc",configureCommand],"options":["env":["PATH":s.environment["PATH"] ?? "", "LC_ALL":"en_US.UTF-8"]],"problemMatcher":[]]
        let build: [String:Any] = ["label":"STM32: Build","type":"process","command":s.cmake,"args":["--build",s.build],"options":["env":["PATH":s.environment["PATH"] ?? "", "LC_ALL":"en_US.UTF-8"]],"dependsOn":"STM32: Configure (首次自动)","dependsOrder":"sequence","problemMatcher":["$gcc"],"group":["kind":"build","isDefault":true]]
        let settings: [String:Any] = ["cmake.sourceDirectory":"${workspaceFolder}","cmake.buildDirectory":s.build,"cmake.generator":"Ninja","cmake.defaultBuildType":s.configuration,"cmake.configureOnOpen":true,"cmake.configureSettings":["CMAKE_C_COMPILER":s.compiler,"CMAKE_CXX_COMPILER":path(compilerDir,"arm-none-eabi-g++"),"CMAKE_ASM_COMPILER":s.compiler,"CMAKE_MAKE_PROGRAM":s.ninja],"cmake.buildBeforeRun":true,"C_Cpp.default.compilerPath":s.compiler,"C_Cpp.default.compileCommands":path(s.build,"compile_commands.json")]
        let launch: [String:Any] = ["name":"STM32 \(s.probe)","type":"cortex-debug","request":"launch","cwd":"${workspaceFolder}","executable":s.firmware.isEmpty ? "${command:cmake.launchTargetPath}" : s.firmware,"servertype":"openocd","serverpath":s.openocd,"armToolchainPath":URL(fileURLWithPath:s.compiler).deletingLastPathComponent().path,"configFiles":[s.probe == "ST-Link" ? "interface/stlink.cfg" : "interface/cmsis-dap.cfg",s.target],"preLaunchTask":"STM32: Build","runToEntryPoint":"main"]
        for (name,obj) in [("settings.json",settings as [String:Any]),("tasks.json",["version":"2.0.0","tasks":[configure,build]] as [String:Any]),("launch.json",["version":"0.2.0","configurations":[launch]] as [String:Any])] { try JSONSerialization.data(withJSONObject:obj,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:path(folder,name)),options:.atomic) }
        runner.log("已更新 VS Code 编译/调试配置，原配置已备份。\n")
    }
}
