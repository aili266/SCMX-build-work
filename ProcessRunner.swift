import Foundation
import Darwin

final class Runner: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var running = false
    let log: (String) -> Void

    init(log: @escaping (String) -> Void) { self.log = log }

    func cancel() { lock.lock(); stopped = true; lock.unlock() }

    func check() throws {
        lock.lock(); let cancelled = stopped; lock.unlock()
        if cancelled { throw StudioError("\u{64CD}\u{4F5C}\u{5DF2}\u{505C}\u{6B62}\u{3002}") }
    }

    // outputLimit bounds the returned UTF-8 tail, not the live log stream.
    // The synchronous log callback must return promptly (as in Studio.perform).
    @discardableResult
    func run(_ exe: String, _ args: [String], cwd: String? = nil,
             env: [String:String]? = nil, timeout: Double = 600,
             outputLimit: Int = 4 * 1024 * 1024) throws -> String {
        try check()
        guard timeout.isFinite, timeout >= 0, outputLimit >= 0 else {
            throw StudioError("Invalid process timeout or output limit.")
        }
        lock.lock()
        guard !running else { lock.unlock(); throw StudioError("Runner is already running a command.") }
        running = true
        lock.unlock()
        defer { lock.lock(); running = false; lock.unlock() }

        let executable = URL(fileURLWithPath:exe).path
        guard FileManager.default.isExecutableFile(atPath:executable) else {
            throw StudioError("Tool is not executable or does not exist: \(exe)")
        }
        let deadline = runnerTime() + timeout
        log("\u{203A} \(exe) \(args.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator:" "))\n")
        try check()
        let child = try RunnerChild.spawn(executable,args,cwd:cwd,env:env)
        var decoder = RunnerUTF8Decoder()
        var tail = RunnerOutputTail(limit:outputLimit)
        var buffer = [UInt8](repeating:0,count:64 * 1024)
        var failure: Error?
        var terminateDeadline: Double?

        func emit(_ text: String) {
            guard !text.isEmpty else { return }
            tail.append(text)
            log(text)
        }

        while true {
            let now = runnerTime()
            if failure == nil {
                do { try check() } catch { failure = error }
                if failure == nil, now >= deadline {
                    // Preserve the localized timeout keyword used by existing callers/tests.
                    failure = StudioError("\(URL(fileURLWithPath:exe).lastPathComponent) \u{6267}\u{884C}\u{8D85}\u{65F6} (\(timeout) s).")
                }
                if failure != nil {
                    child.signalGroup(SIGTERM)
                    terminateDeadline = now + 0.25
                }
            }
            if let end = terminateDeadline, now >= end, !child.killed {
                child.signalGroup(SIGKILL)
                child.closeOutput()
            }

            let exited = try child.hasExited()
            if failure != nil {
                if child.killed && exited { break }
            } else if exited && child.readFD < 0 { break }

            let nextDeadline = child.killed ? now + 0.02 : (terminateDeadline ?? deadline)
            let waitMS = Int32(max(0,min(20,ceil((nextDeadline - now) * 1000))))
            if child.readFD < 0 {
                _ = Darwin.poll(nil,0,waitMS)
                continue
            }
            var descriptor = pollfd(fd:child.readFD,events:Int16(POLLIN),revents:0)
            let ready = Darwin.poll(&descriptor,1,waitMS)
            if ready < 0 {
                if errno == EINTR { continue }
                throw runnerPOSIXError("poll",errno)
            }
            if descriptor.revents & Int16(POLLNVAL) != 0 { throw runnerPOSIXError("poll",EBADF) }
            guard ready > 0 else { continue }
            // Bound each draining turn so a continuously writable producer cannot starve deadlines.
            for _ in 0..<4 {
                let count = buffer.withUnsafeMutableBytes { Darwin.read(child.readFD,$0.baseAddress,$0.count) }
                if count > 0 {
                    emit(decoder.decode(buffer.prefix(count)))
                } else if count == 0 {
                    child.closeOutput()
                    break
                } else {
                    if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR { break }
                    throw runnerPOSIXError("read",errno)
                }
            }
        }
        emit(decoder.finish())
        let status = try child.finish()
        if let failure { throw failure }
        try check()
        let output = tail.string
        let signal = status & 0x7f
        let exitCode = (status >> 8) & 0xff
        guard signal == 0, exitCode == 0 else {
            let reason = signal == 0 ? "exit code \(exitCode)" : "signal \(signal)"
            throw StudioError("\(URL(fileURLWithPath:exe).lastPathComponent) failed (\(reason)).\n\(String(output.suffix(1800)))")
        }
        return output
    }
}

