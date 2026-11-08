import Foundation
import CryptoKit

private struct RegisterDatabaseTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private func registerTestExpect(_ condition: Bool, _ label: String) throws {
    guard condition else { throw RegisterDatabaseTestFailure(message:"Register test failed: " + label) }
    print("PASS: Registers " + label)
}

private enum RegisterTestRejection { case invalid, unsupported, any }

private func registerTestReject(_ label: String, kind: RegisterTestRejection = .invalid,
                                _ action: () throws -> Void) throws {
    do { try action() }
    catch {
        let matches: Bool
        switch (kind,error) {
        case (.any,_), (.invalid,RegisterDatabaseError.invalid), (.unsupported,RegisterDatabaseError.unsupported(_)):
            matches = true
        default: matches = false
        }
        guard matches else { throw RegisterDatabaseTestFailure(message:"\(label): unexpected error \(error)") }
        print("PASS: Registers " + label)
        return
    }
    throw RegisterDatabaseTestFailure(message:"\(label): expected rejection, received success")
}

private func registerTestRow(_ group: String, _ instance: String, _ name: String,
                             _ address: UInt64, size: Int = 32, access: String = "read-write",
                             readAction: String? = nil) -> [String:Any] {
    var row: [String:Any] = ["group":group,"instance":instance,"name":name,"address":address,
                             "size":size,"access":access,"description":"Fixture " + instance + "." + name]
    if let readAction { row["readAction"] = readAction }
    return row
}

private struct RegisterDatabaseFixture {
    var schema = 1
    var devices: [[String:Any]] = []
    var profiles: [[String:Any]] = []
    var storage = Data()

    mutating func addProfile(_ id: String, rows: [[String:Any]]) throws {
        let name = "Fixture " + id
        let data = try JSONSerialization.data(withJSONObject:["name":name,"registers":rows],options:.sortedKeys)
        let compressed = try (data as NSData).compressed(using:.lzfse) as Data
        profiles.append(["id":id,"name":name,"source":"fixture/\(id).svd","license":"MIT",
                         "offset":storage.count,"length":compressed.count,"uncompressedLength":data.count,
                         "sha256":SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined(),
                         "registerCount":rows.count])
        storage.append(compressed)
    }

    mutating func addDevice(_ name: String, family: String, profiles choices: [(String,String)]) {
        devices.append(["name":name,"family":family,"profiles":choices.map { ["id":$0.0,"core":$0.1] }])
    }

    func database() throws -> RegisterDatabase {
        let indexData = try JSONSerialization.data(withJSONObject:["schema":schema,"devices":devices,"profiles":profiles],options:.sortedKeys)
        return try RegisterDatabase(indexData:indexData,storage:storage)
    }

