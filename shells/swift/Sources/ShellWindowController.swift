import AppKit
import WebKit

/// 一个窗口 + 一个 WKWebView + 一块「正在启动」遮罩。
///
/// 网页里 `<a download>` 的下载（导出会话、下载文件）走 WKDownload，
/// 存到「下载」文件夹并在访达里选中。
///
/// WKUIDelegate 是给 `<input type=file>` 用的：网页点附件回形针时，
/// WebKit 会来要一个文件选择面板，不给就什么反应都没有。
final class ShellWindowController: NSObject, WKNavigationDelegate, WKDownloadDelegate, WKUIDelegate {
    let window: NSWindow
    private(set) var webView: WKWebView!
    var onRetry: (() -> Void)?

    private let overlay = NSView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "正在启动 pi 服务…")
    private let spinner = NSProgressIndicator()
    private let retryButton = NSButton(title: "重试", target: nil, action: nil)
    private let dragStrip = DragStripView()
    private let scriptHandler = ShellScriptHandler()
    private var dragHeight: NSLayoutConstraint?
    private var originalLightX: [UInt: CGFloat] = [:]
    private var trafficLightShift: CGFloat = 0
    private var destinations: [ObjectIdentifier: URL] = [:]

    override init() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1240, height: 840),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init()

        scriptHandler.controller = self

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidResize),
            name: NSWindow.didResizeNotification,
            object: window
        )

        let bridge = NotificationBridge.shared
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.userContentController.add(scriptHandler, name: "shellLayout")
        configuration.userContentController.add(bridge, name: NotificationBridge.messageName)
        configuration.userContentController.addUserScript(bridge.userScript(permission: bridge.currentPermission()))
        webView = WKWebView(frame: .zero, configuration: configuration)
        bridge.webView = webView
        bridge.activateWindow = { [weak self] in
            self?.window.makeKeyAndOrderFront(nil)
        }

        window.title = "Easy-Pi"
        window.minSize = NSSize(width: 760, height: 560)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("EasyPiWebUIWindow")
        window.center()

        // 不要标题栏：标题文字隐藏、标题栏透明，网页铺满整窗，
        // 红黄绿三个按钮浮在网页左上角。
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.titlebarSeparatorStyle = .none
        window.isMovableByWindowBackground = true

        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        if #available(macOS 13.3, *) {
            // 允许 Safari 的「开发」菜单连上来调试这个网页
            webView.isInspectable = true
        }

        buildLayout()
    }

    /// 壳专用样式：给红黄绿三个按钮和顶部拖动区让位。
    /// 只注入到这个窗口，网页项目和浏览器里的版本不受影响。
    ///
    /// 顶栏压到 40px，再把三个按钮往下移到顶栏的垂直中心（见 alignTrafficLights），
    /// 两边就对在同一行上了。折叠按钮不动，一直在顶栏左侧。
    private func shellStyleJS() -> String {
        let inset = Int(trafficLightInset.rounded())
        let css = """
        /* 网页顶边那条线是给浏览器窗口用的，壳里没有标题栏，不需要 */
        .app { border-top: 0 !important; }
        /* 顶栏 52px，内容中心 26pt，和红黄绿三个按钮的中心对齐 */
        /* 53 而不是 52：border-box 下要扣掉 1px 下边框，内容区才是 52，中心正好 26 */
        .topbar { height: 53px !important; }
        /* 侧栏品牌行：下移到按钮下面，左边和按钮左边缘对齐（原 10+6=16 → 9） */
        /* 只补顶部：品牌行的左右对齐交给网页 CSS，两边保持一致 */
        .sidebar-head { padding-top: 38px !important; }
        /* --easy-pi-shell-left 由网页实测「新对话」左边缘后写入，下面再补按钮宽度 60 + 间隙 14 */
        .app.sidebar-hidden .topbar { padding-left: calc(var(--easy-pi-shell-left, \(inset)px) + 74px) !important; }
        /* 会话列表右边缘的对齐已交给网页自己实测（app.js 的 syncSessionPad）。
           壳不再硬编码补 10px：不同 WebKit 版本滚动条占不占宽度不一样，猜会猜错。 */
        /* 折叠按钮放进侧栏时：钉在右上角，和红绿灯同一行（中心 26pt，按钮 30pt → top 11） */
        .sidebar > #menuBtn { position: absolute; top: 11px; right: 10px; z-index: 5; }
        """
        return """
        (function () {
          var style = document.createElement('style');
          style.id = 'easy-pi-shell-style';
          style.textContent = \(Self.jsLiteral(css));
          document.head.appendChild(style);

          var sidebar = document.querySelector('.sidebar');
          var app = document.getElementById('app');
          var topbar = document.querySelector('.topbar');
          var toggle = document.getElementById('menuBtn');
          if (!sidebar || !app || !topbar || !toggle) { return; }

          function placeToggle(collapsed) {
            if (collapsed) {
              if (toggle.parentElement !== topbar) { topbar.insertBefore(toggle, topbar.firstChild); }
            } else if (toggle.parentElement !== sidebar) {
              sidebar.appendChild(toggle);
            }
          }

          // 量一次「新对话」的左边缘：品牌行靠 CSS 自己对齐，这个值给壳算三个按钮的 x
          var newChat = document.querySelector('.new-chat');
          if (newChat) {
            var contentLeft = newChat.getBoundingClientRect().left;
            document.documentElement.style.setProperty('--easy-pi-shell-left', contentLeft + 'px');
            window.webkit.messageHandlers.shellLayout.postMessage({ contentLeft: contentLeft });
          }

          // 顶栏里这几块矩形要留给网页：按钮得能点、能悬停；其余都用来拖窗口。
          function rectOf(node) {
            if (!node) return null;
            var r = node.getBoundingClientRect();
            if (!r.width || !r.height) return null;
            return { x: r.left, y: r.top, w: r.width, h: r.height };
          }

          function hotRects(collapsed) {
            var nodes = [
              document.getElementById('menuBtn'),
              document.getElementById('sidebarResizer')
            ];
            // 顶栏右侧按钮（现在是「…」设置菜单）：先取具体 id，再把 .topbar-right 里
            // 其余按钮一并收进来，以后加顶栏按钮不用改壳。
            var settings = document.getElementById('settingsBtn');
            if (settings) nodes.push(settings);
            var extras = document.querySelectorAll('.topbar-right button');
            for (var j = 0; j < extras.length; j++) {
              if (nodes.indexOf(extras[j]) === -1) nodes.push(extras[j]);
            }
            if (!collapsed) nodes.push(document.querySelector('.sidebar-head .brand'));
            var out = [];
            for (var i = 0; i < nodes.length; i++) {
              var r = rectOf(nodes[i]);
              if (r) out.push(r);
            }
            return out;
          }

          function report() {
            var collapsed = app.classList.contains('sidebar-hidden');
            placeToggle(collapsed);
            var width = collapsed ? 0 : Math.round(sidebar.getBoundingClientRect().width);
            window.webkit.messageHandlers.shellLayout.postMessage({
              width: width,
              collapsed: collapsed,
              bandHeight: Math.round(topbar.getBoundingClientRect().bottom),
              hotRects: hotRects(collapsed)
            });
          }

          if (!window.__easyPiShellLayout) {
            window.__easyPiShellLayout = true;
            if (window.ResizeObserver) { new ResizeObserver(report).observe(sidebar); }
            new MutationObserver(report).observe(app, { attributes: true, attributeFilter: ['class'] });
            window.addEventListener('resize', report);
          }
          report();
        })();
        """
    }

    /// 把红黄绿三个按钮往下移，让它们的垂直中心和顶栏（40px）的中心对齐。
    /// 按钮仍在标题栏视图的范围内，点击不受影响；窗口缩放后系统会重排版，所以每次都重设。
    func alignTrafficLights() {
        let targetCenterFromTop: CGFloat = 26
        for kind in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            guard let button = window.standardWindowButton(kind), let bar = button.superview else { continue }
            let key = kind.rawValue
            if originalLightX[key] == nil { originalLightX[key] = button.frame.origin.x }
            let x = (originalLightX[key] ?? button.frame.origin.x) + trafficLightShift
            let y = bar.bounds.height - (targetCenterFromTop + button.frame.height / 2)
            button.setFrameOrigin(NSPoint(x: x, y: y))
        }
    }

    @objc private func windowDidResize() {
        alignTrafficLights()
    }

    /// 三个按钮右边缘再加一点间隙：侧栏收起时顶栏内容从这里开始。
    private var trafficLightInset: CGFloat {
        guard let zoom = window.standardWindowButton(.zoomButton) else { return 86 }
        return zoom.frame.maxX + 14
    }

    /// 网页报回侧栏宽度和折叠状态，拖动区跟着改宽度。
    fileprivate func handleShellMessage(_ message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }

        // 网页量出「新对话」的左边缘，红黄绿三个按钮跟着挪到同一个 x
        if let contentLeft = (body["contentLeft"] as? NSNumber)?.doubleValue {
            let base = originalLightX[NSWindow.ButtonType.closeButton.rawValue] ?? 9
            trafficLightShift = CGFloat(contentLeft) - base
            alignTrafficLights()
        }

        // 拖动区盖住整条顶栏：高度跟网页量出来的顶栏一致，
        // 顶栏按钮所在的矩形让网页自己接事件（见 DragStripView.hitTest）。
        if let height = (body["bandHeight"] as? NSNumber)?.doubleValue {
            dragHeight?.constant = min(max(CGFloat(height), 34), 90)
        }
        if let rects = body["hotRects"] as? [[String: Any]] {
            dragStrip.hotRects = rects.compactMap { rect in
                guard let x = (rect["x"] as? NSNumber)?.doubleValue,
                      let y = (rect["y"] as? NSNumber)?.doubleValue,
                      let w = (rect["w"] as? NSNumber)?.doubleValue,
                      let h = (rect["h"] as? NSNumber)?.doubleValue else { return nil }
                return NSRect(x: x, y: y, width: w, height: h)
            }
        }
    }

    private static func jsLiteral(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }

    private func buildLayout() {
        let container = NSView()

        webView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(webView)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        overlay.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        container.addSubview(overlay)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.alignment = .center
        statusLabel.isSelectable = true
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        retryButton.target = self
        retryButton.action = #selector(retry)
        retryButton.bezelStyle = .rounded
        retryButton.isHidden = true
        retryButton.translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: [spinner, statusLabel, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        overlay.addSubview(stack)

        // 整条顶栏都是拖动区（侧栏头顶 + 主界面顶栏），放在最上层。
        // 网页报回来的按钮矩形会被放行，按钮照常能点、能悬停。
        dragStrip.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(dragStrip)
        let height = dragStrip.heightAnchor.constraint(equalToConstant: 53)
        dragHeight = height

        NSLayoutConstraint.activate([
            webView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            webView.topAnchor.constraint(equalTo: container.topAnchor),
            webView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            overlay.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: container.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            dragStrip.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            dragStrip.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            dragStrip.topAnchor.constraint(equalTo: container.topAnchor),
            height,

            stack.centerXAnchor.constraint(equalTo: overlay.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: overlay.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 560),
            statusLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
        ])

        window.contentView = container
    }

    // MARK: - 遮罩

    func showStarting() {
        statusLabel.stringValue = "正在启动 pi 服务…"
        statusLabel.textColor = .secondaryLabelColor
        retryButton.isHidden = true
        spinner.isHidden = false
        spinner.startAnimation(nil)
        overlay.isHidden = false
    }

    func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        statusLabel.stringValue = message
        statusLabel.textColor = .labelColor
        retryButton.isHidden = false
        overlay.isHidden = false
    }

    @objc private func retry() {
        onRetry?()
    }

    // MARK: - 载入

    func load(_ url: URL) {
        webView.load(URLRequest(url: url))
    }

    func reload() {
        if webView.url == nil {
            onRetry?()
        } else {
            webView.reload()
        }
    }

    /// 「编辑 → 查找会话」(⌘F)。菜单拦截了按键，这里补发一次同样的键盘事件，
    /// 让网页里那套快捷键逻辑（含展开侧栏）保持唯一一份。
    func focusSearch() {
        let js = "document.dispatchEvent(new KeyboardEvent('keydown', { key: 'f', metaKey: true, bubbles: true, cancelable: true }));"
        webView.evaluateJavaScript(js)
    }

    // MARK: - WKNavigationDelegate

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // `<a download>` 的点击（导出会话、下载文件）走下载通道，
        // 否则 WKWebView 会当成一次导航、什么都不发生。
        if navigationAction.shouldPerformDownload {
            decisionHandler(.download)
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        download.delegate = self
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        NSLog("[easy-pi-shell] 页面已载入：%@", webView.url?.absoluteString ?? "")
        webView.evaluateJavaScript(shellStyleJS()) { _, error in
            if let error {
                NSLog("[easy-pi-shell] 样式注入失败：%@", error.localizedDescription)
            }
            self.overlay.isHidden = true
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        reportLoadFailure(error)
    }

    private func reportLoadFailure(_ error: Error) {
        let code = (error as NSError).code
        // 主动取消的导航（-999）不算失败
        guard code != NSURLErrorCancelled else { return }
        NSLog("[easy-pi-shell] 页面载入失败：%@", error.localizedDescription)
        showFailure("页面打不开：\(error.localizedDescription)\n\n服务可能已经退出，点「重试」重新拉起。")
    }

    // MARK: - WKUIDelegate

    /// 网页里的 `<input type=file>`（附件回形针）点了要弹「打开」面板。
    /// 不实现这个方法，点击就完全没反应；必须回调 completionHandler，
    /// 取消时传 nil，否则网页那边会一直等下去。
    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo,
        completionHandler: @escaping ([URL]?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        // 网页要求「只能选文件」时，这里就不让选文件夹
        panel.canChooseDirectories = parameters.allowsDirectories
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canCreateDirectories = false
        panel.prompt = "选择"
        panel.message = "选择要上传的文件"

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            if response == .OK {
                completionHandler(panel.urls)
            } else {
                completionHandler(nil)
            }
        }

        // 挂在窗口上（sheet），不抢焦点也不挡拖拽和粘贴
        panel.beginSheetModal(for: window, completionHandler: finish)
    }

    // MARK: - WKDownloadDelegate

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        let fileManager = FileManager.default
        let folder = fileManager.urls(for: .downloadsDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        let name = suggestedFilename.isEmpty ? "download" : suggestedFilename
        let target = Self.uniqueURL(in: folder, filename: name)
        destinations[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let target = destinations.removeValue(forKey: ObjectIdentifier(download)) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([target])
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        destinations.removeValue(forKey: ObjectIdentifier(download))
        let alert = NSAlert()
        alert.messageText = "下载失败"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func uniqueURL(in folder: URL, filename: String) -> URL {
        let fileManager = FileManager.default
        let base = (filename as NSString).deletingPathExtension
        let ext = (filename as NSString).pathExtension
        var candidate = folder.appendingPathComponent(filename)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(index)" : "\(base) \(index).\(ext)"
            candidate = folder.appendingPathComponent(next)
            index += 1
        }
        return candidate
    }
}

/// 盖住整条顶栏的透明拖动区。
/// hotRects 是网页报回来的按钮位置：落在里面的点击/悬停交还给网页，
/// 其余区域按住就拖窗口。
private final class DragStripView: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    /// 坐标跟网页 getBoundingClientRect() 一致：左上为原点，单位是 pt。
    var hotRects: [NSRect] = []

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview, !isHidden else { return nil }
        let local = convert(point, from: parent)
        guard bounds.contains(local) else { return nil }
        for rect in hotRects where rect.insetBy(dx: -3, dy: -3).contains(local) {
            return nil
        }
        return self
    }

    // 只靠 mouseDownCanMoveWindow 在这套配置下不生效，显式发起拖动。
    override func mouseDown(with event: NSEvent) {
        window?.performDrag(with: event)
    }
}

/// 弱引用转发：userContentController 会强持 handler，
/// 直接传 self 会跟 webView 形成环。
private final class ShellScriptHandler: NSObject, WKScriptMessageHandler {
    weak var controller: ShellWindowController?

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        controller?.handleShellMessage(message)
    }
}