private func runnerTime() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
private func runnerPOSIXError(_ operation: String, _ code: Int32) -> StudioError {
    StudioError("\(operation): \(String(cString:strerror(code))) (\(code))")
}
private func runnerCheckPOSIX(_ result: Int32, _ operation: String) throws {
    if result != 0 { throw runnerPOSIXError(operation,result) }
}
private func runnerClose(_ fd: inout Int32) {
    if fd >= 0 { _ = Darwin.close(fd); fd = -1 }
}

private final class RunnerChild {
    let pid: pid_t
    private(set) var readFD: Int32
    private(set) var killed = false
    private var ownsChild = true

    private init(pid: pid_t, readFD: Int32) { self.pid = pid; self.readFD = readFD }

    static func spawn(_ exe: String, _ args: [String], cwd: String?, env: [String:String]?) throws -> RunnerChild {
        let environment = env ?? ProcessInfo.processInfo.environment
        guard !([exe] + args + [cwd ?? ""]).contains(where: { $0.utf8.contains(0) }),
              environment.allSatisfy({ !$0.key.isEmpty && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw StudioError("Process arguments or environment contain an invalid NUL/key.")
        }
        var descriptors: [Int32] = [-1,-1]
        guard Darwin.pipe(&descriptors) == 0 else { throw runnerPOSIXError("pipe",errno) }
        var readFD = descriptors[0], writeFD = descriptors[1]
        defer { runnerClose(&readFD); runnerClose(&writeFD) }
        // Relocate pipes away from stdin/out/err, even when the host has closed those descriptors.
        for index in 0..<2 {
            let fd = index == 0 ? readFD : writeFD
            let copy = fcntl(fd,F_DUPFD_CLOEXEC,3)
            guard copy >= 0 else { throw runnerPOSIXError("fcntl(F_DUPFD_CLOEXEC)",errno) }
            _ = Darwin.close(fd)
            if index == 0 { readFD = copy } else { writeFD = copy }
        }
        let flags = fcntl(readFD,F_GETFL)
        guard flags >= 0, fcntl(readFD,F_SETFL,flags | O_NONBLOCK) == 0 else {
            throw runnerPOSIXError("fcntl(O_NONBLOCK)",errno)
        }
        var actions: posix_spawn_file_actions_t?
        try runnerCheckPOSIX(posix_spawn_file_actions_init(&actions),"spawn actions init")
        defer { posix_spawn_file_actions_destroy(&actions) }
        try runnerCheckPOSIX(posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0),"spawn stdin")
        try runnerCheckPOSIX(posix_spawn_file_actions_adddup2(&actions,writeFD,STDOUT_FILENO),"spawn stdout")
        try runnerCheckPOSIX(posix_spawn_file_actions_adddup2(&actions,writeFD,STDERR_FILENO),"spawn stderr")
        try runnerCheckPOSIX(posix_spawn_file_actions_addclose(&actions,readFD),"spawn close read")
        try runnerCheckPOSIX(posix_spawn_file_actions_addclose(&actions,writeFD),"spawn close write")
        if let cwd {
            try runnerCheckPOSIX(posix_spawn_file_actions_addchdir_np(&actions,URL(fileURLWithPath:cwd).path),"spawn cwd")
        }
        var attributes: posix_spawnattr_t?
        try runnerCheckPOSIX(posix_spawnattr_init(&attributes),"spawn attributes init")
        defer { posix_spawnattr_destroy(&attributes) }
        let spawnFlags = Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT)
        try runnerCheckPOSIX(posix_spawnattr_setflags(&attributes,spawnFlags),"spawn flags")
        try runnerCheckPOSIX(posix_spawnattr_setpgroup(&attributes,0),"spawn process group")
        var mask = sigset_t(), defaults = sigset_t()
        sigemptyset(&mask); sigemptyset(&defaults)
        for signal in [SIGTERM,SIGINT,SIGQUIT,SIGHUP,SIGPIPE] { sigaddset(&defaults,signal) }
        try runnerCheckPOSIX(posix_spawnattr_setsigmask(&attributes,&mask),"spawn signal mask")
        try runnerCheckPOSIX(posix_spawnattr_setsigdefault(&attributes,&defaults),"spawn signal defaults")
        let arguments = try RunnerCStringArray([exe] + args)
        let variables = try RunnerCStringArray(environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" })
        var pid: pid_t = 0
        let result = withExtendedLifetime((arguments,variables)) {
            arguments.pointers.withUnsafeBufferPointer { argv in
                variables.pointers.withUnsafeBufferPointer { envp in
                    posix_spawn(&pid,exe,&actions,&attributes,argv.baseAddress!,envp.baseAddress!)
                }
            }
        }
        try runnerCheckPOSIX(result,"posix_spawn \(exe)")
        let child = RunnerChild(pid:pid,readFD:readFD)
        readFD = -1
        return child
    }