    static func standard() throws -> RegisterDatabaseFixture {
        var fixture = RegisterDatabaseFixture()
        try fixture.addProfile("g431",rows:[
            registerTestRow("TEST","TEST1","BYTE",0x40000001,size:8,access:"read-only"),
            registerTestRow("TEST","TEST1","HALF",0x40000002,size:16),
            registerTestRow("TEST","TEST1","WORD",0x40000004),
            registerTestRow("TEST","TEST1","DOUBLE",0x40000008,size:64),
            registerTestRow("TEST","TEST1","UNALIGNED",0x40000013),
            registerTestRow("TEST","TEST1","WIDTH24",0x40000020,size:24),
            registerTestRow("TEST","TEST1","UNKNOWN_ACCESS",0x40000024,access:"unknown"),
            registerTestRow("TEST","TEST1","WRITE_ONCE",0x40000028,access:"writeOnce"),
            registerTestRow("TEST","TEST1","READ_WRITE_ONCE",0x4000002c,access:"read-writeOnce"),
            registerTestRow("GPIO","GPIOA","ODR",0x48000014),
            // The generator has already expanded GPIOB's derived register and relocated its base.
            registerTestRow("GPIO","GPIOB","ODR",0x48000414),
            registerTestRow("GPIO","GPIOA","BSRR",0x48000018,access:"write-only"),
            registerTestRow("I2C","I2C1","CR1",0x40005400),
            registerTestRow("I2C","I2C1","I2C1_RXDR",0x40005424,access:"read-only"),
            registerTestRow("USART","USART1","ISR",0x4001381c,access:"read-only",readAction:"clear")
        ])
        try fixture.addProfile("f103",rows:[registerTestRow("GPIO","GPIOA","ODR",0x4001080c)])
        try fixture.addProfile("g474",rows:[registerTestRow("GPIO","GPIOA","ODR",0x48000014)])
        try fixture.addProfile("h745-m7",rows:[registerTestRow("TEST","CORE7","ID",0x58020000)])
        try fixture.addProfile("h745-m4",rows:[registerTestRow("TEST","CORE4","ID",0x50020000)])
        try fixture.addProfile("g071",rows:[registerTestRow("GPIO","GPIOA","ODR",0x50000014)])
        fixture.addDevice("STM32G431RBTx",family:"STM32G4",profiles:[("g431","CM4")])
        fixture.addDevice("STM32G431CBTx",family:"STM32G4",profiles:[("g431","CM4")])
        fixture.addDevice("STM32F103C8",family:"STM32F1",profiles:[("f103","CM3")])
        fixture.addDevice("STM32G474RETx",family:"STM32G4",profiles:[("g474","CM4")])
        fixture.addDevice("STM32H745ZITx",family:"STM32H7",profiles:[("h745-m7","CM7"),("h745-m4","CM4")])
        fixture.addDevice("STM32G071RBTx",family:"STM32G0",profiles:[("g071","CM0+")])
        return fixture
    }
}

private func registerTestFind(_ snapshot: RegisterSnapshot, _ name: String) throws -> RegisterDefinition {
    let matches = snapshot.registers.filter { $0.name == name }
    guard matches.count == 1, let row = matches.first else {
        throw RegisterDatabaseTestFailure(message:"\(snapshot.model): expected one \(name), found \(matches.count)")
    }
    return row
}

