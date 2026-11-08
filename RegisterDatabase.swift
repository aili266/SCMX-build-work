import Foundation
import CryptoKit
import Compression

struct RegisterProfileChoice: Codable, Hashable, Identifiable {
    let id: String
    let core: String
}

struct RegisterProfile: Decodable, Identifiable {
    let id: String
    let name: String
    let source: String
    let license: String
    let offset: Int
    let length: Int
    let uncompressedLength: Int
    let sha256: String
    let registerCount: Int
}

struct RegisterDefinition: Identifiable, Hashable {
    let peripheral: String
    let instance: String
    let registerName: String
    let addressValue: UInt64
    let purpose: String
    let access: String
    let size: Int
    let readAction: String?
    let model: String
    let profileID: String
    var id: String { "\(instance).\(registerName)@\(addressValue)" }
    var name: String { registerName.hasPrefix(instance + "_") ? registerName : instance + "_" + registerName }
    var address: String { String(format:"0x%08llX",addressValue) }
    var resultID: String { model + "|" + profileID + "|" + id }
    var canRead: Bool {
        ["read-only","read-write","read-writeOnce"].contains(access)
            && [8,16,32,64].contains(size) && addressValue % UInt64(size / 8) == 0
    }
    var readCommand: String? {
        guard canRead else { return nil }
        let format = [8:"b",16:"h",32:"w",64:"g"][size]!
        return "x/\(format)x \(address)"
    }
}

struct RegisterSnapshot {
    let model: String
    let profile: RegisterProfile
    let registers: [RegisterDefinition]
}

enum RegisterDatabaseError: LocalizedError {
    case unavailable, invalid, unsupported(String)
    var errorDescription: String? {
        switch self {
        case .unavailable: return L10n.string("The bundled register database is missing. Reinstall the app.")
        case .invalid: return L10n.string("The bundled register database failed validation.")
        case .unsupported(let model): return L10n.format("No bundled register profile matches %@.",model)
        }
    }
}

final class RegisterDatabase {
    private struct Device: Decodable {
        let name: String
        let family: String
        let profiles: [RegisterProfileChoice]
    }
    private struct Index: Decodable {
        let schema: Int
        let devices: [Device]
        let profiles: [RegisterProfile]
    }
    private struct Row: Decodable {
        let group: String
        let instance: String
        let name: String
        let address: UInt64
        let size: Int
        let access: String
        let description: String
        let readAction: String?
    }
    private struct Payload: Decodable {
        let name: String
        let registers: [Row]
    }
    private struct Pattern {
        let device: Device
        let expression: NSRegularExpression
    }
    private let index: Index
    private let storage: Data
    private let profilesByID: [String:RegisterProfile]
    private let devicesByName: [String:Device]
    private let patterns: [Pattern]
    private let cacheLock = NSLock()
    private var cache: [String:Payload] = [:]
    private var cacheOrder: [String] = []

    init(indexData:Data, storage:Data) throws {
        let decoded = try JSONDecoder().decode(Index.self,from:indexData)
        guard decoded.schema == 1, !decoded.devices.isEmpty, !decoded.profiles.isEmpty,
              Set(decoded.profiles.map(\.id)).count == decoded.profiles.count,
              Set(decoded.devices.map { $0.name.uppercased() }).count == decoded.devices.count else { throw RegisterDatabaseError.invalid }
        let byID = Dictionary(uniqueKeysWithValues:decoded.profiles.map { ($0.id,$0) })
        for profile in decoded.profiles {
            guard !profile.id.isEmpty, profile.offset >= 0, profile.length > 0,
                  profile.offset <= storage.count, profile.length <= storage.count - profile.offset,
                  (1...64_000_000).contains(profile.uncompressedLength), profile.registerCount > 0,
                  profile.sha256.range(of:"^[a-f0-9]{64}$",options:.regularExpression) != nil else { throw RegisterDatabaseError.invalid }
        }
        for device in decoded.devices {
            guard device.name.hasPrefix("STM32"), device.family.hasPrefix("STM32"),
                  !device.profiles.isEmpty, device.profiles.allSatisfy({ byID[$0.id] != nil }),
                  Set(device.profiles.map(\.id)).count == device.profiles.count else { throw RegisterDatabaseError.invalid }
        }
        index = decoded; self.storage = storage; profilesByID = byID
        devicesByName = Dictionary(uniqueKeysWithValues:decoded.devices.map { ($0.name.uppercased(),$0) })
        patterns = try decoded.devices.map { device in
            let name = device.name.uppercased()
            var pattern = NSRegularExpression.escapedPattern(for:name).replacingOccurrences(of:"X",with:"[A-Z0-9]")
            // Older packs omit the final package suffix, but still specify the pin and memory variant.
            if !name.contains("X"), (11...13).contains(name.count) { pattern += "[A-Z0-9]{0,3}" }
            return Pattern(device:device,expression:try NSRegularExpression(pattern:"^" + pattern + "$"))
        }.sorted { $0.device.name.count > $1.device.name.count }
    }

