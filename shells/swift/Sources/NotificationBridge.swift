import AppKit
import Foundation
import UserNotifications
import WebKit

/// WKWebView 里没有 `window.Notification`，网页顶栏的铃铛点不亮。
///
/// 这里在网页加载前塞一个「只认本壳」的 Notification 替身：
///   - `permission` / `requestPermission()` → 读 / 问系统的通知授权
///   - `new Notification(...)` → 交给 UNUserNotificationCenter 弹一条本地通知
///
/// 脚本只注入这个窗口，浏览器和 PWA 里的网页一行都不用改。
final class NotificationBridge: NSObject, WKScriptMessageHandler, UNUserNotificationCenterDelegate {
    static let shared = NotificationBridge()
    static let messageName = "shellNotify"

    weak var webView: WKWebView?
    var activateWindow: (() -> Void)?

    /// 没跑在 .app 包里（比如终端直接跑可执行文件）时没有 bundle id，
    /// 通知中心用不了；宁可让网页按「不支持」显示，也别崩。
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// delegate 必须在 applicationDidFinishLaunching 返回前设好，
    /// 否则点系统通知时收不到回调。
    func install() {
        guard Self.available else { return }
        UNUserNotificationCenter.current().delegate = self
    }

    /// 启动时问一次系统授权状态，把结果写进注入脚本。
    /// 网页 boot() 会立刻按 Notification.permission 画铃铛，不能等异步回调。
    func currentPermission() -> String {
        guard Self.available else { return "default" }
        let box = LockedValue<String>("default")
        let semaphore = DispatchSemaphore(value: 0)
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let status = settings.authorizationStatus
            box.value = (status == .authorized || status == .provisional)
                ? "granted"
                : (status == .denied ? "denied" : "default")
            semaphore.signal()
        }
        // 正常是几毫秒；万一系统拖着不回话，也不能让启动卡死。
        if semaphore.wait(timeout: .now() + .milliseconds(400)) == .timedOut {
            NSLog("[easy-pi-shell] 查询通知授权超时，按「尚未授权」处理")
        }
        return box.value
    }

    func userScript(permission: String) -> WKUserScript {
        let source = """
        (function () {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.\(Self.messageName);
          if (!handler) return;
          var permission = \(Self.jsLiteral(permission));
          var pending = Object.create(null);
          var seq = 0;

          window.__easyPiNotify = {
            setPermission: function (value) { permission = value; },
            resolve: function (id, value) {
              permission = value;
              var done = pending[id];
              delete pending[id];
              if (done) done(value);
            }
          };

          function ShellNotification(title, options) {
            if (!(this instanceof ShellNotification)) return new ShellNotification(title, options);
            options = options || {};
            this.title = String(title == null ? "" : title);
            this.body = String(options.body == null ? "" : options.body);
            this.tag = String(options.tag == null ? "" : options.tag);
            handler.postMessage({ type: "show", title: this.title, body: this.body, tag: this.tag });
          }
          ShellNotification.prototype.close = function () {};
          Object.defineProperty(ShellNotification, "permission", {
            configurable: true,
            get: function () { return permission; }
          });
          ShellNotification.requestPermission = function (callback) {
            var id = ++seq;
            var promise = new Promise(function (resolve) {
              pending[id] = resolve;
              handler.postMessage({ type: "request", id: id });
            });
            if (typeof callback === "function") promise.then(callback);
            return promise;
          };
          try {
            Object.defineProperty(window, "Notification", {
              configurable: true, writable: true, value: ShellNotification
            });
          } catch (e) {
            window.Notification = ShellNotification;
          }

          // 网页原本优先走 Service Worker 的 showNotification，WKWebView 弹不出来。
          // 让 getRegistration 落空，统一退回上面这个替身（浏览器 / PWA 不注入这段）。
          if (typeof ServiceWorkerContainer !== "undefined" && ServiceWorkerContainer.prototype) {
            ServiceWorkerContainer.prototype.getRegistration = function () {
              return Promise.resolve(undefined);
            };
          }
        })();
        """
        return WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true)
    }

    // MARK: - 网页 → 原生

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
        switch type {
        case "request":
            let id = (body["id"] as? NSNumber)?.intValue ?? 0
            guard Self.available else {
                resolve(id, "denied")
                return
            }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
                if let error {
                    NSLog("[easy-pi-shell] 通知授权失败：%@", error.localizedDescription)
                }
                self?.resolve(id, granted ? "granted" : "denied")
            }
        case "show":
            guard Self.available else { return }
            let content = UNMutableNotificationContent()
            content.title = body["title"] as? String ?? "pi 已完成"
            content.body = body["body"] as? String ?? ""
            content.sound = .default
            let tag = (body["tag"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let request = UNNotificationRequest(
                identifier: tag.isEmpty ? UUID().uuidString : tag,
                content: content,
                trigger: nil
            )
            UNUserNotificationCenter.current().add(request) { error in
                if let error {
                    NSLog("[easy-pi-shell] 通知发送失败：%@", error.localizedDescription)
                }
            }
        default:
            break
        }
    }

    private func resolve(_ id: Int, _ permission: String) {
        DispatchQueue.main.async { [weak self] in
            let js = "window.__easyPiNotify && window.__easyPiNotify.resolve(\(id), \(Self.jsLiteral(permission)))"
            self?.webView?.evaluateJavaScript(js)
        }
    }

    // MARK: - 通知中心回调

    /// App 在前台也要把横幅弹出来，否则点击「完成通知」却什么也看不见。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    /// 点通知把窗口叫回前台（网页里 notificationclick 那套是给 Service Worker 用的）。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        DispatchQueue.main.async { [weak self] in
            NSApp.activate(ignoringOtherApps: true)
            self?.activateWindow?()
            completionHandler()
        }
    }

    private static func jsLiteral(_ text: String) -> String {
        guard let data = try? JSONEncoder().encode(text), let json = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return json
    }
}

/// 查询授权用的是异步回调，这里给个带锁的小盒子，超时后回调再回来也不会踩到野内存。
private final class LockedValue<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: T

    init(_ value: T) { storage = value }

    var value: T {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock()
            storage = newValue
            lock.unlock()
        }
    }
}
