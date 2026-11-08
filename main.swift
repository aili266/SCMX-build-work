import AppKit
if CommandLine.arguments.contains("--localization-test") {
    do {
        var tables = [String:[String:String]]()
        for language in AppLanguage.allCases {
            guard let resource = Bundle.main.url(forResource:"Localizable",withExtension:"strings",subdirectory:nil,localization:language.rawValue) else { throw StudioError("Missing language resource: \(language.rawValue)") }
            let value = try PropertyListSerialization.propertyList(from:Data(contentsOf:resource),options:[],format:nil)
            guard let strings = value as? [String:String], strings.count >= 150, strings.values.allSatisfy({ !$0.isEmpty }) else { throw StudioError("Invalid language table: \(language.rawValue)") }
            tables[language.rawValue] = strings
            print("PASS: \(language.rawValue) resource contains \(strings.count) nonempty entries")
        }
        guard let english = tables["en"], let chinese = tables["zh-Hans"], Set(english.keys) == Set(chinese.keys), english["Flashing"] == "Flashing", chinese["Flashing"] == "烧录工作台" else { throw StudioError("Language key or translation mismatch") }
        print("PASS: English and Simplified Chinese keys match and navigation translations resolve")
        exit(0)
    } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--settings-test") {
    do { try runSettingsTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--startup-test") {
    do { try runStartupTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--register-test") {
    do { try runRegisterDatabaseTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--register-data-test") {
    do { try runBundledRegisterTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--log-test") {
    do { try runLogBufferTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--runner-test") {
    do { try runRunnerTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--programming-test") {
    do { try runProgrammingTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if CommandLine.arguments.contains("--self-test") {
    do { try runTests(); exit(0) } catch { print("FAIL: \(error)"); exit(1) }
} else if let i = CommandLine.arguments.firstIndex(of:"--verify-build"), CommandLine.arguments.count > i + 1 {
    var s = Settings(); s.discover(); s.project = CommandLine.arguments[i+1]; s.series = SeriesCatalog.group(Engine(runner:Runner(log:{_ in})).family(s.project)) ?? "Gseries"
    do { let files = try Engine(runner:Runner(log:{print($0,terminator:"")})).build(s); print("BUILD VERIFIED: \(files)"); exit(0) } catch { print(error.localizedDescription); exit(1) }
} else if let i = CommandLine.arguments.firstIndex(of:"--verify-generate"), CommandLine.arguments.count > i + 1 {
    var s = Settings(); s.discover(); s.project = CommandLine.arguments[i+1]; s.series = "Fseries"
    do { try Engine(runner:Runner(log:{print($0,terminator:" ")})).generate(s); print("GENERATION VERIFIED"); exit(0) } catch { print(error.localizedDescription); exit(1) }
} else if let i = CommandLine.arguments.firstIndex(of:"--verify-new"), CommandLine.arguments.count > i + 1 {
    var s = Settings(); s.discover(); s.project = CommandLine.arguments[i+1]; s.series = "Fseries"; s.chipFamily = "STM32F1"; s.chipModel = "STM32F103C8Tx"
    do { try fm.createDirectory(atPath:s.project,withIntermediateDirectories:true); try Engine(runner:Runner(log:{print($0,terminator:"")})).generate(s,mcu:s.chipModel); print("NEW PROJECT VERIFIED"); exit(0) } catch { print(error.localizedDescription); exit(1) }
} else if let i = CommandLine.arguments.firstIndex(of:"--verify-debug-live"), CommandLine.arguments.count > i + 1 {
    var s = Settings(); s.discover(); s.series = "Fseries"; s.chipFamily = "STM32F1"; s.chipModel = "STM32F103C8Tx"; s.target = "target/stm32f1x.cfg"; s.firmware = CommandLine.arguments[i+1]
    let session = DebugSession(); session.start(s); let deadline = Date().addingTimeInterval(35); var phase = 0; var done = false
    while Date() < deadline && session.active && !done {
        RunLoop.current.run(until:Date().addingTimeInterval(0.05))
        if session.connected && !session.busyCommand {
            if phase == 0 { phase = 1; session.readMemory("0x08000000","4") }
            else if phase == 1 { phase = 2; session.console("monitor resume") { ok,_ in done = ok } }
        }
    }
    print(session.log); print("REGISTERS: \(session.registers)"); print("MEMORY: \(session.memory)")
    let success = done && session.registers.contains("pc") && (session.memory.contains("0x08000000") || session.memory.contains("0x8000000"))
    session.disconnect(); print(success ? "LIVE DEBUG VERIFIED; target resumed" : "LIVE DEBUG NOT VERIFIED"); exit(success ? 0 : 1)
} else {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let delegate = AppDelegate(); app.delegate = delegate; app.run()
}
