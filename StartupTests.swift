import Foundation

func runStartupTests() throws {
    let home = NSHomeDirectory()
    let roots = [NSTemporaryDirectory(), "/tmp"].map(canonical)
    guard ProcessInfo.processInfo.environment["SCMX_TEST_HOME"] == home,
          roots.contains(where:{ canonical(home).hasPrefix($0 + "/") }) else {
        throw StudioError("Startup tests require an isolated CFFIXED_USER_HOME and matching SCMX_TEST_HOME under a temporary directory.")
    }
    func expect(_ ok:Bool,_ label:String) throws {
        guard ok else { throw StudioError(label) }
        print("PASS: " + label)
    }
    let savedPath = path(home,"Library/Application Support/SCMXBuildWork/settings.json")
    let legacyPath = path(home,"Library/Application Support/STM32Studio/settings.json")
    guard !exists(savedPath), !exists(legacyPath) else { throw StudioError("Startup test home must be empty") }
    let root = path(home,"workspace"), project = path(root,"Fseries/UserProject")
    try fm.createDirectory(atPath:project,withIntermediateDirectories:true)
    try write("Mcu.Family=STM32F1\nMcu.UserName=STM32F103C8Tx\n",path(project,"UserProject.ioc"))
    let firmware = path(home,"selected-firmware.elf")
    try write("fixture",firmware)
    var saved = Settings()
    saved.root = root; saved.series = "Fseries"; saved.project = project
    saved.chipFamily = "STM32F1"; saved.chipModel = "STM32F103C8Tx"
    saved.target = path(home,"custom-target.cfg"); try write("# custom target fixture",saved.target)
    saved.firmware = firmware; saved.debugELF = firmware
    saved.outputDirectory = path(home,"chosen-output"); saved.followBuildOutputs = false
    let data = try JSONEncoder().encode(saved)
    try fm.createDirectory(atPath:URL(fileURLWithPath:legacyPath).deletingLastPathComponent().path,withIntermediateDirectories:true)
    try data.write(to:URL(fileURLWithPath:legacyPath))

    let fresh = Studio()
    try expect(fresh.settings.root.isEmpty && fresh.settings.series.isEmpty && fresh.settings.project.isEmpty,"First launch does not inherit a legacy workspace or select a project")
    try expect(fresh.settings.chipFamily.isEmpty && fresh.settings.chipModel.isEmpty && fresh.settings.target.isEmpty,"First launch leaves the device and target unselected")
    try expect(fresh.settings.firmware.isEmpty && fresh.settings.debugELF.isEmpty && fresh.settings.build.isEmpty,"First launch has no firmware or implicit build path")
    try expect(fresh.projects.isEmpty && fresh.artifact == nil,"First launch has no discovered project or firmware artifact")
    try expect(!exists(fresh.settings.repository),"First launch does not create a firmware repository")
    try expect(!fresh.canBuildProject,"Build shortcut is disabled before a project is selected")
    let beforeBuild = try Data(contentsOf:URL(fileURLWithPath:savedPath)), beforeLog = fresh.log
    fresh.compileCurrent()
    try expect(fresh.failed && !fresh.busy && fresh.log == beforeLog,"Building without a project is rejected before starting tools or queuing logs")
    try expect(try Data(contentsOf:URL(fileURLWithPath:savedPath)) == beforeBuild,"Rejected empty build never rewrites saved settings")
    fresh.settings.project = " \n "
    try expect(!fresh.canBuildProject,"Whitespace is not a selected project")
    fresh.settings.project = project
    try expect(fresh.canBuildProject,"Selected project enables the shared build action")
    fresh.busy = true
    try expect(!fresh.canBuildProject,"Busy operations disable both build shortcuts")
    fresh.busy = false; fresh.debug.active = true
    try expect(!fresh.canBuildProject,"Active debugging disables both build shortcuts")
    fresh.debug.active = false; fresh.settings.project = ""
    try expect(!navigationCatalog.contains(where:{$0.id == 6}) && !fresh.navigationItems.contains(where:{$0.id == 6}),"Sidebar and reorder defaults exclude experimental code organization")
    fresh.settings.navigationOrder = [6,3,5,0,4,1,2]
    try expect(fresh.navigationItems.map(\.id) == [3,5,0,4,1,2],"Legacy sidebar order cannot restore the hidden experimental module")
    try expect(fresh.settings.navigationOrder == [6,3,5,0,4,1,2],"Filtering hidden navigation leaves saved custom order intact")
    fresh.reloadCatalog()
    try expect(fresh.settings.chipModel.isEmpty && fresh.settings.chipFamily.isEmpty,"Reloading catalogs never selects the first MCU")

    var workspaceOnly = Settings(); workspaceOnly.root = root; workspaceOnly.series = "Fseries"
    try JSONEncoder().encode(workspaceOnly).write(to:URL(fileURLWithPath:savedPath))
    let unselected = Studio()
    try expect(unselected.projects.contains(project) && unselected.settings.project.isEmpty,"Existing workspace projects are listed but never selected automatically")
    try expect(unselected.settings.chipFamily.isEmpty && unselected.settings.chipModel.isEmpty,"Listing a project does not apply its MCU")

    try data.write(to:URL(fileURLWithPath:savedPath))
    let restored = Studio()
    try expect(restored.settings.project == project && restored.settings.root == root,"Explicitly saved current-app workspace is restored")
    try expect(restored.settings.target == saved.target,"Explicit custom OpenOCD target survives relaunch")
    try expect(restored.settings.firmware == firmware && restored.settings.debugELF == firmware && restored.settings.outputDirectory == saved.outputDirectory,"Explicit firmware, debug ELF, and output selections survive relaunch")
    try expect(!restored.settings.followBuildOutputs,"Manual firmware tracking preference survives relaunch")
    var crossSeries = saved
    crossSeries.series = "Gseries"; crossSeries.chipFamily = "STM32G4"; crossSeries.chipModel = "STM32G431RBTx"; crossSeries.target = ""
    try JSONEncoder().encode(crossSeries).write(to:URL(fileURLWithPath:savedPath))
    let switched = Studio()
    try expect(switched.settings.project == project && switched.settings.firmware == firmware && switched.settings.outputDirectory == saved.outputDirectory,"A different selected MCU family does not discard the saved project or firmware on relaunch")
    try expect(switched.projects.contains(project),"Explicit saved project remains selectable outside the current series filter")
    restored.settings.chipFamily = "STM32G4"; restored.selectFamily(updateSeries:true)
    try expect(restored.settings.chipModel.isEmpty && restored.settings.target.isEmpty,"Changing family clears the incompatible MCU without selecting another")
    let repository = restored.settings.repository, compiler = restored.settings.compiler
    restored.clearWorkspaceSelection()
    try expect(restored.settings.root.isEmpty && restored.settings.project.isEmpty && restored.settings.chipModel.isEmpty && restored.settings.series.isEmpty,"Clear Selection returns to an empty workspace and device")
    try expect(restored.settings.repository == repository && restored.settings.compiler == compiler,"Clear Selection keeps tool paths and the repository preference")
    try expect(exists(path(project,"UserProject.ioc")) && exists(firmware),"Clear Selection never deletes project or firmware files")
    try expect(try Data(contentsOf:URL(fileURLWithPath:legacyPath)) == data,"Legacy app settings remain untouched")
    print("STARTUP TESTS PASSED")
}
