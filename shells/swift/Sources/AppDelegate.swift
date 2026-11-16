import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: ShellWindowController?
    private var server: ServerProcess?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 通知中心要在启动流程结束前认好 delegate，点击系统通知才能把窗口叫回来
        NotificationBridge.shared.install()
        buildMenu()
        installSignalHandlers()

        guard let directory = resolveDirectory() else {
            NSApp.terminate(nil)
            return
        }
        NSLog("[easy-pi-shell] 服务目录：%@", directory.path)

        let port = Int(ProcessInfo.processInfo.environment["PORT"] ?? "") ?? ServerProcess.defaultPort
        let server = ServerProcess(directory: directory, port: port)
        self.server = server

        let controller = ShellWindowController()
        controller.onRetry = { [weak self] in self?.runServer() }
        self.controller = controller

        controller.showStarting()
        controller.window.makeKeyAndOrderFront(nil)
        controller.alignTrafficLights()
        NSApp.activate(ignoringOtherApps: true)

        runServer()
    }

    /// 起服务；成功后把网页装进窗口，失败就把原因写在遮罩上。
    private func runServer() {
        guard let server else { return }
        controller?.showStarting()
        server.start { [weak self] result in
            switch result {
            case .ready:
                self?.controller?.load(server.baseURL)
            case .failed(let message):
                NSLog("[easy-pi-shell] 启动失败：%@", message)
                self?.controller?.showFailure(message)
            }
        }
    }

    private func resolveDirectory() -> URL? {
        if let directory = ServerLocator.locate() {
            return directory
        }
        let alert = NSAlert()
        alert.messageText = "找不到 easy-pi 项目"
        alert.informativeText = "请选一次 node-server/easy-pi 目录（里面有 server.js），选完会记住。"
        alert.addButton(withTitle: "选择目录…")
        alert.addButton(withTitle: "退出")
        guard alert.runModal() == .alertFirstButtonReturn, let picked = ServerLocator.askUser() else {
            return nil
        }
        ServerLocator.save(picked)
        return picked
    }

    // MARK: - 生命周期

    /// `kill` 和系统关机发的 SIGTERM 默认会直接结束进程，
    /// 那样自己起的 node 就漏在外面了。接住信号，走正常退出流程。
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler {
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// 关窗即退出。退出前只回收自己起的那个 node，终端里跑的不动。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        server?.stopAndWait()
        return .terminateNow
    }

    // MARK: - 菜单

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(
            withTitle: "关于 Easy-Pi",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "隐藏 Easy-Pi",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "关闭窗口",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "退出 Easy-Pi",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // 没有这组菜单，⌘C / ⌘V 在网页里不会生效
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "编辑")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "撤销", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "重做", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenu.addItem(.separator())
        // WKWebView 没有系统查找栏；菜单项比网页按键更靠前，保证 ⌘F 一定生效。
        let find = NSMenuItem(title: "查找会话", action: #selector(findSessions), keyEquivalent: "f")
        find.target = self
        editMenu.addItem(find)

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "显示")
        viewItem.submenu = viewMenu
        let reload = NSMenuItem(title: "重新载入", action: #selector(reloadPage), keyEquivalent: "r")
        reload.target = self
        viewMenu.addItem(reload)

        NSApp.mainMenu = mainMenu
    }

    @objc private func reloadPage() {
        controller?.reload()
    }

    @objc private func findSessions() {
        controller?.focusSearch()
    }
}
