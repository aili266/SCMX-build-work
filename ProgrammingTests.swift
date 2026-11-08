import Foundation
import Darwin

func runProjectOrganizationConflictTests() throws {
    let folder = path(NSTemporaryDirectory(),"workbench-conflict-test-" + UUID().uuidString)
    try fm.createDirectory(atPath:folder,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:folder) }
    func expect(_ ok:Bool,_ label:String) throws { guard ok else { throw StudioError(label) }; print("PASS: " + label) }
    let cases = [("cmake",false),("cmake",true),("CMakePresets.json",false),("startup.s",false),("memory.ld",false)]
    for (index,test) in cases.enumerated() {
        let (conflict,populated) = test
        let project = path(folder,"Project-\(index)")
        let nested = path(project,"Projects")
        try fm.createDirectory(atPath:path(nested,"cmake/stm32cubemx"),withIntermediateDirectories:true)
        let files = ["CMakeLists.txt":"add_subdirectory(cmake/stm32cubemx)\n",
                     "CMakePresets.json":"{}\n", "startup.s":"startup\n", "memory.ld":"linker\n",
                     "cmake/stm32cubemx/CMakeLists.txt":"# nested CMake\n",
                     "cmake/gcc-arm-none-eabi.cmake":"# toolchain\n"]
        for (name,content) in files { try write(content,path(nested,name)) }
        let destination = path(project,conflict)
        let preserved = conflict == "cmake" ? path(destination,"custom.cmake") : destination
        if conflict == "cmake" { try fm.createDirectory(atPath:destination,withIntermediateDirectories:true) }
        if conflict != "cmake" || populated { try write("keep original\n",preserved) }
        let before = ((fm.enumerator(atPath:project)?.allObjects as? [String]) ?? []).sorted()
        var settings = Settings(); settings.project = project
        var messages = "", rejection:String?
        let engine = Engine(runner:Runner(log:{ messages += $0 }))
        do { try engine.organizeProject(settings) } catch { rejection = error.localizedDescription }
        let label = "Conflict \(conflict) (case \(index))"
        try expect(rejection?.contains(destination) == true,label + " reports the conflicting destination")
        let after = ((fm.enumerator(atPath:project)?.allObjects as? [String]) ?? []).sorted()
        try expect(before == after,label + " leaves every file and directory in its original location")
        for (name,content) in files {
            try expect(read(path(nested,name)) == content,label + " preserves Projects/" + name)
        }
        if conflict != "cmake" || populated { try expect(read(preserved) == "keep original\n",label + " preserves the existing destination") }
        try expect(messages.isEmpty,label + " does not report backup or organization success")
    }
}

