import Foundation

/// WebSocket client for ws://127.0.0.1:8765/bridge with automatic 1 s reconnect.
/// Text frames only. All callbacks run on `queue`.
public final class BridgeSocket: NSObject, URLSessionWebSocketDelegate {
    public let url: URL
    public var onOpen: (() -> Void)?
    public var onClose: (() -> Void)?
    public var onText: ((String) -> Void)?
    public var onLog: ((String) -> Void)?

    private let queue: DispatchQueue
    private var session: URLSession!
    private var task: URLSessionWebSocketTask?
    private var running = false
    private var isOpen = false
    private var loggedDown = false
    private var pingTimer: DispatchSourceTimer?

    public init(url: URL, queue: DispatchQueue) {
        self.url = url
        self.queue = queue
        super.init()
        queue.setSpecific(key: BridgeSocket.key, value: true)
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 5
        let opq = OperationQueue()
        opq.maxConcurrentOperationCount = 1
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: opq)
    }

    public var connected: Bool { isOpenOnQueue() }

    public func start() { queue.async { self.running = true; self.connect() } }

    public func stop() {
        queue.sync {
            running = false
            pingTimer?.cancel(); pingTimer = nil
            task?.cancel(with: .goingAway, reason: nil)
            task = nil
            isOpen = false
        }
        session.invalidateAndCancel()
    }

    /// Returns false when not connected (the message is dropped).
    @discardableResult
    public func send(_ text: String) -> Bool {
        guard isOpenOnQueue(), let t = task else { return false }
        t.send(.string(text)) { [weak self] err in
            if err != nil { self?.queue.async { self?.failed(t) } }
        }
        return true
    }

    private func isOpenOnQueue() -> Bool {
        if DispatchQueue.getSpecific(key: BridgeSocket.key) != nil { return isOpen }
        return queue.sync { isOpen }
    }
    private static let key = DispatchSpecificKey<Bool>()

    private func connect() {
        guard running else { return }
        let t = session.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            guard let self = self else { return }
            self.queue.async {
                guard t === self.task else { return }
                switch result {
                case .failure: self.failed(t)
                case .success(let msg):
                    if !self.isOpen { self.opened(t) }   // a frame arrived, so the socket is up
                    if case .string(let s) = msg { self.onText?(s) }
                    self.receive(t)
                }
            }
        }
    }

    private func opened(_ t: URLSessionWebSocketTask) {
        guard t === task, !isOpen else { return }
        isOpen = true
        loggedDown = false
        onLog?("bridge socket connected: \(url.absoluteString)")
        startPing()
        onOpen?()
    }

    private func failed(_ t: URLSessionWebSocketTask) {
        guard t === task else { return }
        let wasOpen = isOpen
        isOpen = false
        task = nil
        pingTimer?.cancel(); pingTimer = nil
        t.cancel(with: .goingAway, reason: nil)
        if wasOpen { onLog?("bridge socket closed; reconnecting every 1 s"); onClose?() }
        else if !loggedDown { loggedDown = true; onLog?("bridge socket not reachable (\(url.absoluteString)); retrying every 1 s") }
        guard running else { return }
        queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self, self.running, self.task == nil else { return }
            self.connect()
        }
    }

    private func startPing() {
        pingTimer?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 5, repeating: 5)
        timer.setEventHandler { [weak self] in
            guard let self = self, let t = self.task, self.isOpen else { return }
            t.sendPing { err in if err != nil { self.queue.async { self.failed(t) } } }
        }
        timer.resume()
        pingTimer = timer
    }

    // MARK: URLSessionWebSocketDelegate

    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didOpenWithProtocol protocol: String?) {
        queue.async { self.opened(webSocketTask) }
    }
    public func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask,
                           didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        queue.async { self.failed(webSocketTask) }
    }
    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let t = task as? URLSessionWebSocketTask else { return }
        queue.async { self.failed(t) }
    }
}