func runRegisterDatabaseTests() throws {
    let fixture = try RegisterDatabaseFixture.standard()
    let database = try fixture.database()
    try database.validateAllProfiles()
    try registerTestExpect(database.allProfiles.count == 6 && database.devices.count == 6,"fixture index and all LZFSE profiles validate")
    let g431 = try database.snapshot(family:"STM32G4",model:"STM32G431RBTx")
    for (name,command) in [("BYTE","x/bx 0x40000001"),("HALF","x/hx 0x40000002"),
                           ("WORD","x/wx 0x40000004"),("DOUBLE","x/gx 0x40000008")] {
        let row = try registerTestFind(g431,"TEST1_" + name)
        try registerTestExpect(row.canRead && row.readCommand == command,"\(row.size)-bit read command uses the exact address")
    }
    for name in ["GPIOA_BSRR","TEST1_WRITE_ONCE","TEST1_UNALIGNED","TEST1_WIDTH24","TEST1_UNKNOWN_ACCESS"] {
        let row = try registerTestFind(g431,name)
        try registerTestExpect(!row.canRead && row.readCommand == nil,"\(name) never produces a read command")
    }
    try registerTestExpect(try registerTestFind(g431,"TEST1_READ_WRITE_ONCE").canRead,"read-writeOnce permits reading")
    let action = try registerTestFind(g431,"USART1_ISR")
    try registerTestExpect(action.readAction == "clear" && action.access == "read-only","readAction is preserved for side-effect warnings")
    try registerTestExpect(try registerTestFind(g431,"GPIOA_ODR").readAction == nil,"absent readAction remains nil")
    let i2c = try registerTestFind(g431,"I2C1_CR1")
    try registerTestExpect(i2c.instance == "I2C1" && i2c.peripheral == "I2C" && i2c.addressValue == 0x40005400,"I2C1 instance is not truncated to I2")
    try registerTestExpect(try registerTestFind(g431,"I2C1_RXDR").name == "I2C1_RXDR","prefixed register name is not prefixed twice")
    let gpioA = try registerTestFind(g431,"GPIOA_ODR"), gpioB = try registerTestFind(g431,"GPIOB_ODR")
    try registerTestExpect(gpioA.addressValue == 0x48000014 && gpioB.addressValue == 0x48000414 && gpioA.id != gpioB.id,"expanded GPIOB retains its distinct instance and relocated address")

    let f103 = try database.snapshot(family:"STM32F1",model:"STM32F103C8Tx")
    try registerTestExpect(f103.profile.id == "f103" && f103.model == "STM32F103C8Tx","old-pack STM32F103C8 accepts the package suffix Tx")
    try registerTestExpect(try database.snapshot(family:"STM32F1",model:"STM32F103C8").profile.id == "f103","old-pack exact model matches")
    try registerTestExpect(try database.snapshot(family:"STM32G4",model:"STM32G474RETx").profile.id == "g474","another model in the same family selects its own profile")
    try registerTestExpect(try database.snapshot(family:"stm32g4",model:"stm32g431rbt6").profile.id == "g431","x wildcard and case normalization match a concrete model")
    for (family,model) in [("STM32F1","STM32G431RBTx"),("STM32G4","STM32F103C8Tx"),
                           ("STM32G0","STM32G431RBTx"),("STM32G4","STM32G499RBTx"),
                           ("STM32F1","STM32F103C9Tx"),("STM32F4","STM32F407VGTx"),
                           ("STM32G4","STM32G431RBT"),("STM32G4","STM32G431RBT66"),
                           ("STM32G4","STM32G431RBT!"),("STM32F1","STM32F103C8T666"),
                           ("","STM32G431RBTx"),("STM32G4","")] {
        try registerTestExpect(database.choices(family:family,model:model).isEmpty,"no choices for unmatched \(family)/\(model)")
        try registerTestReject("unmatched \(family)/\(model) has no F1/G4 fallback",kind:.unsupported) {
            _ = try database.snapshot(family:family,model:model)
        }
    }
    var ambiguous = fixture
    ambiguous.addDevice("STM32G431RBxx",family:"STM32G4",profiles:[("g474","CM4")])
    let ambiguousDatabase = try ambiguous.database()
    try registerTestReject("equally specific conflicting wildcard matches are rejected",kind:.unsupported) {
        _ = try ambiguousDatabase.snapshot(family:"STM32G4",model:"STM32G431RBT6")
    }
    let choices = database.choices(family:"STM32H7",model:"STM32H745ZITx")
    try registerTestExpect(choices.map(\.id) == ["h745-m7","h745-m4"] && choices.map(\.core) == ["CM7","CM4"],"multicore choices preserve profile IDs and core labels")
    let m7 = try database.snapshot(family:"STM32H7",model:"STM32H745ZITx")
    let m4 = try database.snapshot(family:"STM32H7",model:"STM32H745ZITx",profileID:"h745-m4")
    try registerTestExpect(m7.profile.id == "h745-m7" && m4.profile.id == "h745-m4" && m7.registers.first?.addressValue == 0x58020000 && m4.registers.first?.addressValue == 0x50020000,"profileID switches the multicore payload")
    for id in ["f103","missing"] {
        try registerTestReject("profile \(id) cannot bypass the selected model",kind:.unsupported) {
            _ = try database.snapshot(family:"STM32H7",model:"STM32H745ZITx",profileID:id)
        }
    }

    let badFields: [(String,Any)] = [("offset",-1),("offset",fixture.storage.count + 1),("offset",Int.max),
                                    ("length",0),("length",-1),("length",fixture.storage.count + 1),("length",Int.max),
                                    ("uncompressedLength",0),("uncompressedLength",64_000_001),
                                    ("registerCount",0),("sha256","not-a-sha256")]
    for (key,value) in badFields {
        var invalid = fixture; invalid.profiles[0][key] = value
        try registerTestReject("invalid profile \(key)=\(value)") { _ = try invalid.database() }
    }
    var duplicateDevice = fixture; duplicateDevice.devices.append(fixture.devices[0])
    try registerTestReject("duplicate device names") { _ = try duplicateDevice.database() }
    var caseDuplicate = fixture
    caseDuplicate.addDevice("STM32G431RBTX",family:"STM32G4",profiles:[("g431","CM4")])
    try registerTestReject("case-insensitive duplicate device names") { _ = try caseDuplicate.database() }
    var duplicateProfile = fixture; duplicateProfile.profiles.append(fixture.profiles[0])
    try registerTestReject("duplicate profile IDs") { _ = try duplicateProfile.database() }
    var missingProfile = fixture; missingProfile.devices[0]["profiles"] = [["id":"absent","core":"CM4"]]
    try registerTestReject("device references a missing profile") { _ = try missingProfile.database() }
    var emptyChoices = fixture; emptyChoices.devices[0]["profiles"] = [[String:String]]()
    try registerTestReject("device has no profile") { _ = try emptyChoices.database() }
    var duplicateChoice = fixture
    duplicateChoice.devices[0]["profiles"] = [["id":"g431","core":"CM4"],["id":"g431","core":"CM4"]]
    try registerTestReject("device repeats a profile ID") { _ = try duplicateChoice.database() }

    let originalLength = fixture.profiles[0]["uncompressedLength"] as! Int
    let originalCount = fixture.profiles[0]["registerCount"] as! Int
    for (key,value) in [("sha256",String(repeating:"0",count:64) as Any),
                        ("uncompressedLength",originalLength + 1 as Any),
                        ("registerCount",originalCount + 1 as Any),("name","Wrong payload" as Any)] {
        var corrupt = fixture; corrupt.profiles[0][key] = value
        let corruptDatabase = try corrupt.database()
        try registerTestReject("lazy payload validation rejects corrupt \(key)") {
            _ = try corruptDatabase.snapshot(family:"STM32G4",model:"STM32G431RBTx")
        }
        try registerTestReject("validateAllProfiles rejects corrupt \(key)") { try corruptDatabase.validateAllProfiles() }
    }
    let compressedLength = fixture.profiles[0]["length"] as! Int
    var brokenLZFSE = fixture
    brokenLZFSE.storage.replaceSubrange(0..<compressedLength,with:Data(repeating:0,count:compressedLength))
    let brokenDatabase = try brokenLZFSE.database()
    try registerTestReject("corrupt LZFSE bytes fail instead of returning registers",kind:.any) {
        _ = try brokenDatabase.snapshot(family:"STM32G4",model:"STM32G431RBTx")
    }
    var truncated = fixture; truncated.profiles[0]["length"] = compressedLength - 1
    let truncatedDatabase = try truncated.database()
    try registerTestReject("truncated compressed length fails validation",kind:.any) { try truncatedDatabase.validateAllProfiles() }

    var h7rs = fixture
    h7rs.addDevice("STM32H7S3L8Hx",family:"STM32H7RS",profiles:[("h745-m7","CM7")])
    h7rs.addDevice("STM32H7R3L8Hx",family:"STM32H7RS",profiles:[("h745-m7","CM7")])
    let h7rsDatabase = try h7rs.database()
    for model in ["STM32H7S3L8Hx","STM32H7R3L8Hx"] {
        try registerTestExpect(try h7rsDatabase.snapshot(family:"STM32H7RS",model:model).model == model,"H7RS family accepts its explicitly mapped R/S device")
    }
    let probe = RegisterDatabaseCacheProbe(database:try fixture.database())
    DispatchQueue.concurrentPerform(iterations:64) { index in probe.read(index % 2) }
    DispatchQueue.concurrentPerform(iterations:192) { index in probe.read(index % probe.requests.count) }
    for index in probe.requests.indices { probe.read(index) }
    try registerTestExpect(probe.failures.isEmpty,"concurrent cold-cache reads, aliases and six-profile eviction: " + probe.failures.joined(separator:"; "))
    print("PASS: all RegisterDatabase fixture tests")
}