func runEngineRegressionTests() throws {
    let folder = path("/tmp","workbench-engine-test-" + UUID().uuidString)
    try fm.createDirectory(atPath:folder,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:folder) }
    func expect(_ ok:Bool,_ label:String) throws { guard ok else { throw StudioError(label) }; print("PASS: " + label) }
    func put(_ file:String,_ content:String) throws {
        try fm.createDirectory(atPath:URL(fileURLWithPath:file).deletingLastPathComponent().path,withIntermediateDirectories:true)
        try write(content,file)
    }
    let incompleteCases:[(String,[String:String])] = [
        ("ioc-only",[:]), ("core-only",["Core/Src/user.c":"keep core\n"]),
        ("partial",["Core/Src/user.c":"keep core\n","Drivers/CMSIS/device.h":"keep driver\n"])
    ]
    for (name,extra) in incompleteCases {
        let project = path(folder,name)
        let files = extra.merging(["Test.ioc":"Mcu.Family=STM32G4\n"]) { old,_ in old }
        for (file,content) in files { try put(path(project,file),content) }
        let before = ((fm.enumerator(atPath:project)?.allObjects as? [String]) ?? []).sorted()
        var settings = Settings(); settings.project = project; settings.cube = "/usr/bin/false"
        var messages = "", rejection:String?
        let engine = Engine(runner:Runner(log:{ messages += $0 }))
        do { try engine.organizeProject(settings) } catch { rejection = error.localizedDescription }
        try expect(rejection?.contains("生成工程") == true && rejection?.contains("Core/Drivers") == true,name + " explicitly requires generation instead of claiming a complete project")
        let after = ((fm.enumerator(atPath:project)?.allObjects as? [String]) ?? []).sorted()
        try expect(before == after && messages.isEmpty,name + " does not invoke CubeMX or create CMake, editor or backup files")
        for (file,content) in files { try expect(read(path(project,file)) == content,name + " preserves " + file) }
    }

    let source = path(folder,"guard-source")
    try put(path(source,"CMakeLists.txt"),"# source project\n")
    try put(path(source,"Core/main.c"),"keep source\n")
    try put(path(source,"CMakeCache.txt"),"keep source cache\n")
    try put(path(source,"CMakeFiles/user.c"),"keep source file\n")
    var guarded = Settings(); guarded.project = source; guarded.cmake = "/usr/bin/false"
    func rejectsConfiguration(_ settings:Settings,_ label:String) throws {
        var messages = "", rejection:String?
        let engine = Engine(runner:Runner(log:{ messages += $0 }))
        do { try engine.configureBuild(settings) } catch { rejection = error.localizedDescription }
        try expect(rejection?.contains("未清除任何文件") == true && messages.isEmpty,label + " rejected before cleanup or tool execution")
    }
    let alias = path(folder,"source-alias")
    try fm.createSymbolicLink(atPath:alias,withDestinationPath:source)
    for output in [source,alias,folder,"/","relative-build"] {
        guarded.outputDirectory = output
        try rejectsConfiguration(guarded,"Unsafe build path " + output)
    }
    try put(path(source,"Core/CMakeLists.txt"),"# another source project\n")
    guarded.outputDirectory = path(source,"Core")
    try rejectsConfiguration(guarded,"Nested source project")
    try expect(read(path(source,"CMakeCache.txt")) == "keep source cache\n" && read(path(source,"CMakeFiles/user.c")) == "keep source file\n","Unsafe build paths preserve source-root cache and files")
    for kind in ["foreign-source","foreign-output","unowned","linked-cache","linked-files","dangling-files"] {
        let output = path(folder,kind)
        guarded.outputDirectory = output
        let owner = kind == "foreign-source" ? folder : source
        let location = kind == "foreign-output" ? folder : output
        let cache = kind == "unowned" ? "user file\n" : "CMAKE_HOME_DIRECTORY:INTERNAL=\(owner)\nCMAKE_CACHEFILE_DIR:INTERNAL=\(location)\n"
        try put(path(output,"CMakeCache.txt"),cache)
        try put(path(output,"CMakeFiles/keep.txt"),"keep metadata\n")
        if kind == "linked-cache" {
            try fm.removeItem(atPath:path(output,"CMakeCache.txt"))
            try fm.createSymbolicLink(atPath:path(output,"CMakeCache.txt"),withDestinationPath:path(source,"CMakeCache.txt"))
        } else if kind == "linked-files" || kind == "dangling-files" {
            try fm.removeItem(atPath:path(output,"CMakeFiles"))
            try fm.createSymbolicLink(atPath:path(output,"CMakeFiles"),withDestinationPath:path(source,kind == "linked-files" ? "Core" : "missing"))
        }
        try rejectsConfiguration(guarded,kind)
        try expect(read(path(output,"CMakeCache.txt")) == (kind == "linked-cache" ? "keep source cache\n" : cache),kind + " preserves the cache during preflight rejection")
        if kind == "linked-files" || kind == "dangling-files" {
            try expect((try? fm.destinationOfSymbolicLink(atPath:path(output,"CMakeFiles"))) != nil,kind + " preserves the link")
        } else { try expect(read(path(output,"CMakeFiles/keep.txt")) == "keep metadata\n",kind + " preserves CMakeFiles") }
    }
    try expect(read(path(source,"Core/main.c")) == "keep source\n","Cache guards never remove linked source files")

    guard let cmake = ["/opt/homebrew/bin/cmake","/usr/local/bin/cmake","/Applications/CMake.app/Contents/bin/cmake"].first(where:{fm.isExecutableFile(atPath:$0)}),
          let ninja = ["/opt/homebrew/bin/ninja","/usr/local/bin/ninja"].first(where:{fm.isExecutableFile(atPath:$0)}) else {
        print("SKIP: Real CMake regression tests (CMake or Ninja not installed)"); return
    }
    let engine = Engine(runner:Runner(log:{_ in}))
    var settings = Settings(); settings.cmake = cmake; settings.ninja = ninja; settings.compiler = "/usr/bin/clang"
    settings.project = path(folder,"cache-project"); settings.outputDirectory = path(folder,"cache-output")
    try put(path(settings.project,"CMakeLists.txt"),"cmake_minimum_required(VERSION 3.20)\nproject(CacheFixture C)\nadd_executable(CacheFixture main.c)\n")
    let main = "int main(void) { return 0; }\n"
    try put(path(settings.project,"main.c"),main)
    for name in ["A","B"] { try put(path(settings.project,name + ".cmake"),"set(CMAKE_C_FLAGS_INIT \"-DWORKBENCH_\(name)\")\n") }
    settings.toolchain = path(settings.project,"A.cmake")
    try engine.configureBuild(settings)
    try expect(read(path(settings.build,"CMakeCache.txt")).contains("CMAKE_C_FLAGS:STRING=-DWORKBENCH_A"),"Real CMake initializes toolchain A flags")
    let cachedMarker = path(settings.build,"CMakeFiles/cache-hit-marker")
    try write("keep on cache hit\n",cachedMarker)
    try engine.configureBuild(settings)
    try expect(exists(cachedMarker),"Unchanged signature preserves the configured cache")
    try put(path(settings.build,"user.c"),"keep user source\n")
    try put(path(settings.build,"firmware.elf"),"keep artifact\n")
    try put(path(settings.build,"other/data.txt"),"keep other output\n")
    try fm.createSymbolicLink(atPath:path(settings.build,"CMakeFiles/source-link"),withDestinationPath:settings.project)
    settings.toolchain = path(settings.project,"B.cmake")
    try engine.configureBuild(settings)
    let cache = read(path(settings.build,"CMakeCache.txt"))
    try expect(cache.contains("CMAKE_C_FLAGS:STRING=-DWORKBENCH_B") && !cache.contains("-DWORKBENCH_A"),"Real CMake A -> B replaces cached flags")
    let commands = try JSONSerialization.jsonObject(with:Data(contentsOf:URL(fileURLWithPath:path(settings.build,"compile_commands.json")))) as? [[String:Any]]
    try expect(commands?.contains(where:{ ($0["command"] as? String)?.contains("-DWORKBENCH_B") == true }) == true,"Generated compile command uses toolchain B")
    try expect(!exists(cachedMarker) && read(path(settings.build,".toolchain-signature")) == engine.buildSignature(settings),"Reconfiguration replaces CMakeFiles and commits the new signature")
    try expect(read(path(settings.project,"main.c")) == main && read(path(settings.build,"user.c")) == "keep user source\n" && read(path(settings.build,"firmware.elf")) == "keep artifact\n" && read(path(settings.build,"other/data.txt")) == "keep other output\n","Cache cleanup preserves sources, symlink targets and all unrelated build files")
    settings.configuration = "Release"
    try engine.configureBuild(settings)
    try expect(read(path(settings.build,"CMakeCache.txt")).contains("CMAKE_BUILD_TYPE:STRING=Release"),"Fixed output directory still switches Debug -> Release")

    settings.project = path(folder,"middleware-project"); settings.outputDirectory = ""; settings.toolchain = ""
    let nested = path(settings.project,"Projects")
    try put(path(nested,"CMakeLists.txt"),"cmake_minimum_required(VERSION 3.20)\nproject(MiddlewareFixture NONE)\nadd_subdirectory(cmake/stm32cubemx)\n")
    let resources = ["Core/Src/main.c","Drivers/CMSIS/device.h","Middlewares/Third_Party/FreeRTOS/tasks.c","USB_DEVICE/App/usb_device.c","USB_HOST/App/usb_host.c","FATFS/App/fatfs.c","LWIP/App/lwip.c","AZURE_RTOS/App/app_threadx.c"]
    for resource in resources { try put(path(settings.project,resource),"keep resource\n") }
    var driver = "foreach(resource\n"
    for anchor in ["${CMAKE_CURRENT_SOURCE_DIR}","${CMAKE_CURRENT_LIST_DIR}"] {
        driver += resources.map { "    \"\(anchor)/../../../\($0)\"\n" }.joined()
    }
    driver += ")\n  if(NOT EXISTS \"${resource}\")\n    message(FATAL_ERROR \"Missing generated resource: ${resource}\")\n  endif()\nendforeach()\n"
    try put(path(nested,"cmake/stm32cubemx/CMakeLists.txt"),driver)
    _ = try engine.runner.run(cmake,["-S",nested,"-B",path(folder,"middleware-before"),"-G","Ninja","-DCMAKE_MAKE_PROGRAM=\(ninja)"],env:settings.environment)
    try engine.organizeProject(settings)
    _ = try engine.runner.run(cmake,["-S",settings.project,"-B",path(folder,"middleware-after"),"-G","Ninja","-DCMAKE_MAKE_PROGRAM=\(ninja)"],env:settings.environment)
    try expect(!read(path(settings.project,"cmake/stm32cubemx/CMakeLists.txt")).contains("/../../../"),"All generated project-root paths are rebased")
    for resource in resources { try expect(read(path(settings.project,resource)) == "keep resource\n","Real CMake resolves and preserves " + resource + " before and after organization") }
}

func runProgrammingTests() throws {
    try runProjectOrganizationConflictTests()
    try runEngineRegressionTests()
    let folder = path(NSTemporaryDirectory(),"workbench-test-" + UUID().uuidString)
    try fm.createDirectory(atPath:folder,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:folder) }
    func expect(_ ok:Bool,_ label:String) throws { guard ok else { throw StudioError(label) }; print("PASS: " + label) }
    func rejects(_ label:String,_ action:()throws->Void) throws {
        do { try action() } catch { print("PASS: " + label); return }; throw StudioError("Expected rejection: " + label)
    }
    var s = Settings(); s.programmerBackend = "CubeProgrammer"; s.cubeProgrammer = "/missing/cube"
    s.series = "Gseries"; s.chipFamily = "STM32G4"; s.chipModel = "STM32G431RBTx"; s.target = "target/stm32g4x.cfg"
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
