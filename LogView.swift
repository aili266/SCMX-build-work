import AppKit
import SwiftUI

enum LogBuffer {
    static let maximumUTF16Count = 180_000
    static let retainedUTF16Count = 150_000

    static func appending(_ chunk: String, to current: String) -> String {
        let combined = current + chunk
        let value = combined as NSString
        guard value.length > maximumUTF16Count else { return combined }
        var start = value.length - retainedUTF16Count
        // Do not split a UTF-16 surrogate pair at the retained boundary.
        let unit = value.character(at:start)
        if (0xDC00...0xDFFF).contains(unit) { start += 1 }
        return value.substring(from:start)
    }
}

func runLogBufferTests() throws {
    func expect(_ condition: Bool, _ message: String) throws {
        guard condition else { throw NSError(domain:"SCMXLogTests",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
        print("PASS: " + message)
    }
    try expect(Thread.isMainThread,"Log tests run on the main thread without opening a window")

    var log = ""
    for chunk in LogStressFixture.chunks { log = LogBuffer.appending(chunk,to:log) }
    try expect((log as NSString).length <= LogBuffer.maximumUTF16Count,"Log buffer remains bounded after repeated build failures")
    try expect(log.hasSuffix(LogStressFixture.tailMarker + "\n"),"Log buffer preserves the newest error tail")

    let boundary = String(repeating:"a",count:30_002) + "\u{1F680}" + String(repeating:"b",count:149_999)
    let retained = LogBuffer.appending("",to:boundary)
    try expect(retained == String(repeating:"b",count:149_999),"Truncation skips a split UTF-16 surrogate pair")
    let unicodeTail = "\u{4E2D}\u{6587} e\u{301} \u{1F680}\n"
    let unicodeLog = LogBuffer.appending(unicodeTail,to:String(repeating:"x",count:180_001))
    try expect(unicodeLog.hasSuffix(unicodeTail) && !unicodeLog.contains("\u{FFFD}"),"Unicode errors survive buffer truncation intact")
    log = ""
    log = LogBuffer.appending("after-clear\n",to:log)
    try expect(log == "after-clear\n","Clearing the model leaves no stale log prefix")

    var deliveries: [String] = []
    var order: [String] = []
    let coalescer = LogOutputCoalescer { chunk in
        deliveries.append(chunk)
        order.append("output")
    }
    let producerDone = DispatchSemaphore(value:0)
    DispatchQueue.global(qos:.userInitiated).async {
        let chunk = String(repeating:"error: missing_symbol; ",count:380) + "\u{1F680}\n"
        for _ in 0..<2_048 { coalescer.append(chunk) }
        coalescer.append("COALESCER_FINAL_ERROR\n")
        producerDone.signal()
    }
    // Deliberately block main while the producer submits more than 15 MiB.
    try expect(producerDone.wait(timeout:.now() + 15) == .success,"Background producer completes while main is blocked")
    try expect(deliveries.isEmpty,"Blocked main has not received premature deliveries")
    try expect(coalescer.pendingFlushCount == 1 && coalescer.enqueuedFlushCount == 1,"Thousands of chunks enqueue only one pending main flush")
    try expect(coalescer.bufferedUTF16Count <= LogBuffer.maximumUTF16Count,"Pending output remains bounded while main is blocked")
    coalescer.finish()
    order.append("completion")
    try expect(deliveries.count == 1 && deliveries[0].hasSuffix("COALESCER_FINAL_ERROR\n"),"Completion flush preserves the latest error tail")
    try expect(order == ["output","completion"],"Tail flush precedes the final operation state")
    try expect(coalescer.pendingFlushCount == 0 && coalescer.bufferedUTF16Count == 0,"Completion empties and cancels the pending flush")
    coalescer.finish()
    coalescer.append("late-output")
    try expect(deliveries.count == 1 && coalescer.bufferedUTF16Count == 0,"Completion is idempotent and rejects late output")

    var live: [String] = []
    let liveCoalescer = LogOutputCoalescer(interval:0.01) { live.append($0) }
    liveCoalescer.append("first\n")
    liveCoalescer.append("second\n")
    let deadline = Date().addingTimeInterval(2)
    while live.isEmpty && Date() < deadline {
        RunLoop.current.run(until:Date().addingTimeInterval(0.01))
    }
    try expect(live == ["first\nsecond\n"],"Scheduled main delivery preserves chunk order")
    liveCoalescer.append("last\n")
    liveCoalescer.finish()
    try expect(live.joined() == "first\nsecond\nlast\n","Scheduled delivery and final flush preserve stream order")
    print("LOG BUFFER TESTS PASSED")
}

final class LogOutputCoalescer {
    private let lock = NSLock()
    private let deliver: (String) -> Void
    private let interval: TimeInterval
    private var buffered = ""
    private var scheduled: DispatchWorkItem?
    private var finished = false
    private var scheduledCount = 0

    init(interval: TimeInterval = 0.05, deliver: @escaping (String) -> Void) {
        self.interval = max(0,interval)
        self.deliver = deliver
    }

    var pendingFlushCount: Int {
        lock.lock(); defer { lock.unlock() }
        return scheduled == nil ? 0 : 1
    }

    var bufferedUTF16Count: Int {
        lock.lock(); defer { lock.unlock() }
        return (buffered as NSString).length
    }

    var enqueuedFlushCount: Int {
        lock.lock(); defer { lock.unlock() }
        return scheduledCount
    }

    func append(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        guard !finished else { return }
        buffered = LogBuffer.appending(chunk,to:buffered)
        guard scheduled == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.flushScheduled() }
        scheduled = work
        scheduledCount += 1
        DispatchQueue.main.asyncAfter(deadline:.now() + interval,execute:work)
    }

    // The producer must have stopped before this main-thread completion barrier.
    func finish() {
        precondition(Thread.isMainThread)
        lock.lock()
        finished = true
        scheduled?.cancel()
        scheduled = nil
        let tail = buffered
        buffered = ""
        lock.unlock()
        if !tail.isEmpty { deliver(tail) }
    }

    private func flushScheduled() {
        precondition(Thread.isMainThread)
        lock.lock()
        scheduled = nil
        let chunk = buffered
        buffered = ""
        lock.unlock()
        if !chunk.isEmpty { deliver(chunk) }
    }
}

struct NativeLogView: NSViewRepresentable {
    let text: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> LogTextScrollView {
        let view = LogTextScrollView(frame:.zero)
        view.setLog(text)
        return view
    }

    func updateNSView(_ view: LogTextScrollView, context: Context) {
        context.coordinator.update(text,in:view)
    }

    static func dismantleNSView(_ view: LogTextScrollView, coordinator: Coordinator) {
        coordinator.cancel()
    }

    final class Coordinator {
        private var pending: String?
        private var work: DispatchWorkItem?

        func update(_ text: String, in view: LogTextScrollView) {
            if text.isEmpty {
                cancel()
                view.setLog("")
                return
            }
            pending = text
            guard work == nil else { return }
            let item = DispatchWorkItem { [weak self, weak view] in
                guard let self else { return }
                let latest = self.pending
                self.pending = nil
                self.work = nil
                if let latest, let view { view.setLog(latest) }
            }
            work = item
            DispatchQueue.main.asyncAfter(deadline:.now() + 0.075,execute:item)
        }

        func cancel() {
            work?.cancel()
            work = nil
            pending = nil
        }

        deinit { work?.cancel() }
    }
}

final class LogTextScrollView: NSScrollView {
    let logTextView = NSTextView(frame:.zero)
    private(set) var replacementCount = 0
    private(set) var incrementalAppendCount = 0
    private(set) var clearCount = 0

    override init(frame frameRect: NSRect) {
        super.init(frame:frameRect)
        hasVerticalScroller = true
        hasHorizontalScroller = true
        autohidesScrollers = true
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        borderType = .noBorder
        identifier = NSUserInterfaceItemIdentifier("SCMXRunLog")
        logTextView.isEditable = false
        logTextView.isSelectable = true
        logTextView.isRichText = false
        logTextView.allowsUndo = false
        logTextView.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        logTextView.textColor = .textColor
        logTextView.backgroundColor = .textBackgroundColor
        logTextView.textContainerInset = NSSize(width:14,height:14)
        logTextView.isHorizontallyResizable = true
        logTextView.isVerticallyResizable = true
        logTextView.autoresizingMask = []
        logTextView.minSize = .zero
        logTextView.maxSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        logTextView.textContainer?.widthTracksTextView = false
        logTextView.textContainer?.heightTracksTextView = false
        logTextView.textContainer?.containerSize = NSSize(width:CGFloat.greatestFiniteMagnitude,height:CGFloat.greatestFiniteMagnitude)
        documentView = logTextView
    }

    required init?(coder: NSCoder) { nil }

    override func tile() {
        let atBottom = contentView.bounds.maxY >= logTextView.frame.height - 28
        super.tile()
        resizeDocument()
        if atBottom {
            contentView.scroll(to:NSPoint(x:contentView.bounds.minX,y:max(0,logTextView.frame.height - contentSize.height)))
            reflectScrolledClipView(contentView)
        }
    }

    func setLog(_ value: String) {
        let previous = logTextView.string
        guard previous != value else { return }
        let visible = contentView.bounds
        let selection = logTextView.selectedRange()
        let followTail = previous.isEmpty || (selection.length == 0 && visible.maxY >= logTextView.frame.height - 28)
        let oldLength = (previous as NSString).length
        let newValue = value as NSString
        guard let storage = logTextView.textStorage else { return }

        storage.beginEditing()
        if value.hasPrefix(previous) && !previous.isEmpty {
            let delta = newValue.substring(from:oldLength)
            storage.append(NSAttributedString(string:delta,attributes:textAttributes))
            incrementalAppendCount += 1
        } else {
            storage.setAttributedString(NSAttributedString(string:value,attributes:textAttributes))
            replacementCount += 1
        }
        storage.endEditing()
        let location = min(selection.location,newValue.length)
        logTextView.setSelectedRange(NSRange(location:location,length:min(selection.length,newValue.length - location)))
        if let manager = logTextView.layoutManager, let container = logTextView.textContainer {
            manager.ensureLayout(for:container)
        }
        resizeDocument()
        if value.isEmpty {
            clearCount += 1
            logTextView.setSelectedRange(NSRange(location:0,length:0))
            contentView.scroll(to:.zero)
        } else if followTail {
            contentView.scroll(to:NSPoint(x:visible.minX,y:max(0,logTextView.frame.height - contentSize.height)))
        } else {
            contentView.scroll(to:visible.origin)
        }
        reflectScrolledClipView(contentView)
        logTextView.needsDisplay = true
    }

    private var textAttributes: [NSAttributedString.Key:Any] {
        [.font:NSFont.monospacedSystemFont(ofSize:12,weight:.regular),.foregroundColor:NSColor.textColor]
    }

    private func resizeDocument() {
        let used = logTextView.layoutManager.flatMap { manager in
            logTextView.textContainer.map { manager.usedRect(for:$0) }
        } ?? .zero
        let inset = logTextView.textContainerInset
        let size = NSSize(width:max(contentSize.width,ceil(used.maxX) + inset.width * 2),height:max(contentSize.height,ceil(used.maxY) + inset.height * 2))
        if logTextView.frame.size != size { logTextView.setFrameSize(size) }
    }
}

enum LogStressFixture {
    static let tailMarker = "SCMX_LOG_STRESS_TAIL: newest failure remains visible"

    static var chunks: [String] {
        let failures = (1...90).map { attempt in
            "Build attempt \(attempt) failed\n" + String(repeating:"Core/Src/main.c:128:17: error: undefined reference to peripheral_init; build stopped\n",count:45)
        }
        return failures + ["LONG_LINE: " + String(repeating:"undefined_reference_",count:2_000) + "\n",tailMarker + "\n"]
    }
}

enum LogViewDiagnostics {
    static func find(in root: NSView) -> LogTextScrollView? {
        if let log = root as? LogTextScrollView { return log }
        for child in root.subviews { if let log = find(in:child) { return log } }
        return nil
    }

    static func report(root: NSView, source: String, outputDirectory: String) -> String {
        var fields = ["logSourceUTF16Count=\((source as NSString).length)","logSourceNonempty=\(!source.isEmpty)"]
        guard let scroll = find(in:root) else { return (fields + ["nativeLogFound=false","nativeLogRendered=false"]).joined(separator:"\n") + "\n" }
        let text = scroll.logTextView
        let matches = text.string == source
        let glyphs: Int
        if let manager = text.layoutManager, let container = text.textContainer {
            let visible = text.visibleRect.offsetBy(dx:-text.textContainerInset.width,dy:-text.textContainerInset.height)
            glyphs = manager.glyphRange(forBoundingRect:visible,in:container).length
        } else { glyphs = 0 }
        let clip = scroll.contentView
        clip.displayIfNeeded()
        var inkPixels = 0
        var imageWritten = false
        if let bitmap = clip.bitmapImageRepForCachingDisplay(in:clip.bounds) {
            clip.cacheDisplay(in:clip.bounds,to:bitmap)
            if let background = bitmap.colorAt(x:0,y:0)?.usingColorSpace(.deviceRGB) {
                for y in stride(from:0,to:bitmap.pixelsHigh,by:2) {
                    for x in stride(from:0,to:bitmap.pixelsWide,by:2) {
                        if let pixel = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),
                           max(abs(pixel.redComponent - background.redComponent),abs(pixel.greenComponent - background.greenComponent),abs(pixel.blueComponent - background.blueComponent)) > 0.12 { inkPixels += 1 }
                    }
                }
            }
            if let png = bitmap.representation(using:.png,properties:[:]) {
                do {
                    try png.write(to:URL(fileURLWithPath:outputDirectory).appendingPathComponent("native-log-preview.png"))
                    imageWritten = true
                } catch { imageWritten = false }
            }
        }
        fields += ["nativeLogFound=true","nativeLogUTF16Count=\((text.string as NSString).length)","nativeLogMatchesSource=\(matches)","nativeLogVisibleGlyphs=\(glyphs)","nativeLogInkPixels=\(inkPixels)","nativeLogImageWritten=\(imageWritten)","nativeLogIncrementalAppends=\(scroll.incrementalAppendCount)","nativeLogReplacements=\(scroll.replacementCount)","nativeLogClears=\(scroll.clearCount)","nativeLogHorizontalOverflow=\(text.frame.width > clip.bounds.width)","nativeLogRendered=\(!source.isEmpty && matches && glyphs > 0 && inkPixels > 10 && imageWritten)"]
        return fields.joined(separator:"\n") + "\n"
    }
}
