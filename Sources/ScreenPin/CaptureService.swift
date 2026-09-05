import ScreenCaptureKit
import CoreGraphics
import AppKit

/// 调试日志：追加写入 ~/Library/Logs/ScreenPin.log（macOS 应用日志惯例位置，
/// 控制台 App 可直接查看，好找好删）。超过 512KB 自动滚动为 ScreenPin.old.log，
/// 只保留一代，总量可控。
enum DebugLog {
    private static let logURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenPin.log")
    private static let oldURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/ScreenPin.old.log")
    private static let maxBytes: UInt64 = 512 * 1024

    static func log(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        rotateIfNeeded()
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    private static func rotateIfNeeded() {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: logURL.path),
              let size = attrs[.size] as? UInt64,
              size > maxBytes else { return }
        try? fm.removeItem(at: oldURL)
        try? fm.moveItem(at: logURL, to: oldURL)
    }
}

enum CaptureError: LocalizedError {
    case noPermission
    case noDisplay
    case emptyRect

    var errorDescription: String? {
        switch self {
        case .noPermission: return L("No screen recording permission")
        case .noDisplay: return L("No matching display found")
        case .emptyRect: return L("Selection is outside all displays")
        }
    }
}

enum CaptureService {

    /// 仅预检，不触发系统授权弹窗
    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// 预检屏幕录制权限；未授权时触发系统授权流程。
    /// - Returns: 当前是否已授权
    @discardableResult
    static func ensurePermission() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        CGRequestScreenCaptureAccess()
        return CGPreflightScreenCaptureAccess()
    }

    static func openScreenRecordingSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    static func showPermissionAlert() {
        NSApplication.shared.activate()
        let alert = NSAlert()
        alert.messageText = L("Screen Recording Permission Required")
        alert.informativeText = L("ScreenPin needs Screen Recording permission to snip. Enable it in System Settings; if it still does not work after granting, restart the app.")
        alert.addButton(withTitle: L("Open System Settings"))
        alert.addButton(withTitle: L("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    /// 捕获所有显示器的整屏快照（排除自身窗口，其余全部包含，
    /// 因此下拉菜单等瞬态 UI 会被定格进快照）。
    /// 返回每块屏的全局 CG 坐标 frame 与对应图像（像素 = point × pointPixelScale）。
    static func captureAllDisplays() async throws -> [(frame: CGRect, image: CGImage)] {
        guard ensurePermission() else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let pid = ProcessInfo.processInfo.processIdentifier
        let ownWindows = content.windows.filter { $0.owningApplication?.processID == pid }
        var result: [(frame: CGRect, image: CGImage)] = []
        for display in content.displays {
            let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
            let config = SCStreamConfiguration()
            config.width = max(1, Int((display.frame.width * CGFloat(filter.pointPixelScale)).rounded()))
            config.height = max(1, Int((display.frame.height * CGFloat(filter.pointPixelScale)).rounded()))
            config.showsCursor = false
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            result.append((frame: display.frame, image: image))
        }
        DebugLog.log("ScreenPin: backdrops=\(result.map { "\($0.frame)->\($0.image.width)x\($0.image.height)" })")
        return result
    }
}
