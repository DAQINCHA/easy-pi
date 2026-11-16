import AppKit
import Foundation

/// 找到 easy-pi 项目目录（里面有 server.js 的那个）。
///
/// 顺序：环境变量 → 上次保存的 → 从 .app 所在位置往上找。
/// 都找不到时让用户自己选一次，选完记进 UserDefaults。
enum ServerLocator {
    static let defaultsKey = "easyPiWebUIServerDirectory"

    static func locate() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        if let raw = environment["PI_WEBUI_DIR"] {
            let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
            if isValid(url) { return url }
        }
        if let saved = UserDefaults.standard.string(forKey: defaultsKey) {
            let url = URL(fileURLWithPath: saved)
            if isValid(url) { return url }
        }
        // .app 在 shells/swift/build/ 下，往上几层就是项目根 easy-pi/ 本身；
        // 再往上（Coding/）也能拼出 node-server/easy-pi。
        var directory = Bundle.main.bundleURL
        for _ in 0..<10 {
            directory = directory.deletingLastPathComponent()
            if isValid(directory) { return directory }
            for candidate in [
                directory.appendingPathComponent("node-server/easy-pi"),
                directory.appendingPathComponent("easy-pi"),
            ] where isValid(candidate) {
                return candidate
            }
        }
        return nil
    }

    static func isValid(_ directory: URL) -> Bool {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: directory.appendingPathComponent("server.js").path) else {
            return false
        }
        return fileManager.fileExists(atPath: directory.appendingPathComponent("package.json").path)
    }

    static func save(_ directory: URL) {
        UserDefaults.standard.set(directory.path, forKey: defaultsKey)
    }

    /// 找不到时让用户指一次目录。取消返回 nil。
    static func askUser() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "使用这个目录"
        panel.message = "选择 easy-pi 项目目录（里面要有 server.js）"
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        guard isValid(url) else {
            let alert = NSAlert()
            alert.messageText = "这个目录里没有 server.js"
            alert.informativeText = "请选 node-server/easy-pi 那个目录。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return nil
        }
        return url
    }
}

/// 找 node 可执行文件。
///
/// 图形界面启动的 app 拿不到终端里的 PATH，所以这里直接查常见位置。
/// 都不行时用 PI_NODE 环境变量指定。
enum NodeLocator {
    static func locate() -> String? {
        let fileManager = FileManager.default
        if let raw = ProcessInfo.processInfo.environment["PI_NODE"] {
            let path = (raw as NSString).expandingTildeInPath
            if fileManager.isExecutableFile(atPath: path) { return path }
        }
        for path in ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node", "/opt/local/bin/node"]
        where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        // nvm 装的 node：取版本号最大的一个。
        let nvmRoot = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".nvm/versions/node")
        if let versions = try? fileManager.contentsOfDirectory(atPath: nvmRoot.path) {
            let sorted = versions.sorted { $0.compare($1, options: .numeric) == .orderedAscending }
            for version in sorted.reversed() {
                let path = nvmRoot.appendingPathComponent(version).appendingPathComponent("bin/node").path
                if fileManager.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }
}
