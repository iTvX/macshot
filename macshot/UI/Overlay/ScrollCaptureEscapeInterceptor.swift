import Cocoa

/// Catches Escape for an active scroll capture while another app has keyboard
/// focus, and swallows it so the app being captured doesn't also act on it.
///
/// The event tap runs on its own thread: a tap serviced by the main run loop
/// holds back the whole session's input whenever the main thread is busy.
nonisolated final class ScrollCaptureEscapeInterceptor: @unchecked Sendable {

    private let onEscape: @Sendable () -> Void
    private let lock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var stopped = false
    private var installed = false

    init(onEscape: @escaping @Sendable () -> Void) {
        self.onEscape = onEscape
    }

    /// Plain Escape, with or without Shift. Chords stay with their app.
    static func isCancelKey(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == 53 && flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
    }

    /// Starts the tap. False when it can't be installed (no Accessibility
    /// access), in which case the caller falls back to event monitors.
    func start() -> Bool {
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let mask = CGEventMask(1 << CGEventType.keyDown.rawValue)
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                eventsOfInterest: mask, callback: escapeTapCallback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()),
                  let source = CFMachPortCreateRunLoopSource(nil, tap, 0) else {
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            lock.lock()
            let cancelledEarly = stopped
            if !cancelledEarly {
                self.tap = tap
                runLoop = loop
                installed = true
            }
            lock.unlock()
            guard !cancelledEarly else {
                CFMachPortInvalidate(tap)
                ready.signal()
                return
            }
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            ready.signal()
            // Retained by the thread until the tap is gone, so a callback can
            // never reach a freed interceptor.
            withExtendedLifetime(self) { CFRunLoopRun() }
            CFRunLoopRemoveSource(loop, source, .commonModes)
            CFMachPortInvalidate(tap)
        }
        thread.name = "macshot.scrollcapture.escape"
        thread.qualityOfService = .userInteractive
        thread.start()
        _ = ready.wait(timeout: .now() + 1)
        lock.lock()
        defer { lock.unlock() }
        return installed
    }

    func stop() {
        lock.lock()
        stopped = true
        let tap = self.tap, loop = runLoop
        self.tap = nil
        runLoop = nil
        lock.unlock()
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let loop { CFRunLoopStop(loop) }
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            let tap = stopped ? nil : self.tap
            lock.unlock()
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard Self.isCancelKey(keyCode: keyCode, flags: event.flags) else {
                return Unmanaged.passUnretained(event)
            }
            lock.lock()
            let active = !stopped
            lock.unlock()
            guard active else { return Unmanaged.passUnretained(event) }
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { onEscape() }
            return nil
        default:
            return Unmanaged.passUnretained(event)
        }
    }
}

nonisolated private func escapeTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                               userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let interceptor = Unmanaged<ScrollCaptureEscapeInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
    return interceptor.handle(type: type, event: event)
}
