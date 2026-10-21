import Darwin
import Foundation

private final class LifetimeState: @unchecked Sendable {
    private let lock = NSLock()
    private var released = false

    func release() {
        lock.lock()
        released = true
        lock.unlock()
    }

    var isReleased: Bool {
        lock.lock()
        defer { lock.unlock() }
        return released
    }
}

private final class LifetimeProbe: NSObject {
    let state: LifetimeState
    init(_ state: LifetimeState) { self.state = state }
    deinit { state.release() }
}

private func makeAutoreleasedObject(_ state: LifetimeState) {
    typealias Autorelease = @convention(c) (UnsafeMutableRawPointer) -> UnsafeMutableRawPointer
    let library = dlopen(nil, RTLD_NOW)!
    defer { dlclose(library) }
    let function = unsafeBitCast(dlsym(library, "objc_autorelease")!, to: Autorelease.self)
    let object = LifetimeProbe(state)
    _ = function(Unmanaged.passRetained(object).toOpaque())
}

@main struct CoreExecutorAutoreleaseCheck {
    static func main() async {
        let asynchronous = LifetimeState()
        _ = await LogseqCoreExecutor.shared.call({ _ in
            makeAutoreleasedObject(asynchronous)
            return "done"
        }, requestJSON: "")
        precondition(asynchronous.isReleased, "Async core jobs must release temporary objects before completion")

        let synchronous = LifetimeState()
        _ = LogseqCoreExecutor.shared.callSync({ _ in
            makeAutoreleasedObject(synchronous)
            return "done"
        }, requestJSON: "")
        precondition(synchronous.isReleased, "Sync core jobs must release temporary objects before completion")
        print("PASS: synchronous and asynchronous core jobs drain their autorelease pools")
    }
}
