import Foundation
import Darwin
import SwiftUI
import AppKit

final class SerialTerminal: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var received = Data()
    @Published private(set) var receivedCount = 0
    @Published private(set) var sentCount = 0
    @Published var status = "Disconnected"
    private var descriptor: Int32 = -1
    private var source: DispatchSourceRead?

    static func payload(_ text:String, hex:Bool, newline:Bool) throws -> Data {
        if hex {
            let compact = text.filter { !$0.isWhitespace }
            guard !compact.isEmpty, compact.count % 2 == 0, compact.allSatisfy({ $0.isHexDigit && $0.isASCII }) else {
                throw StudioError("HEX 请填写成对的十六进制字节，例如 01 A0 FF。")
            }
            let chars = Array(compact)
            return Data(stride(from:0,to:chars.count,by:2).map { UInt8(String(chars[$0...$0+1]),radix:16)! })
        }
        return Data((text + (newline ? "\r\n" : "")).utf8)
    }
    func connect(port:String,baud:String) {
        guard !connected else { return }
        let pseudoTerminal = port.range(of:"^/dev/ttys[0-9]+$",options:.regularExpression) != nil
        guard port.hasPrefix("/dev/cu.") || port.hasPrefix("/dev/tty.") || pseudoTerminal,
              ["9600","19200","38400","57600","115200","230400"].contains(baud) else { status = "请选择串口和有效波特率"; return }
        let fd = Darwin.open(port,O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard fd >= 0 else { status = "打开串口失败：" + String(cString:strerror(errno)); return }
        do {
            let process = Process(); process.executableURL = URL(fileURLWithPath:"/bin/stty")
            process.arguments = ["-f",port,baud,"raw","-echo","cs8","-parenb","-cstopb","clocal","-crtscts"]
            let errors = Pipe(); process.standardError = errors; process.standardOutput = FileHandle.nullDevice
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw StudioError(String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)) }
            // Apply exclusivity after stty has opened and configured the device.
            guard ioctl(fd,TIOCEXCL,0) == 0 else { throw StudioError("串口无法独占，请关闭其他串口程序") }
            descriptor = fd; connected = true; status = "Connected · 8N1"
            let input = DispatchSource.makeReadSource(fileDescriptor:fd,queue:.main)
            input.setEventHandler { [weak self] in self?.receive() }
            input.setCancelHandler { Darwin.close(fd) }
            source = input; input.resume()
        } catch { Darwin.close(fd); status = "串口配置失败：" + error.localizedDescription }
    }
    private func receive() {
        guard connected else { return }
        var buffer = [UInt8](repeating:0,count:4096)
        let size = Darwin.read(descriptor,&buffer,buffer.count)
        if size > 0 {
            received.append(contentsOf:buffer.prefix(size)); receivedCount += size
            if received.count > 65536 { received = Data(received.suffix(65536)) }
        } else if size == 0 || (size < 0 && errno != EAGAIN && errno != EINTR) {
            disconnect(); status = "串口已断开或设备已移除"
        }
    }
    func send(_ text:String,hex:Bool,newline:Bool) {
        guard connected else { status = "请先连接串口"; return }
        do {
            let data = try Self.payload(text,hex:hex,newline:newline)
            guard data.count <= 4096 else { throw StudioError("单次发送最多 4096 字节。") }
            let written = data.withUnsafeBytes { Darwin.write(descriptor,$0.baseAddress,data.count) }
            if written > 0 { sentCount += written }
            guard written == data.count else { throw StudioError("串口发送未完成，请检查连接后重试；已发送 \(max(0,written)) 字节。") }
            status = L10n.format("Sent %lld bytes",written)
        } catch { status = error.localizedDescription }
    }
    func disconnect() { connected = false; descriptor = -1; source?.cancel(); source = nil; status = "Disconnected" }
    func clear() { received = Data(); receivedCount = 0; sentCount = 0 }
    deinit { source?.cancel() }
}

struct SerialTerminalView: View {
    @ObservedObject var studio: Studio
    @ObservedObject var terminal: SerialTerminal
    @State private var baud = "115200"
    @State private var hex = false
    @State private var newline = true
    @State private var outgoing = ""
    var body: some View {
        VStack(alignment:.leading,spacing:12) {
            HStack {
                Picker("Serial Port",selection:$studio.settings.serialPort) {
                    Text("Select a port").tag("")
                    ForEach(studio.serialDevices,id:\.port) { Text($0.port).tag($0.port) }
                }.disabled(terminal.connected)
                Picker("Baud Rate",selection:$baud) { ForEach(["9600","19200","38400","57600","115200","230400"],id:\.self) { Text($0).tag($0) } }.frame(width:175).disabled(terminal.connected)
                Button { studio.scanSerial() } label: { Image(systemName:"arrow.clockwise") }.help("Refresh Serial Ports")
                Button(LocalizedStringKey(terminal.connected ? "Disconnect" : "Connect")) {
                    if terminal.connected { terminal.disconnect() }
                    else { terminal.connect(port:studio.settings.serialPort,baud:baud) }
                }.disabled(studio.busy)
            }
            HStack {
                Toggle("HEX",isOn:$hex); Toggle("Append CRLF",isOn:$newline).disabled(hex)
                Spacer(); Text("RX \(terminal.receivedCount) / TX \(terminal.sentCount) bytes").font(.caption).foregroundStyle(.secondary)
                Button { terminal.clear() } label: { Image(systemName:"trash") }.help("Clear Received Data")
                Button { exportReceived() } label: { Image(systemName:"square.and.arrow.down") }.help("Save Received Data")
            }
            ScrollView([.vertical,.horizontal]) {
                Text(hex ? terminal.received.map { String(format:"%02X",$0) }.joined(separator:" ") : String(decoding:terminal.received,as:UTF8.self))
                    .font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.topLeading).padding(8)
            }.frame(height:180).background(Color(nsColor:.textBackgroundColor))
            HStack {
                TextField(LocalizedStringKey(hex ? "01 A0 FF" : "Text to send"),text:$outgoing).onSubmit { send() }
                Button { send() } label: { Image(systemName:"paperplane") }.help("Send").disabled(!terminal.connected)
            }
            Text(L10n.string(terminal.status)).font(.caption).foregroundStyle(.secondary)
        }
    }
    private func send() { terminal.send(outgoing,hex:hex,newline:newline) }
    private func exportReceived() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "serial-received.bin"
        if panel.runModal() == .OK, let url = panel.url {
            do { try terminal.received.write(to:url,options:.atomic) } catch { terminal.status = error.localizedDescription }
        }
    }
}
