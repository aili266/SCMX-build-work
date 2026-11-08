import AppKit
if CommandLine.arguments.contains("--programming-test") {
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
