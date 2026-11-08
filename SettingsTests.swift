import Foundation

func runSettingsTests() throws {
    let folder = path(NSTemporaryDirectory(),"workbench-settings-test-" + UUID().uuidString)
    try fm.createDirectory(atPath:folder,withIntermediateDirectories:true)
    defer { try? fm.removeItem(atPath:folder) }
    func expect(_ condition:Bool,_ label:String) throws {
        guard condition else { throw StudioError(label) }
        print("PASS: " + label)
    }
    func rejects(_ label:String,_ operation:() throws -> Void) throws {
        do { try operation() } catch let error as StudioError {
            try expect(!error.message.isEmpty,label)
            return
        }
        throw StudioError("Expected rejection: " + label)
    }
    let selections:[KeyPath<Settings,String>] = [\.root,\.series,\.project,\.target,\.chipFamily,\.chipModel,\.outputDirectory]
    func expectEmpty(_ settings:Settings,_ label:String) throws {
        try expect(selections.allSatisfy { settings[keyPath:$0].isEmpty },label)
        try expect(settings.build.isEmpty,label + " has no implicit build directory")
    }
    let defaults = Settings()
    try expectEmpty(defaults,"New settings have no project or device selection")
    let missing = path(folder,"missing.json")
    try expectEmpty(Settings.load(missing),"Missing settings file keeps selections empty")
    try expect(!exists(missing),"Loading missing settings does not create a file")
    let empty = path(folder,"empty.json")
    try write("{}",empty)
    try expectEmpty(Settings.load(empty),"Empty saved settings keep selections empty")
    try expect(defaults.repository == path(NSHomeDirectory(),"STM32Cube/Repository"),"Default firmware repository is retained")
    try expect(defaults.probe == "ST-Link" && defaults.configuration == "Debug" && defaults.speed == "1000" && defaults.programmerTransport == "SWD", "Non-device defaults are retained")
    var discovered = defaults
    discovered.cmake = "/usr/bin/true"
    discovered.discover()
    try expectEmpty(discovered,"Tool discovery does not select a project or device")
    try expect(discovered.cmake == "/usr/bin/true" && discovered.repository == defaults.repository,"Tool discovery retains explicit executable and repository paths")

    let legacy = path(folder,"legacy.json")
    let saved:[String:String] = ["root":path(folder,"saved root"), "series":"Fseries",
        "project":path(folder,"saved project"), "target":"target/stm32f1x.cfg",
        "chipFamily":"STM32F1", "chipModel":"STM32F103C8Tx",
        "outputDirectory":path(folder,"saved output"), "compiler":"/saved/arm-none-eabi-gcc",
        "toolchain":"/saved/toolchain.cmake", "repository":"/saved/firmware repository"]
    let data = try JSONSerialization.data(withJSONObject:saved,options:.sortedKeys)
    try data.write(to:URL(fileURLWithPath:legacy))
    let restored = Settings.load(legacy)
    let encoded = try JSONEncoder().encode(restored)
    guard let values = try JSONSerialization.jsonObject(with:encoded) as? [String:Any] else {
        throw StudioError("Settings did not encode as a JSON object")
    }
    for (key,value) in saved { try expect(values[key] as? String == value,"Saved " + key + " is preserved") }
    try expect(restored.build == saved["outputDirectory"],"Explicit output directory is preserved")
    try expect(restored.programmerBackend == defaults.programmerBackend && restored.followBuildOutputs == defaults.followBuildOutputs && restored.backupLength == defaults.backupLength && restored.navigationOrder == defaults.navigationOrder,"Loading older settings fills missing newer fields")
    try expect(try Data(contentsOf:URL(fileURLWithPath:legacy)) == data,"Loading never rewrites saved settings")
    let partial = path(folder,"partial.json")
    try write("{\"root\":\"/saved/root\"}",partial)
    let partialSettings = Settings.load(partial)
    try expect(partialSettings.root == "/saved/root" && partialSettings.series.isEmpty && partialSettings.chipModel.isEmpty && partialSettings.target.isEmpty && partialSettings.build.isEmpty,"Partial old settings preserve explicit values without inventing a device")
    var outputOnly = defaults; outputOnly.outputDirectory = path(folder,"explicit output")
    try expect(outputOnly.build == outputOnly.outputDirectory,"Explicit output works without a selected project")
    var projectOnly = defaults; projectOnly.project = path(folder,"selected project")
    try expect(projectOnly.build == path(projectOnly.project,"build/STM32Studio-Debug"),"Selected project gets its normal build directory")
    projectOnly.configuration = "Release"
    try expect(projectOnly.build == path(projectOnly.project,"build/STM32Studio-Release"),"Selected project keeps configuration-specific build paths")

    // A plausible project in cwd must never stand in for an empty selection.
    let cwd = path(folder,"cwd")
    try fm.createDirectory(atPath:path(cwd,"Core/Src"),withIntermediateDirectories:true)
    try fm.createDirectory(atPath:path(cwd,"cmake"),withIntermediateDirectories:true)
    try write("Mcu.Family=STM32G4\n",path(cwd,"decoy.ioc"))
    try write("project(Decoy)\n",path(cwd,"CMakeLists.txt"))
    try write("set(CMAKE_C_COMPILER                ${TOOLCHAIN_PREFIX}gcc)\n",path(cwd,"cmake/gcc-arm-none-eabi.cmake"))
    try write("int value;\n",path(cwd,"Core/Src/bsp_value.c"))
    try write("decoy",path(cwd,"decoy.elf"))
    let previous = fm.currentDirectoryPath
    guard fm.changeCurrentDirectoryPath(cwd) else { throw StudioError("Could not enter settings test directory") }
    defer { _ = fm.changeCurrentDirectoryPath(previous) }
    let names = (fm.enumerator(atPath:cwd)?.allObjects as? [String] ?? []).sorted()
    let files = try names.filter { (try fm.attributesOfItem(atPath:path(cwd,$0)))[.type] as? FileAttributeType == .typeRegular }
    let contents = try files.map { try Data(contentsOf:URL(fileURLWithPath:path(cwd,$0))) }
    var messages = ""
    let engine = Engine(runner:Runner(log:{ messages += $0 }))
    try expect(defaults.build.isEmpty,"Empty build stays empty even inside a project directory")
    try expect(engine.family("").isEmpty && engine.firmwareFiles("").isEmpty,"Empty paths do not discover cwd projects or firmware")
    try expect(engine.openocdFile("",defaults) == nil,"Empty target cannot resolve to a scripts directory")
    let operations:[(String,() throws -> Void)] = [
        ("Read IOC", { _ = try engine.ioc("") }),
        ("Normalize toolchain", { try engine.normalizeToolchain("") }),
        ("Backup", { try engine.backup("") }),
        ("Organize project", { try engine.organizeProject(defaults) }),
        ("Organize user files", { try engine.organizeUserFiles(defaults) }),
        ("Synchronize user CMake", { try engine.synchronizeUserCMake(defaults,prefixes:["bsp"]) }),
        ("Configure editor", { try engine.configureEditor(defaults) }),
        ("Configure build", { try engine.configureBuild(defaults) }),
        ("Build", { _ = try engine.build(defaults) }),
        ("Generate", { try engine.generate(defaults) }),
        ("Hardware arguments", { _ = try engine.hardwareArguments(defaults) }),
        ("Flash arguments", { _ = try engine.flashArguments(defaults) })
    ]
    for (label,operation) in operations { try rejects(label + " rejects an empty selection",operation) }
    var offlineOnly = defaults
    offlineOnly.project = cwd; offlineOnly.series = "Gseries"; offlineOnly.chipFamily = "STM32G4"; offlineOnly.chipModel = "STM32G431RBTx"
    try rejects("Bundled register models never authorize CubeMX generation without its own record") { try engine.generate(offlineOnly,mcu:offlineOnly.chipModel) }
    var importSettings = defaults; importSettings.root = folder; importSettings.series = "Gseries"
    try rejects("Import rejects an empty source rather than copying cwd") { _ = try engine.importProject("",importSettings) }
    try rejects("An output directory alone cannot authorize configuration") { try engine.configureBuild(outputOnly) }
    var incomplete = defaults
    incomplete.series = "Gseries"; incomplete.chipModel = "STM32G431RBTx"; incomplete.target = path(cwd,"target.cfg")
    try write("# test target\n",incomplete.target)
    try rejects("Hardware arguments require an explicit family") { _ = try engine.hardwareArguments(incomplete) }
    try rejects("Flash arguments require an explicit family") { _ = try engine.flashArguments(incomplete) }
    incomplete.chipFamily = "STM32G4"; incomplete.series = ""
    try rejects("Hardware arguments require an explicit series") { _ = try engine.hardwareArguments(incomplete) }
    try fm.removeItem(atPath:incomplete.target)
    try expect((fm.enumerator(atPath:cwd)?.allObjects as? [String] ?? []).sorted() == names,"Rejected empty selections leave cwd entries unchanged")
    for (index,file) in files.enumerated() {
        try expect(try Data(contentsOf:URL(fileURLWithPath:path(cwd,file))) == contents[index],"Rejected empty selections preserve " + file)
    }
    try expect(!exists(outputOnly.outputDirectory) && messages.isEmpty,"Empty selections neither create build output nor execute tools")
    print("SETTINGS TESTS PASSED")
}
