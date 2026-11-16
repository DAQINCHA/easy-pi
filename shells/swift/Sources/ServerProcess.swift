import Foundation

enum ServerStartResult {
    case ready
    case failed(String)
}

/// 管着 `node server.js` 这一个子进程。
///
/// 三种开局：
/// - 端口上已经跑着本项目的服务（终端里 `npm start` 起的）→ 直接复用，退出时也不动它
/// - 端口空着 → 起一个自己的，退出时发 SIGTERM 回收
/// - 端口被别的程序占着 → 报错，不猜
final class ServerProcess {
    static let defaultPort = 30142

    let directory: URL
    let port: Int
    private(set) var didSpawn = false

    private var process: Process?
    private var pipe: Pipe?
    private var outputTail = ""
    private var finished = false
    private var completion: ((ServerStartResult) -> Void)?
    private var pollTimer: Timer?
    private var deadline = Date.distantFuture

    init(directory: URL, port: Int) {
        self.directory = directory
        self.port = port
    }

    var baseURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    // MARK: - 启动

    func start(completion: @escaping (ServerStartResult) -> Void) {
        self.completion = completion
        finished = false
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            let ours = Self.serverAnswers(self.port)
            DispatchQueue.main.async {
                if ours {
                    self.finish(.ready)
                } else {
                    // 端口空不空不猜，直接起。真被占了 node 自己会报 EADDRINUSE，
                    // 那比任何试探都准。
                    self.launch()
                }
            }
        }
    }

    private func launch() {
        guard let node = NodeLocator.locate() else {
            finish(.failed("没找到 node。\n装一个 Node.js 22.19 或更新版本，或者用环境变量 PI_NODE 指定路径。"))
            return
        }

        let task = Process()
        task.executableURL = URL(fileURLWithPath: node)
        task.arguments = ["server.js", "--port", "\(port)"]
        task.currentDirectoryURL = directory
        task.standardInput = FileHandle.nullDevice

        let output = Pipe()
        task.standardOutput = output
        task.standardError = output
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            DispatchQueue.main.async { self?.consume(text) }
        }

        task.terminationHandler = { [weak self] ended in
            DispatchQueue.main.async { self?.handleExit(status: ended.terminationStatus) }
        }

        do {
            try task.run()
        } catch {
            finish(.failed("启动 node 失败：\(error.localizedDescription)"))
            return
        }

        process = task
        pipe = output
        didSpawn = true
        deadline = Date().addingTimeInterval(25)
        startPolling()
    }

    // MARK: - 就绪判断

    private func consume(_ text: String) {
        outputTail += text
        if outputTail.count > 8000 {
            outputTail = String(outputTail.suffix(4000))
        }
        guard !finished else { return }
        if outputTail.contains("listening on") {
            finish(.ready)
        } else if outputTail.contains("EADDRINUSE") {
            finish(.failed("端口 \(port) 被别的程序占用了。\n先关掉它，或者设置环境变量 PORT 换一个端口。\n\n\(tail())"))
        }
    }

    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            guard let self, !self.finished else { return }
            if Date() >= self.deadline {
                self.finish(.failed("等了 25 秒服务还没起来。\n\(self.tail())"))
                return
            }
            DispatchQueue.global(qos: .utility).async {
                guard Self.serverAnswers(self.port) else { return }
                DispatchQueue.main.async { self.finish(.ready) }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func handleExit(status: Int32) {
        guard !finished else { return }
        finish(.failed("pi 服务退出了（状态 \(status)）。\n\(tail())"))
    }

    private func tail() -> String {
        let trimmed = outputTail.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "（服务没有输出任何内容）" }
        return String(trimmed.suffix(800))
    }

    private func finish(_ result: ServerStartResult) {
        guard !finished else { return }
        finished = true
        pollTimer?.invalidate()
        pollTimer = nil
        let callback = completion
        completion = nil
        callback?(result)
    }

    // MARK: - 退出

    /// 只回收自己起的那个进程。先 SIGTERM，超时再 SIGKILL。
    ///
    /// 同步等待是故意的：AppKit 的「稍后退出」会在 `applicationShouldTerminate`
    /// 返回后跑一个嵌套事件循环，主队列的异步回调在那里面不一定会执行，
    /// 一等就卡死。退出时把主线程阻塞几秒可以接受。
    func stopAndWait(timeout: TimeInterval = 8) {
        pollTimer?.invalidate()
        pollTimer = nil
        pipe?.fileHandleForReading.readabilityHandler = nil

        guard let process, didSpawn, process.isRunning else { return }

        process.terminate()
        let limit = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < limit {
            usleep(100_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
    }

    // MARK: - 端口探测

    /// 端口上有没有本项目自己的服务：能拿到页面，且页面里有项目名。
    private static func serverAnswers(_ port: Int) -> Bool {
        var ours = false
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1.5
        configuration.waitsForConnectivity = false
        let session = URLSession(configuration: configuration)
        let url = URL(string: "http://127.0.0.1:\(port)/")!

        session.dataTask(with: url) { data, _, _ in
            if let data, let text = String(data: data, encoding: .utf8) {
                // 这是网页自己的标题（index.html 的 <title>），不是 App 名字，别跟着改
                ours = text.contains("Easy-Pi WebUI")
            }
            semaphore.signal()
        }.resume()

        _ = semaphore.wait(timeout: .now() + 3)
        session.invalidateAndCancel()
        return ours
    }
}
