import Foundation

struct MCURecord: Hashable {
    let name: String; let family: String; let package: String; let databaseName:String
    let fromCubeMX: Bool
    init(name:String,family:String,package:String,databaseName:String,fromCubeMX:Bool = true) {
        self.name = name; self.family = family; self.package = package; self.databaseName = databaseName; self.fromCubeMX = fromCubeMX
    }
}
final class MCUParser: NSObject, XMLParserDelegate {
    var family = "", records:[MCURecord] = []
    func parser(_ parser:XMLParser,didStartElement elementName:String,namespaceURI:String?,qualifiedName:String?,attributes:[String:String]) {
        if elementName == "Family" { family = attributes["Name"] ?? "" }
        if elementName == "Mcu", let name = attributes["RefName"], !name.isEmpty { records.append(MCURecord(name:name,family:family,package:attributes["PackageName"] ?? "",databaseName:attributes["Name"] ?? name)) }
    }
}
struct FirmwarePack {
    let folder:String
    var name:String { URL(fileURLWithPath:folder).lastPathComponent }
    static func available(repository:String,family:String) -> [FirmwarePack] {
        // L4+ shares STM32CubeL4. Other series keep exact package identities.
        let key = family.replacingOccurrences(of:"STM32",with:"").replacingOccurrences(of:"+",with:"")
        guard !key.isEmpty else { return [] }
        return children(repository).filter { $0.hasPrefix("STM32Cube_FW_" + key + "_V") }.map { FirmwarePack(folder:path(repository,$0)) }.filter { exists(path($0.folder,"package.xml")) && exists(path($0.folder,"Drivers")) }.sorted { $0.name.compare($1.name,options:.numeric) == .orderedDescending }
    }
    static func downloadURL(_ family:String) -> URL {
        let key = family.replacingOccurrences(of:"STM32",with:"").replacingOccurrences(of:"+",with:"").lowercased()
        if key.hasPrefix("mp") { return URL(string:"https://www.st.com/en/embedded-software/stm32-mpu-embedded-software.html")! }
        return URL(string:"https://www.st.com/en/embedded-software/stm32cube" + key + ".html")!
    }
}
struct DeviceCatalog {
    static func load(_ cube:String) -> [MCURecord] {
        let local = cubeRecords(cube)
        var records = Dictionary(local.map { ($0.name.uppercased(),$0) },uniquingKeysWith:{first,_ in first})
        let localNames = Array(records.keys)
        for device in RegisterCatalog.devices where records[device.name.uppercased()] == nil {
            let name = device.name.uppercased()
            if !name.contains("X"), (11...13).contains(name.count), localNames.contains(where:{$0.hasPrefix(name) && $0.count <= name.count + 3}) { continue }
            records[name] = device
        }
        return records.values.sorted { $0.name < $1.name }
    }
    static func cubeRecords(_ cube:String) -> [MCURecord] {
        guard !cube.isEmpty else { return [] }
        let base = URL(fileURLWithPath:cube).deletingLastPathComponent().path
        for p in [path(base,"db/mcu/families.xml"),path(base,"../Resources/db/mcu/families.xml")] {
            if let parser = XMLParser(contentsOf:URL(fileURLWithPath:p)) { let delegate = MCUParser(); parser.delegate = delegate; if parser.parse() { return Array(Set(delegate.records)).sorted{$0.name < $1.name} } }
        }
        return []
    }
    static func iocValue(_ key:String,_ project:String) -> String {
        guard !project.isEmpty else { return "" }
        guard let file = children(project).first(where:{$0.hasSuffix(".ioc")}) else { return "" }
        return read(path(project,file)).components(separatedBy:.newlines).first{$0.hasPrefix(key + "=")}?.dropFirst(key.count+1).trimmingCharacters(in:.whitespacesAndNewlines) ?? ""
    }
}

struct SerialDevice: Hashable { let port:String; let detail:String }
struct SerialCatalog {
    static func scan() -> [SerialDevice] {
        let paths = children("/dev").filter{$0.hasPrefix("cu.") || $0.hasPrefix("tty.")}.sorted().map{"/dev/" + $0}
        var descriptions:[String:String] = [:]
        let process = Process(), pipe = Pipe(); process.executableURL = URL(fileURLWithPath:"/usr/sbin/ioreg"); process.arguments = ["-r","-c","IOUSBHostDevice","-a"]; process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        if (try? process.run()) != nil {
            let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
            if let list = try? PropertyListSerialization.propertyList(from:data,format:nil) as? [[String:Any]] {
                func visit(_ node:[String:Any], inherited:String = "") {
                    let usb = [node["USB Vendor Name"] as? String,node["USB Product Name"] as? String].compactMap{$0}.joined(separator:" ")
                    let inherited = usb.isEmpty ? inherited : usb
                    let detail = [node["IOTTYDevice"] as? String,node["IOTTYBaseName"] as? String,node["USB Product Name"] as? String,node["IORegistryEntryName"] as? String].compactMap{$0}.filter{!$0.isEmpty}.joined(separator:" · ") + (inherited.isEmpty ? "" : " · " + inherited)
                    for key in ["IOCalloutDevice","IODialinDevice"] { if let p = node[key] as? String { descriptions[p] = detail } }
                    for child in node["IORegistryEntryChildren"] as? [[String:Any]] ?? [] { visit(child,inherited:inherited) }
                }
                list.forEach { visit($0) }
            }
        }
        return paths.map { SerialDevice(port:$0,detail:descriptions[$0] ?? ($0.localizedCaseInsensitiveContains("usb") ? "USB 串口设备（含扩展坞）" : "系统串口设备")) }
    }
}
