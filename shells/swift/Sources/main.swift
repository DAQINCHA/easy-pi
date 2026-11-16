import AppKit

// 单窗口壳：程序入口只负责把 NSApplication 立起来，
// 其余逻辑在 AppDelegate 里。
let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
