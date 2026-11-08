import Foundation
import CryptoKit

struct FirmwareArtifact: Equatable {
    let file:String
    let modified:Date
    let size:UInt64
    let sha256:String
    var summary:String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return "\(formatter.string(from:modified)) · \(ByteCountFormatter.string(fromByteCount:Int64(size),countStyle:.file)) · SHA-256 \(sha256.prefix(16))…"
    }
    static func inspect(_ file:String) throws -> FirmwareArtifact {
        let before = try fm.attributesOfItem(atPath:file)
        guard before[.type] as? FileAttributeType == .typeRegular,
              let size = before[.size] as? UInt64, size > 0,
              let date = before[.modificationDate] as? Date else { throw StudioError("固件必须是非空的普通文件。") }
        let handle = try FileHandle(forReadingFrom:URL(fileURLWithPath:file)); defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount:1024*1024), !data.isEmpty { hash.update(data:data) }
        let after = try fm.attributesOfItem(atPath:file)
        guard after[.size] as? UInt64 == size, after[.modificationDate] as? Date == date else { throw StudioError("固件仍在写入，请稍后刷新。") }
        return FirmwareArtifact(file:file,modified:date,size:size,sha256:hash.finalize().map{String(format:"%02x",$0)}.joined())
    }
    static func outputs(_ directory:String) -> [String] {
        guard let entries = fm.enumerator(atPath:directory) else{return []}
        return entries.allObjects.compactMap{$0 as? String}.filter{["elf","hex","bin"].contains(URL(fileURLWithPath:$0).pathExtension.lowercased()) && !$0.contains("CMakeFiles/") && !$0.hasPrefix(".")}.map{path(directory,$0)}.sorted()
    }
}
