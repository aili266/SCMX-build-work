import Foundation
import CryptoKit
import Darwin

enum PackingError: Error { case invalid(String) }

struct PackedProfile: Decodable {
    let id:String
    let name:String
    let source:String
    let license:String
    let offset:Int
    let length:Int
    let uncompressedLength:Int
    let sha256:String
    let registerCount:Int
}
struct PackedChoice: Decodable { let id:String; let core:String }
struct PackedDevice: Decodable { let name:String; let family:String; let profiles:[PackedChoice] }
struct PackedIndex: Decodable { let schema:Int; let devices:[PackedDevice]; let profiles:[PackedProfile] }
struct PackedRow: Decodable {
    let group:String
    let instance:String
    let name:String
    let address:UInt64
    let size:Int
    let access:String
    let description:String
    let readAction:String?
}
struct PackedPayload: Decodable { let name:String; let registers:[PackedRow] }

func sha256(_ data:Data) -> String {
    SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
}

func verify(_ directory:URL) throws {
    let index = try JSONDecoder().decode(PackedIndex.self,from:Data(contentsOf:directory.appendingPathComponent("index.json")))
    let storage = try Data(contentsOf:directory.appendingPathComponent("registers.dat"),options:.mappedIfSafe)
    let identifiers = Set(index.profiles.map(\.id))
    guard index.schema == 1, !index.devices.isEmpty, !index.profiles.isEmpty,
          identifiers.count == index.profiles.count,
          Set(index.devices.map { $0.name.uppercased() }).count == index.devices.count else {
        throw PackingError.invalid("Invalid index identities")
    }
    var offset = 0, total = 0
    for profile in index.profiles {
        try autoreleasepool {
            guard profile.offset == offset, profile.length > 0,
                  profile.offset >= 0, profile.offset <= storage.count,
                  profile.length <= storage.count - profile.offset else {
                throw PackingError.invalid("Invalid block bounds: " + profile.id)
            }
            let block = storage.subdata(in:profile.offset..<(profile.offset + profile.length))
            let raw = try (block as NSData).decompressed(using:.lzfse) as Data
            guard raw.count == profile.uncompressedLength, sha256(raw) == profile.sha256 else {
                throw PackingError.invalid("Invalid block SHA256: " + profile.id)
            }
            let payload = try JSONDecoder().decode(PackedPayload.self,from:raw)
            guard payload.name == profile.name, payload.registers.count == profile.registerCount,
                  Set(payload.registers.map { "\($0.instance).\($0.name)@\($0.address)" }).count == payload.registers.count,
                  payload.registers.allSatisfy({ !$0.group.isEmpty && !$0.instance.isEmpty && !$0.name.isEmpty && (1...4096).contains($0.size) }) else {
                throw PackingError.invalid("Invalid or duplicate register rows: " + profile.id)
            }
            offset += block.count
            total += payload.registers.count
        }
    }
    guard offset == storage.count else { throw PackingError.invalid("Trailing data after final profile") }
    for device in index.devices {
        guard device.name.hasPrefix("STM32"), device.family.hasPrefix("STM32"), !device.profiles.isEmpty,
              Set(device.profiles.map(\.id)).count == device.profiles.count,
              device.profiles.allSatisfy({ identifiers.contains($0.id) }) else {
            throw PackingError.invalid("Invalid device choices: " + device.name)
        }
    }
    print("Verified \(index.devices.count) devices, \(index.profiles.count) blocks, \(total) register rows; offsets, SHA256, schema and unique IDs passed")
}

func pack() throws {
    if CommandLine.arguments.count == 3, CommandLine.arguments[1] == "--verify" {
        try verify(URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true))
        return
    }
    guard CommandLine.arguments.count == 4 else {
        throw PackingError.invalid("Usage: swift pack-register-db.swift manifest.json raw-json-directory output-directory")
    }
    let manifestURL = URL(fileURLWithPath:CommandLine.arguments[1])
    let rawDirectory = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
    let output = URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
    guard var manifest = try JSONSerialization.jsonObject(with:Data(contentsOf:manifestURL)) as? [String:Any],
          manifest["schema"] as? Int == 1, let profiles = manifest["profiles"] as? [[String:Any]], !profiles.isEmpty else {
        throw PackingError.invalid("Invalid manifest")
    }
    try FileManager.default.createDirectory(at:output,withIntermediateDirectories:true)
    let temporary = output.appendingPathComponent(".registers.dat.tmp")
    defer { try? FileManager.default.removeItem(at:temporary) }
    guard FileManager.default.createFile(atPath:temporary.path,contents:nil) else {
        throw PackingError.invalid("Cannot create packed database")
    }
    let handle = try FileHandle(forWritingTo:temporary)
    defer { try? handle.close() }
    var offset = 0
    var packed:[[String:Any]] = []
    var identifiers = Set<String>()
    for var profile in profiles {
        try autoreleasepool {
            guard let id = profile["id"] as? String,
                  id.range(of:"^[A-Za-z0-9_-]+$",options:.regularExpression) != nil,
                  identifiers.insert(id).inserted,
                  let expectedHash = profile["sha256"] as? String,
                  let expectedLength = profile["uncompressedLength"] as? Int,
                  let expectedRegisters = profile["registerCount"] as? Int else {
                throw PackingError.invalid("Invalid or duplicate profile")
            }
            let data = try Data(contentsOf:rawDirectory.appendingPathComponent(id + ".json"))
            guard data.count == expectedLength, sha256(data) == expectedHash,
                  let payload = try JSONSerialization.jsonObject(with:data) as? [String:Any],
                  let rows = payload["registers"] as? [[String:Any]], rows.count == expectedRegisters else {
                throw PackingError.invalid("Raw profile hash/count mismatch: " + id)
            }
            let compressed = try (data as NSData).compressed(using:.lzfse) as Data
            let restored = try (compressed as NSData).decompressed(using:.lzfse) as Data
            guard restored == data else { throw PackingError.invalid("LZFSE roundtrip failed: " + id) }
            profile["offset"] = offset
            profile["length"] = compressed.count
            try handle.write(contentsOf:compressed)
            offset += compressed.count
            packed.append(profile)
        }
    }
    try handle.synchronize()
    try handle.close()
    let destination = output.appendingPathComponent("registers.dat")
    guard Darwin.rename(temporary.path,destination.path) == 0 else {
        throw PackingError.invalid("Cannot install registers.dat: \(errno)")
    }
    manifest["profiles"] = packed
    let data = try JSONSerialization.data(withJSONObject:manifest,options:[.sortedKeys,.prettyPrinted,.withoutEscapingSlashes])
    try data.write(to:output.appendingPathComponent("index.json"),options:.atomic)
    print("Packed \(packed.count) independent LZFSE blocks, \(offset) bytes; every block hash and roundtrip verified")
    try verify(output)
}

do { try pack() } catch {
    FileHandle.standardError.write(Data("Register database packing failed: \(error)\n".utf8))
    exit(1)
}