// Only the database's synchronized payload cache is shared; failure recording has its own lock.
private final class RegisterDatabaseCacheProbe: @unchecked Sendable {
    let database: RegisterDatabase
    let requests: [(family:String,model:String,id:String,address:UInt64)] = [
        ("STM32G4","STM32G431RBTx","g431",0x40000001),
        ("STM32G4","STM32G431CBT6","g431",0x40000001),
        ("STM32F1","STM32F103C8Tx","f103",0x4001080c),
        ("STM32G4","STM32G474RETx","g474",0x48000014),
        ("STM32H7","STM32H745ZITx","h745-m7",0x58020000),
        ("STM32H7","STM32H745ZITx","h745-m4",0x50020000),
        ("STM32G0","STM32G071RBTx","g071",0x50000014)
    ]
    private let lock = NSLock()
    private var errors: [String] = []
    init(database: RegisterDatabase) { self.database = database }
    var failures: [String] { lock.lock(); defer { lock.unlock() }; return errors }
    func read(_ index: Int) {
        let request = requests[index]
        do {
            let snapshot = try database.snapshot(family:request.family,model:request.model,profileID:request.id)
            guard snapshot.profile.id == request.id, snapshot.model == request.model,
                  snapshot.registers.first?.addressValue == request.address,
                  snapshot.registers.count == snapshot.profile.registerCount,
                  snapshot.registers.allSatisfy({ $0.model == request.model }) else {
                throw RegisterDatabaseTestFailure(message:"cached payload/model mismatch: \(request.model)/\(request.id)")
            }
        } catch { lock.lock(); errors.append(String(describing:error)); lock.unlock() }
    }
}

