import Foundation
import Darwin

func runProgrammingTests() throws {
    let folder = path(NSTemporaryDirectory(),"workbench-test-" + UUID().uuidString)
    try fm.createDirectory(atPath:folder,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:folder) }
    func expect(_ ok:Bool,_ label:String) throws { guard ok else { throw StudioError(label) }; print("PASS: " + label) }
    func rejects(_ label:String,_ action:()throws->Void) throws {
        do { try action() } catch { print("PASS: " + label); return }; throw StudioError("Expected rejection: " + label)
    }
    var s = Settings(); s.programmerBackend = "CubeProgrammer"; s.cubeProgrammer = "/missing/cube"
    s.firmware = path(folder,"固件 $[file].bin"); try write("binary",s.firmware)
    let engine = Engine(runner:Runner(log:{_ in}))
    let flash = try engine.programmingCommand(.flash,s)
    try expect(flash.arguments == ["-c","port=SWD","freq=1000","mode=NORMAL","-w",s.firmware,"0x08000000","-v","-rst"],"Cube SWD write, verify, reset; Unicode path stays one argument")
    s.connectionMode = "Under Reset"; s.probeSerial = "12345"
    try expect(try engine.programmingCommand(.connect,s).arguments.contains("mode=UR"),"Under-reset connection")
    try expect(try engine.programmingCommand(.connect,s).arguments.contains("sn=12345"),"Probe serial targeting")
    s.programmerTransport = "UART"; s.serialPort = "/dev/cu.usbserial-test"
    let uart = try engine.programmingCommand(.flash,s).arguments
    try expect(uart.contains("port=/dev/cu.usbserial-test") && uart.contains("P=EVEN") && !uart.contains("-rst"),"UART even parity, no unsupported reset")
    try rejects("UART reset explicitly unavailable") { _ = try engine.programmingCommand(.reset,s) }
    s.serialPort = "SWD"; try rejects("Invalid UART port rejected") { _ = try engine.programmingCommand(.connect,s) }
    s.programmerTransport = "USB DFU"
    try expect(try engine.programmingCommand(.connect,s).arguments.contains("port=USB1"),"DFU connection")
    s.dfuPort = "USB1 -e all"; try rejects("Invalid DFU port rejected") { _ = try engine.programmingCommand(.connect,s) }; s.dfuPort = "USB1"
    let verify = try engine.programmingCommand(.verify,s).arguments
    try expect(verify.contains("-v") && !verify.contains("-w") && !verify.contains("-e"),"Verify-only does not write or erase")
    s.binaryAddress = "0x08000000;exit"
    try rejects("Invalid firmware address rejected") { _ = try engine.programmingCommand(.flash,s) }; s.binaryAddress = "0x08000000"
    s.backupAddress = "0xfffffff0"; s.backupLength = "32"
    try rejects("Backup rejects 32-bit address overflow") { _ = try engine.validatedRange(s) }
    s.backupAddress = "0x08000000"; s.backupLength = "65536"
    let backup = try engine.programmingCommand(.backup(path(folder,"backup.bin")),s)
    try expect(backup.arguments.suffix(4).first == "-u", "Backup uses upload, not write")
    s.programmerTransport = "SWD"
    try expect(try engine.programmingCommand(.optionBytes,s).arguments.suffix(2) == ["-ob","displ"],"Option bytes read-only")
    let digest = try FirmwareArtifact.inspect(s.firmware).sha256
    s.expectedFirmwareHash = digest; try write("changed",s.firmware)
    try rejects("Changed firmware blocked before tool execution") { try engine.program(.flash,s) }
    let existing = path(folder,"existing.bin"); try write("keep",existing)
    try rejects("Backup never overwrites existing destination") { try engine.program(.backup(existing),s) }
    try expect(read(existing) == "keep","Existing backup preserved")
    let encoded = try JSONEncoder().encode(ConnectionPreset(s))
    try expect(!String(decoding:encoded,as:UTF8.self).contains("/Users/"),"Connection preset excludes private local paths")
    var restored = Settings(); try JSONDecoder().decode(ConnectionPreset.self,from:encoded).apply(to:&restored)
    try expect(restored.chipModel == s.chipModel && restored.connectionMode == s.connectionMode,"Preset round trip")
    try expect(try SerialTerminal.payload("01 A0 ff",hex:true,newline:true) == Data([1,160,255]),"HEX serial payload")
    try expect(try SerialTerminal.payload("ok",hex:false,newline:true) == Data("ok\r\n".utf8),"Text serial CRLF")
    try rejects("Odd HEX rejected") { _ = try SerialTerminal.payload("A",hex:true,newline:false) }
    let script = path(folder,"old-settings.json"); try write("{\"root\":\"/tmp/test\"}",script)
    try expect(Settings.load(script).programmerBackend == "OpenOCD","Old settings migrate to default backend")
    var release = s; release.configuration = "Release"
    try expect(engine.buildSignature(release) != engine.buildSignature(s),"Fixed build folder reconfigures when Debug changes to Release")
    let emptyFile = path(folder,"empty.bin"); try write("",emptyFile)
    try rejects("Empty firmware rejected") { _ = try FirmwareArtifact.inspect(emptyFile) }
    do { _ = try Runner(log:{_ in}).run("/bin/sleep",["2"],timeout:0.1); throw StudioError("Timeout did not trigger") }
    catch { try expect(error.localizedDescription.contains("超时"),"Timeout reports the actual cause") }
    s.programmerBackend = "OpenOCD"; s.target = path(folder,"target.cfg"); try write("# test target",s.target)
    let openocd = try engine.programmingCommand(.connect,s).arguments
    try expect(openocd.contains("adapter serial \"12345\"") && openocd.contains("reset_config srst_only srst_nogate connect_assert_srst"),"OpenOCD serial selection and under-reset configuration")
    try rejects("OpenOCD option byte changes not exposed") { _ = try engine.programmingCommand(.optionBytes,s) }
    // Exercise the actual serial transport without a connected development board.
    var master: Int32 = -1, slave: Int32 = -1
    var name = [CChar](repeating:0,count:128)
    guard openpty(&master,&slave,&name,nil,nil) == 0 else { throw StudioError("openpty failed") }
    Darwin.close(slave); defer { Darwin.close(master) }
    let terminal = SerialTerminal(); terminal.connect(port:String(cString:name),baud:"115200")
    try expect(terminal.connected,"Pseudo-terminal opens with 8N1 configuration: " + terminal.status)
    let input = Data([0,1,0x41,0xff]); _ = input.withUnsafeBytes { Darwin.write(master,$0.baseAddress,input.count) }
    let deadline = Date().addingTimeInterval(2)
    while terminal.received.count < input.count && Date() < deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.01)) }
    try expect(terminal.received == input,"Serial RX preserves binary bytes")
    terminal.send("01 A0",hex:true,newline:false)
    _ = fcntl(master,F_SETFL,O_NONBLOCK)
    var output = [UInt8](repeating:0,count:10)
    let size = Darwin.read(master,&output,output.count)
    try expect(size == 2 && Array(output.prefix(2)) == [1,160],"Serial TX sends exact HEX bytes")
    terminal.disconnect()
    let project = path(folder,"User Files")
    try fm.createDirectory(atPath:path(project,"Core/Src"),withIntermediateDirectories:true)
    try fm.createDirectory(atPath:path(project,"Core/Inc"),withIntermediateDirectories:true)
    try write("int value(void);\n",path(project,"Core/Inc/bsp_value.h"))
    try write("#include \"bsp_value.h\"\nint value(void) { return 42; }\n",path(project,"Core/Src/bsp_value.c"))
    try write("#include \"bsp_value.h\"\nint main(void) { return value() == 42 ? 0 : 1; }\n",path(project,"Core/Src/main.c"))
    try write("cmake_minimum_required(VERSION 3.20)\nproject(OrganizerCheck C)\nadd_executable(${CMAKE_PROJECT_NAME} Core/Src/main.c Core/Src/bsp_value.c)\ntarget_include_directories(${CMAKE_PROJECT_NAME} PRIVATE Core/Inc)\n",path(project,"CMakeLists.txt"))
    var organized = Settings(); organized.project = project
    try engine.organizeUserFiles(organized)
    try expect(exists(path(project,"Core/Src/bsp_c/bsp_value.c")) && exists(path(project,"Core/Inc/bsp_h/bsp_value.h")),"Code organizer moves source and header")
    try expect(read(path(project,"CMakeLists.txt")).contains("Core/Src/bsp_c/bsp_value.c"),"Organizer updates existing CMake source references")
    try engine.organizeUserFiles(organized)
    try expect(read(path(project,"CMakeLists.txt")).components(separatedBy:"include(\"${CMAKE_CURRENT_LIST_DIR}/cmake/stm32studio-user-files.cmake\")").count == 2,"Organizer rerun does not duplicate CMake integration")
    var local = Settings(); local.discover()
    if !local.cmake.isEmpty {
        _ = try engine.runner.run(local.cmake,["-S",project,"-B",path(project,"build"),"-G","Unix Makefiles","-DCMAKE_MAKE_PROGRAM=/usr/bin/make","-DCMAKE_C_COMPILER=/usr/bin/clang"],env:local.environment)
        _ = try engine.runner.run(local.cmake,["--build",path(project,"build")],env:local.environment)
        _ = try engine.runner.run(path(project,"build/OrganizerCheck"),[])
        try expect(true,"Organized project configures, compiles and runs with real CMake")
    } else { print("SKIP: Real CMake integration (CMake not installed)") }
    print("PROGRAMMING TESTS PASSED")
}
