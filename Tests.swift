import Foundation
func runTests() throws {
    let temp = path(NSTemporaryDirectory(),"STM32 Studio 中文 " + UUID().uuidString)
    try fm.createDirectory(atPath:temp,withIntermediateDirectories:true); defer { try? fm.removeItem(atPath:temp) }
    let e = Engine(runner:Runner(log:{print($0,terminator:"")}))
    func expect(_ condition:Bool,_ message:String) throws { if !condition { throw StudioError(message) }; print("PASS: \(message)") }
    func rejects(_ label:String,_ f:()throws->Void) throws { do { try f() } catch { print("PASS: \(label)"); return }; throw StudioError("未拒绝：" + label) }
    let src = path(temp,"源 工程"); try fm.createDirectory(atPath:src,withIntermediateDirectories:true); try write("Mcu.Family=STM32G4\n",path(src,"test.ioc")); try write("test",path(src,"CMakeLists.txt"))
    var s = Settings(); s.root = path(temp,"总目录"); try fm.createDirectory(atPath:s.root,withIntermediateDirectories:true)
    s.project = try e.importProject(src,s)
    try expect(exists(path(src,"test.ioc")) && exists(path(s.project,"test.ioc")),"中文/空格路径导入，源文件保留")
    try rejects("同名工程不覆盖") { _ = try e.importProject(src,s) }
    try rejects("新建路径穿越") { _ = try e.create(root:s.root,series:s.series,name:"../oops") }
    try expect(e.targetFor(e.family(s.project)) == "target/stm32g4x.cfg","从 ioc 识别芯片目标")
    var wrong = s; wrong.series = "Fseries"; try rejects("错误系列被拒绝") { try e.validateSeries(wrong) }
    s.firmware = path(s.project,"固件 $foo[bar].elf"); try write("elf",s.firmware)
    let args = try e.flashArguments(s); try expect(args.last!.contains("\\$foo\\[bar\\]"),"OpenOCD 路径安全转义")
    s.probe = "CMSIS-DAP"; try expect(try e.flashArguments(s).contains("interface/cmsis-dap.cfg"),"CMSIS-DAP 参数")
    s.speed = "oops"; try rejects("无效 SWD 速度") { _ = try e.flashArguments(s) }; s.speed = "1000"
    s.target = "target/stm32f1x.cfg"; try rejects("芯片目标不匹配") { _ = try e.flashArguments(s) }
    try rejects("进程失败不能显示成功") { _ = try e.runner.run("/usr/bin/false",[]) }
    try rejects("缺失工具") { _ = try e.runner.run("/nonexistent",[]) }
    s.compiler = "/usr/bin/gcc"; try rejects("本机 GCC 不能编译 STM32") { try e.validateCompiler(s) }
    try e.backup(s.project); try expect(!children(path(s.project,".stm32studio/backups")).isEmpty,"生成前工程备份")
    let stopped = Runner(log:{_ in}); stopped.cancel(); try rejects("停止后不再启动进程") { _ = try stopped.run("/usr/bin/true",[]) }
    for group in SeriesCatalog.groups {
        try expect(SeriesCatalog.accepts(SeriesCatalog.examples[group]!,group),"新建型号识别：" + group)
        _ = try e.create(root:s.root,series:group,name:"FamilyTest")
    }
    for (family,target) in [("STM32H7","stm32h7x"),("STM32L4+","stm32l4x"),("STM32U5","stm32u5x"),("STM32WB","stm32wbx")] { try expect(e.targetFor(family) == "target/" + target + ".cfg","目标映射：" + family) }
    try expect(e.targetFor("STM32N6") == nil && e.targetFor("STM32H7RS") == nil,"特殊芯片不套用其他系列配置")
    var actual = Settings(); actual.discover()
    let catalog = DeviceCatalog.load(actual.cube)
    try expect(catalog.contains(where:{$0.name == "STM32F103C8Tx" && $0.family == "STM32F1"}),"CubeMX 数据库包含 F103C8")
    try expect(catalog.contains(where:{$0.name == "STM32G431RBTx" && $0.family == "STM32G4"}),"CubeMX 数据库包含 G431RB")
    try expect(catalog.allSatisfy{SeriesCatalog.group($0.family) != nil},"本机全部 MCU 型号可归入系列目录")
    try expect(!FirmwarePack.available(repository:actual.repository,family:"STM32F1").isEmpty,"现有 F1 固件包可用")
    try expect(!FirmwarePack.available(repository:actual.repository,family:"STM32G4").isEmpty,"现有 G4 固件包可用")
    try expect(FirmwarePack.available(repository:temp,family:"STM32F1").isEmpty,"缺失固件包不会显示已安装")
    actual.series = "Fseries"; actual.chipFamily = "STM32F1"; actual.chipModel = "STM32F103C8Tx"; actual.target = "target/stm32f1x.cfg"; actual.project = ""
    actual.firmware = path(temp,"firmware.bin"); try write("bin",actual.firmware)
    try expect(try e.flashArguments(actual).last!.hasSuffix(" 0x08000000"),"无工程也可生成 BIN 烧录命令，包含地址")
    actual.binaryAddress = "0x08000000;exit"; try rejects("BIN 地址拒绝命令注入") { _ = try e.flashArguments(actual) }; actual.binaryAddress = "0x08000000"
    try expect(try e.hardwareArguments(actual).contains(where:{$0.hasSuffix("stm32f1x.cfg")}),"F103 ST-Link 连接配置")
    try expect(e.targetFor("STM32H7",model:"STM32H7S3L8Hx") == nil,"H7RS 不沿用 H7 通用配置")
    let settingsFile = path(temp,"old-settings.json"); try write("{\"root\":\"/tmp/custom\"}",settingsFile)
    let migrated = Settings.load(settingsFile); try expect(migrated.root == "/tmp/custom" && !migrated.repository.isEmpty,"旧设置升级保留路径并补充新字段")
    let ports = SerialCatalog.scan(); try expect(ports.allSatisfy{$0.port.hasPrefix("/dev/cu.") || $0.port.hasPrefix("/dev/tty.")},"串口扫描仅返回 macOS 串口节点")
    print("MCU RECORDS: \(catalog.count)")
    print("SERIAL PORTS: \(ports.map{ $0.port + ": " + $0.detail })")
    try expect(miText("\"line\\nvalue\\t1\"") == "line\nvalue\t1","GDB MI 转义解析")
    try expect(miQuote("a\"b\\c") == "\"a\\\"b\\\\c\"","GDB MI 命令安全引用")
    let debug = DebugSession(); var noELF = actual; noELF.firmware = ""; debug.start(noELF)
    try expect(!debug.active && debug.status.contains("ELF"),"调试缺失 ELF 时不连接探针")
    noELF.gdb = "/missing/gdb"; debug.start(noELF)
    try expect(!debug.active && debug.status.contains("arm-none-eabi-gdb"),"调试缺失 GDB 时给出提示")
    let tracked = path(temp,"tracked.elf"); try write("first",tracked)
    let firstArtifact = try FirmwareArtifact.inspect(tracked); try write("second firmware",tracked)
    let secondArtifact = try FirmwareArtifact.inspect(tracked)
    try expect(firstArtifact.sha256 != secondArtifact.sha256 && firstArtifact.size != secondArtifact.size,"同一路径固件更新可通过摘要和大小识别")
    actual.firmware = tracked; actual.expectedFirmwareHash = firstArtifact.sha256
    try rejects("确认后固件改变，阻止烧录") { try e.flash(actual) }
    try write("bin",path(temp,"tracked.bin")); try write("hex",path(temp,"tracked.hex"))
    try expect(FirmwareArtifact.outputs(temp).contains(path(temp,"tracked.hex")) && FirmwareArtifact.outputs(temp).contains(path(temp,"tracked.bin")),"构建扫描覆盖 ELF / BIN / HEX")
    print("ALL TESTS PASSED")
}