func runBundledRegisterTests() throws {
    try RegisterCatalog.validateAllProfiles()
    try registerTestExpect(!RegisterCatalog.allProfiles.isEmpty && !RegisterCatalog.devices.isEmpty,"bundled index and every payload validate")
    try registerTestExpect(RegisterCatalog.devices.allSatisfy({!$0.fromCubeMX}) && DeviceCatalog.cubeRecords("").isEmpty,"offline register models are not CubeMX generation records")
    let f1 = try RegisterCatalog.snapshot(family:"STM32F1",model:"STM32F103C8Tx")
    let g4 = try RegisterCatalog.snapshot(family:"STM32G4",model:"STM32G431RBTx")
    try registerTestExpect(try registerTestFind(f1,"GPIOA_ODR").addressValue == 0x4001080c,"bundled F103C8Tx GPIOA_ODR is 0x4001080C")
    try registerTestExpect(try registerTestFind(g4,"GPIOA_ODR").addressValue == 0x48000014,"bundled G431RBTx GPIOA_ODR is 0x48000014")
    try registerTestExpect(try registerTestFind(g4,"SPI1_DR").addressValue == 0x4001300c,"bundled G431 SPI1_DR is 0x4001300C")
    let misplaced = g4.registers.filter { row in
        row.instance == "SPI1" && ["CFG1","TXDR"].contains { name in
            row.registerName == name || row.registerName.hasSuffix("_" + name)
        }
    }
    try registerTestExpect(misplaced.isEmpty,"bundled G431 SPI1 has no foreign CFG1/TXDR registers")

    // Ignore model tags and profile IDs: a renamed F1/G4 fallback must still fail this comparison.
    func layout(_ snapshot: RegisterSnapshot) -> Set<String> {
        Set(snapshot.registers.map { "\($0.instance)|\($0.registerName)|\($0.addressValue)|\($0.size)|\($0.access)" })
    }
    let f1Layout = layout(f1), g4Layout = layout(g4)
    for (family,model) in [("STM32F4","STM32F407VGTx"),("STM32H7","STM32H743ZITx"),
                           ("STM32L4","STM32L476RGTx"),("STM32U5","STM32U575ZITx"),
                           ("STM32G0","STM32G071RBTx")] {
        let snapshot = try RegisterCatalog.snapshot(family:family,model:model)
        let registers = layout(snapshot)
        try registerTestExpect(!registers.isEmpty && registers != f1Layout && registers != g4Layout,
                               "bundled \(model) is nonempty and is neither an F1 nor a G4 fallback")
    }
    print("PASS: all bundled register tests (\(RegisterCatalog.allProfiles.count) profiles)")
}