    func closeOutput() { runnerClose(&readFD) }

    func hasExited() throws -> Bool {
        var info = siginfo_t()
        // Keep the leader waitable until all group signals are sent: its PID/PGID cannot be reused.
        if waitid(P_PID,id_t(pid),&info,WEXITED | WNOHANG | WNOWAIT) < 0 {
            if errno == EINTR { return false }
            if errno == ECHILD { ownsChild = false }
            throw runnerPOSIXError("waitid",errno)
        }
        return info.si_pid == pid
    }

    func signalGroup(_ signal: Int32) {
        guard ownsChild, pid > 1 else { return }
        _ = Darwin.kill(-pid,signal)
        _ = Darwin.kill(pid,signal)
        if signal == SIGKILL { killed = true }
    }

    func finish() throws -> Int32 {
        // Also clean up any remaining group members that have already closed their output.
        signalGroup(SIGKILL)
        closeOutput()
        var status: Int32 = 0
        while waitpid(pid,&status,0) < 0 {
            if errno == EINTR { continue }
            if errno == ECHILD { ownsChild = false }
            throw runnerPOSIXError("waitpid",errno)
        }
        ownsChild = false
        return status
    }

    deinit {
        closeOutput()
        guard ownsChild else { return }
        if !killed {
            signalGroup(SIGTERM)
            let end = runnerTime() + 0.25
            while runnerTime() < end { _ = Darwin.poll(nil,0,20) }
            signalGroup(SIGKILL)
        }
        var status: Int32 = 0
        while waitpid(pid,&status,0) < 0 && errno == EINTR {}
    }
}

private final class RunnerCStringArray {
    private(set) var pointers: [UnsafeMutablePointer<CChar>?] = []
    init(_ strings: [String]) throws {
        do {
            for string in strings {
                guard let pointer = strdup(string) else { throw runnerPOSIXError("strdup",ENOMEM) }
                pointers.append(pointer)
            }
            pointers.append(nil)
        } catch {
            for pointer in pointers { free(pointer) }
            pointers.removeAll()
            throw error
        }
    }
    deinit { for pointer in pointers { free(pointer) } }
}

private struct RunnerUTF8Decoder {
    private var pending: [UInt8] = []

    mutating func decode(_ chunk: ArraySlice<UInt8>) -> String {
        var bytes = pending
        bytes.append(contentsOf:chunk)
        pending.removeAll(keepingCapacity:true)
        var end = bytes.count
        if end > 0 {
            var start = end - 1
            while start > max(0,end - 4), bytes[start] & 0xc0 == 0x80 { start -= 1 }
            let lead = bytes[start]
            let length = (0xc2...0xdf).contains(lead) ? 2 : (0xe0...0xef).contains(lead) ? 3 : (0xf0...0xf4).contains(lead) ? 4 : 0
            var validPrefix = length > end - start
            if validPrefix, end - start > 1 {
                let second = bytes[start + 1]
                validPrefix = (lead != 0xe0 || second >= 0xa0) && (lead != 0xed || second <= 0x9f)
                    && (lead != 0xf0 || second >= 0x90) && (lead != 0xf4 || second <= 0x8f)
            }
            if validPrefix { pending = Array(bytes[start...]); end = start }
        }
        return String(decoding:bytes[..<end],as:UTF8.self)
    }

    mutating func finish() -> String {
        defer { pending.removeAll() }
        return String(decoding:pending,as:UTF8.self)
    }
}

private struct RunnerOutputTail {
    let limit: Int
    private var bytes: [UInt8] = []
    private var head = 0

    init(limit: Int) { self.limit = limit }

    mutating func append(_ text: String) {
        guard limit > 0 else { return }
        for byte in text.utf8 {
            if bytes.count < limit { bytes.append(byte) }
            else { bytes[head] = byte; head += 1; if head == limit { head = 0 } }
        }
    }

    var string: String {
        let ordered = Array(bytes[head...]) + bytes[..<head]
        // Byte eviction may cut through a code point; omit its remaining continuation bytes.
        return String(decoding:ordered.drop(while: { $0 & 0xc0 == 0x80 }),as:UTF8.self)
    }
}
