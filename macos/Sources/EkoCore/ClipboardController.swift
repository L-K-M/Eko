import AppKit
import Foundation

@MainActor
public protocol PasteboardWriting: AnyObject {
    var changeCount: Int { get }
    @discardableResult func writeConcealedString(_ value: String) -> Int
    func clear()
}

@MainActor
public final class SystemPasteboardWriter: PasteboardWriting {
    private let pasteboard: NSPasteboard
    private let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    public init(pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    public var changeCount: Int { pasteboard.changeCount }

    @discardableResult
    public func writeConcealedString(_ value: String) -> Int {
        pasteboard.clearContents()
        pasteboard.setString(value, forType: .string)
        pasteboard.setData(Data(), forType: concealedType)
        return pasteboard.changeCount
    }

    public func clear() {
        pasteboard.clearContents()
    }
}

@MainActor
public final class ClipboardController {
    private let pasteboard: any PasteboardWriting
    private let clock: any EkoClock
    private var clearTask: Task<Void, Never>?

    public init(pasteboard: any PasteboardWriting = SystemPasteboardWriter(), clock: any EkoClock = SystemEkoClock()) {
        self.pasteboard = pasteboard
        self.clock = clock
    }

    public func copy(_ value: String, clearAfter: TimeInterval? = 120) {
        clearTask?.cancel()
        let expectedChangeCount = pasteboard.writeConcealedString(value)
        guard let clearAfter, clearAfter > 0 else { return }
        let clock = self.clock
        clearTask = Task { [weak self] in
            try? await clock.sleep(for: .seconds(clearAfter))
            guard !Task.isCancelled, let self,
                  self.pasteboard.changeCount == expectedChangeCount else { return }
            self.pasteboard.clear()
        }
    }

    public func cancelPendingClear() {
        clearTask?.cancel()
        clearTask = nil
    }
}
