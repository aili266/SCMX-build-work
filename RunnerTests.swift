import Foundation
import Darwin

func runRunnerTests() throws {
    let files = FileManager.default
    let directory = URL(fileURLWithPath:"/tmp").appendingPathComponent("runner-tests-" + UUID().uuidString)
    try files.createDirectory(at:directory,withIntermediateDirectories:true)
    defer { try? files.removeItem(at:directory) }
    func expect(_ condition: Bool, _ label: String, details: String = "") throws {
        guard condition else { throw StudioError("Runner test failed: " + label + " " + details) }
        print("PASS: Runner " + label)
    }
    func rejected(_ action: () throws -> Void) throws -> String {
        do { try action() } catch { return error.localizedDescription }
        throw StudioError("Runner test expected rejection.")
    }
    func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
    func descriptorCount() -> Int { (0..<1024).filter { fcntl(Int32($0),F_GETFD) >= 0 }.count }
    func isGone(_ pid: pid_t) -> Bool {
        let deadline = now() + 2
        repeat {
            if kill(pid,0) < 0, errno == ESRCH { return true }
            usleep(10_000)
        } while now() < deadline
        return false
    }
    func assertReaped(_ pid: pid_t) throws {
        var status: Int32 = 0
        let result = waitpid(pid,&status,WNOHANG)
        try expect(result == -1 && errno == ECHILD,"direct child \(pid) is reaped")
    }
    func identity(_ text: String) throws -> (pid_t,pid_t) {
        guard let line = text.split(separator:"\n").first(where: { $0.hasPrefix("PID ") }) else {
            throw StudioError("Missing fixture PID: " + text)
        }
        let fields = line.split(separator:" ")
        guard fields.count == 4, let pid = pid_t(fields[1]), let group = pid_t(fields[3]) else {
            throw StudioError("Invalid fixture PID: " + text)
        }
        return (pid,group)
    }

    // A bounded, hardware-free fixture; alarm also limits its lifetime if a regression leaks it.
    let source = directory.appendingPathComponent("fixture.c")
    let fixture = directory.appendingPathComponent("fixture").path
    try runnerTestFixtureSource.write(to:source,atomically:true,encoding:.utf8)
    let compiler = Process(), diagnostics = Pipe()
    compiler.executableURL = URL(fileURLWithPath:"/usr/bin/clang")
    compiler.arguments = ["-O2","-Wall","-Wextra","-std=c11",source.path,"-o",fixture]
    compiler.standardInput = FileHandle.nullDevice
    compiler.standardOutput = diagnostics; compiler.standardError = diagnostics
    try compiler.run()
    let compilation = diagnostics.fileHandleForReading.readDataToEndOfFile()
    compiler.waitUntilExit()
    try expect(compiler.terminationStatus == 0,"isolated C fixture compiles: " + String(decoding:compilation,as:UTF8.self))
    try diagnostics.fileHandleForReading.close()
    try diagnostics.fileHandleForWriting.close()

    let quiet = Runner(log:{ _ in })
    try expect(try quiet.run(fixture,["normal"]) == "normal-out\nnormal-err\n","normal stdout/stderr")
    let failed = try rejected { _ = try quiet.run(fixture,["failed"],outputLimit:8) }
    try expect(failed.contains("exit code 7") && failed.hasSuffix("LASTERR\n"),"failed status and bounded error tail")
    let signalled = try rejected { _ = try quiet.run(fixture,["signal"]) }
    try expect(signalled.contains("signal 15"),"signal termination is not success")
    let originalCWD = files.currentDirectoryPath
    let working = directory.appendingPathComponent("space \u{4E2D}\u{6587}")
    try files.createDirectory(at:working,withIntermediateDirectories:true)
    let actual = try quiet.run(fixture,["environment","argument with spaces"],cwd:working.path,env:["RUNNER_SENTINEL":"value"])
    guard let resolvedCWD = realpath(working.path,nil) else { throw StudioError("Cannot resolve fixture directory.") }
    let expectedCWD = String(cString:resolvedCWD)
    free(resolvedCWD)
    try expect(actual == "\(expectedCWD)\nvalue\nargument with spaces\nstdin-eof=1\nhome-absent=1\n","cwd, explicit environment, argv and null stdin",details:actual.debugDescription + " expected cwd=" + expectedCWD)
    try expect(files.currentDirectoryPath == originalCWD,"parent cwd is unchanged")
    let inheritedFD = open(source.path,O_RDONLY)
    guard inheritedFD >= 0 else { throw StudioError("Cannot open descriptor fixture.") }
    defer { close(inheritedFD) }
    try expect(try quiet.run(fixture,["descriptor",String(inheritedFD)]) == "closed\n","unrelated parent descriptors are not inherited")
    let (directPID,group) = try identity(quiet.run(fixture,["identity"]))
    try expect(directPID == group && group != getpgrp(),"new group belongs to the spawned child, not the test host")
    try assertReaped(directPID)

    let sentinel = Process()
    sentinel.executableURL = URL(fileURLWithPath:fixture); sentinel.arguments = ["sleep"]
    sentinel.standardOutput = FileHandle.nullDevice; sentinel.standardError = FileHandle.nullDevice
    try sentinel.run()
    defer { if sentinel.isRunning { sentinel.terminate() }; sentinel.waitUntilExit() }
    for mode in ["sleep","ignore-term","closed-output","flood"] {
        var prefix = ""
        let runner = Runner { if prefix.utf8.count < 4096 { prefix += String($0.prefix(1024)) } }
        let start = now()
        let error = try rejected { _ = try runner.run(fixture,[mode],timeout:0.12,outputLimit:4096) }
        try expect(error.contains("\u{8D85}\u{65F6}") && now() - start < 2,"\(mode) obeys timeout, including TERM-to-KILL grace")
        let (pid,pgid) = try identity(prefix)
        try expect(pid == pgid && pgid != getpgrp(),"\(mode) uses its own group")
        try assertReaped(pid)
        try expect(sentinel.isRunning,"\(mode) leaves an unrelated child alive")
    }

    for cancel in [false,true] {
        let pidFile = directory.appendingPathComponent("grandchild-\(cancel).pid")
        var text = ""
        let runner = Runner { text += $0 }
        if cancel { DispatchQueue.global().asyncAfter(deadline:.now() + 0.12) { runner.cancel() } }
        let start = now()
        let error = try rejected {
            _ = try runner.run(fixture,["grandchild",pidFile.path],timeout:cancel ? 3 : 0.12)
        }
        let keyword = cancel ? "\u{505C}\u{6B62}" : "\u{8D85}\u{65F6}"
        try expect(error.contains(keyword) && now() - start < 2,"\(cancel ? "cancel" : "timeout") interrupts a grandchild-held pipe after leader exit")
        let (pid,_) = try identity(text)
        try assertReaped(pid)
        let grandchildText = try String(contentsOf:pidFile,encoding:.utf8).trimmingCharacters(in:.whitespacesAndNewlines)
        guard let grandchild = pid_t(grandchildText) else { throw StudioError("Missing grandchild PID.") }
        try expect(isGone(grandchild),"grandchild ignoring TERM was killed")
        try expect(sentinel.isRunning,"group cleanup leaves unrelated sentinel alive")
    }
    let cancelled = Runner(log:{ _ in })
    DispatchQueue.global().asyncAfter(deadline:.now() + 0.12) { cancelled.cancel() }
    let cancelStart = now()
    let cancelError = try rejected { _ = try cancelled.run(fixture,["ignore-term"],timeout:3) }
    try expect(cancelError.contains("\u{505C}\u{6B62}") && now() - cancelStart < 2,"cancel kills a live TERM-ignoring leader")
    let stopped = Runner(log:{ _ in }); stopped.cancel()
    try expect(try rejected { try stopped.check() }.contains("\u{505C}\u{6B62}"),"check sees sticky cancellation")
    try expect(try rejected { _ = try stopped.run(fixture,["normal"]) }.contains("\u{505C}\u{6B62}"),"cancelled Runner never starts another command")

    for (mode,bytes) in [("utf8",[UInt8](arrayLiteral:0x41,0xe4,0xb8,0xad,0xf0,0x9f,0x98,0x80,0x42)),
                         ("invalid-utf8",[UInt8](arrayLiteral:0x61,0xe4,0xb8,0x62,0xff,0xf0,0x9f))] {
        var stream = ""
        let runner = Runner { if !$0.hasPrefix("\u{203A} ") { stream += $0 } }
        let output = try runner.run(fixture,[mode])
        let expected = String(decoding:bytes,as:UTF8.self)
        try expect(output == expected && stream == expected,"\(mode) incremental stream equals whole-data decoding, including EOF")
    }
    var liveBytes = 0
    let large = Runner { if !$0.hasPrefix("\u{203A} ") { liveBytes += $0.utf8.count } }
    let largeOutput = try large.run(fixture,["large"])
    try expect(largeOutput.utf8.count == 4 * 1024 * 1024 && largeOutput.hasSuffix("TAIL-END\n"),"default 4 MiB limit retains newest bytes")
    try expect(liveBytes == 5 * 1024 * 1024 + 9,"capture limit does not truncate the live stream")
    try expect(try quiet.run(fixture,["large"],outputLimit:17) == String(repeating:"x",count:8) + "TAIL-END\n","custom byte limit retains exact ASCII tail")
    try expect(try quiet.run(fixture,["tail-unicode"],outputLimit:3) == "Z","byte truncation never retains a partial UTF-8 scalar")
    try expect(try quiet.run(fixture,["tail-unicode"],outputLimit:5) == "\u{1F600}Z","complete four-byte scalar survives a fitting limit")
    try expect(try quiet.run(fixture,["invalid-utf8"],outputLimit:4).utf8.count <= 4,"replacement characters also obey the byte limit")
    try expect(try quiet.run(fixture,["normal"],outputLimit:0).isEmpty,"zero limit disables capture")

    _ = try rejected { _ = try quiet.run("/nonexistent-runner-test",[]) }
    _ = try rejected { _ = try quiet.run(fixture,["normal"],outputLimit:-1) }
    _ = try rejected { _ = try quiet.run(fixture,["normal"],timeout:.nan) }
    _ = try rejected { _ = try quiet.run(fixture,["bad\0argument"]) }
    _ = try rejected { _ = try quiet.run(fixture,["normal"],env:["BAD=KEY":"value"]) }
    try expect(try quiet.run(fixture,["normal"]) == "normal-out\nnormal-err\n","Runner remains reusable after ordinary failures")
    let before = descriptorCount()
    for _ in 0..<20 {
        _ = try quiet.run(fixture,["normal"])
        _ = try rejected { _ = try quiet.run(fixture,["normal"],cwd:directory.appendingPathComponent("missing").path) }
    }
    try expect(descriptorCount() == before,"success and spawn failures do not leak descriptors")
    print("PASS: all Runner tests")
}