    var devices: [MCURecord] {
        index.devices.map { MCURecord(name:$0.name,family:$0.family,package:"",databaseName:$0.name,fromCubeMX:false) }
    }
    var allProfiles: [RegisterProfile] { index.profiles }

    private func device(family:String, model:String) -> Device? {
        let normalized = model.uppercased()
        let matchesFamily = family == "STM32H7RS"
            ? (normalized.hasPrefix("STM32H7R") || normalized.hasPrefix("STM32H7S"))
            : normalized.hasPrefix(family.uppercased().replacingOccurrences(of:"+",with:""))
        guard !family.isEmpty, !model.isEmpty,
              matchesFamily else { return nil }
        if let exact = devicesByName[normalized] { return exact }
        let range = NSRange(normalized.startIndex..<normalized.endIndex,in:normalized)
        let matches = patterns.filter { $0.expression.firstMatch(in:normalized,range:range) != nil }
        guard let first = matches.first else { return nil }
        let equallySpecific = matches.filter { $0.device.name.count == first.device.name.count }
        guard equallySpecific.allSatisfy({ Set($0.device.profiles) == Set(first.device.profiles) }) else { return nil }
        return first.device
    }

    func choices(family:String, model:String) -> [RegisterProfileChoice] {
        device(family:family,model:model)?.profiles ?? []
    }

    func snapshot(family:String, model:String, profileID:String = "") throws -> RegisterSnapshot {
        let choices = choices(family:family,model:model)
        let selected = profileID.isEmpty ? choices.first?.id : choices.first(where:{$0.id == profileID})?.id
        guard let id = selected, let profile = profilesByID[id] else { throw RegisterDatabaseError.unsupported(model) }
        let payload = try payload(profile)
        let registers = payload.registers.map {
            RegisterDefinition(peripheral:$0.group,instance:$0.instance,registerName:$0.name,addressValue:$0.address,
                               purpose:$0.description,access:$0.access,size:$0.size,readAction:$0.readAction,model:model,profileID:profile.id)
        }
        return RegisterSnapshot(model:model,profile:profile,registers:registers)
    }

    func validateAllProfiles() throws {
        for profile in index.profiles { _ = try payload(profile) }
    }

    private func payload(_ profile:RegisterProfile) throws -> Payload {
        cacheLock.lock()
        let stored = cache[profile.id]
        cacheLock.unlock()
        if let stored { return stored }
        let compressed = storage.subdata(in:profile.offset..<(profile.offset + profile.length))
        var data = Data(count:profile.uncompressedLength)
        let decoded = data.withUnsafeMutableBytes { output in
            compressed.withUnsafeBytes { input in
                compression_decode_buffer(output.bindMemory(to:UInt8.self).baseAddress!,profile.uncompressedLength,
                                          input.bindMemory(to:UInt8.self).baseAddress!,compressed.count,nil,COMPRESSION_LZFSE)
            }
        }
        guard decoded == profile.uncompressedLength,
              SHA256.hash(data:data).map({String(format:"%02x",$0)}).joined() == profile.sha256 else { throw RegisterDatabaseError.invalid }
        let result = try JSONDecoder().decode(Payload.self,from:data)
        guard result.name == profile.name, result.registers.count == profile.registerCount,
              result.registers.allSatisfy({ !$0.name.isEmpty && !$0.instance.isEmpty && !$0.group.isEmpty && $0.address <= UInt64(UInt32.max) && (1...4096).contains($0.size) }),
              Set(result.registers.map { "\($0.instance).\($0.name)@\($0.address)" }).count == result.registers.count else { throw RegisterDatabaseError.invalid }
        cacheLock.lock()
        cache[profile.id] = result; cacheOrder.removeAll(where:{$0 == profile.id}); cacheOrder.append(profile.id)
        while cacheOrder.count > 4 { cache.removeValue(forKey:cacheOrder.removeFirst()) }
        cacheLock.unlock()
        return result
    }
}

enum RegisterCatalog {
    private static let database: Result<RegisterDatabase,Error> = Result {
        guard let index = Bundle.main.url(forResource:"index",withExtension:"json",subdirectory:"Registers"),
              let storage = Bundle.main.url(forResource:"registers",withExtension:"dat",subdirectory:"Registers") else { throw RegisterDatabaseError.unavailable }
        return try RegisterDatabase(indexData:Data(contentsOf:index),storage:Data(contentsOf:storage,options:.mappedIfSafe))
    }
    static var devices: [MCURecord] { (try? database.get().devices) ?? [] }
    static var allProfiles: [RegisterProfile] { (try? database.get().allProfiles) ?? [] }
    static func choices(family:String,model:String) -> [RegisterProfileChoice] { (try? database.get().choices(family:family,model:model)) ?? [] }
    static func snapshot(family:String,model:String,profileID:String = "") throws -> RegisterSnapshot {
        try database.get().snapshot(family:family,model:model,profileID:profileID)
    }
    static func validateAllProfiles() throws { try database.get().validateAllProfiles() }
}