private let runnerTestFixtureSource = #"""
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <signal.h>
#include <fcntl.h>
#include <errno.h>
#include <sys/wait.h>

static void output(const void *data, size_t size) {
    const unsigned char *p = data;
    while (size) {
        ssize_t n = write(STDOUT_FILENO, p, size);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) _exit(90);
        p += n; size -= (size_t)n;
    }
}
static void identity(void) { printf("PID %d GROUP %d\n", getpid(), getpgrp()); }
int main(int argc, char **argv) {
    if (argc < 2) return 91;
    alarm(8);
    setvbuf(stdout, NULL, _IONBF, 0);
    const char *mode = argv[1];
    if (!strcmp(mode, "normal")) { output("normal-out\n",11); write(2,"normal-err\n",11); }
    else if (!strcmp(mode, "failed")) { output("old error\nLASTERR\n",18); return 7; }
    else if (!strcmp(mode, "signal")) { raise(SIGTERM); return 92; }
    else if (!strcmp(mode, "identity")) identity();
    else if (!strcmp(mode, "descriptor")) { puts(fcntl(atoi(argv[2]),F_GETFD) < 0 ? "closed" : "inherited"); }
    else if (!strcmp(mode, "environment")) {
        char cwd[4096], byte;
        if (!getcwd(cwd,sizeof(cwd))) return 93;
        printf("%s\n%s\n%s\nstdin-eof=%d\nhome-absent=%d\n",cwd,getenv("RUNNER_SENTINEL"),argv[2],read(0,&byte,1)==0,getenv("HOME")==NULL);
    } else if (!strcmp(mode, "grandchild")) {
        identity();
        int gate[2]; if (pipe(gate)) return 94;
        pid_t child = fork(); if (child < 0) return 95;
        if (child == 0) {
            pid_t grandchild = fork(); if (grandchild < 0) _exit(96);
            if (grandchild == 0) {
                alarm(8); signal(SIGTERM,SIG_IGN);
                FILE *f = fopen(argv[2],"w"); if (!f) _exit(97);
                fprintf(f,"%d\n",getpid()); fclose(f);
                write(gate[1],"x",1); close(gate[0]); close(gate[1]);
                for (;;) pause();
            }
            _exit(0);
        }
        close(gate[1]); char byte; read(gate[0],&byte,1); close(gate[0]);
        waitpid(child,NULL,0);
    } else if (!strcmp(mode,"utf8") || !strcmp(mode,"invalid-utf8")) {
        const unsigned char valid[] = {0x41,0xe4,0xb8,0xad,0xf0,0x9f,0x98,0x80,0x42};
        const unsigned char invalid[] = {0x61,0xe4,0xb8,0x62,0xff,0xf0,0x9f};
        int good = !strcmp(mode,"utf8");
        const unsigned char *bytes = good ? valid : invalid;
        size_t size = good ? sizeof(valid) : sizeof(invalid);
        for (size_t i=0; i<size; ++i) { output(bytes+i,1); usleep(40000); }
    } else if (!strcmp(mode,"tail-unicode")) {
        const unsigned char bytes[] = {0x41,0x41,0x41,0x41,0xf0,0x9f,0x98,0x80,0x5a}; output(bytes,sizeof(bytes));
    } else if (!strcmp(mode,"large")) {
        char block[8192]; memset(block,'x',sizeof(block));
        for (int i=0; i<640; ++i) output(block,sizeof(block));
        output("TAIL-END\n",9);
    } else {
        identity();
        if (!strcmp(mode,"ignore-term") || !strcmp(mode,"flood")) signal(SIGTERM,SIG_IGN);
        if (!strcmp(mode,"closed-output")) { close(1); close(2); }
        if (!strcmp(mode,"flood")) { char block[8192]; memset(block,'x',sizeof(block)); for (;;) output(block,sizeof(block)); }
        else for (;;) pause();
    }
    return 0;
}
"""#
