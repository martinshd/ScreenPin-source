import AppKit

enum SaveService {

    /// 静默保存 PNG 到桌面，文件名带时间戳；同秒冲突时自动追加序号。
    @discardableResult
    static func savePNGToDesktop(_ image: CGImage) throws -> URL {
        let data = try pngData(from: image)
        let desktop = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Desktop", isDirectory: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd_HHmmss"
        let base = "ScreenPin_\(formatter.string(from: Date()))"
        var url = desktop.appendingPathComponent("\(base).png")
        var index = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = desktop.appendingPathComponent("\(base)_\(index).png")
            index += 1
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    static func copyToPasteboard(_ image: CGImage) {
        guard let data = try? pngData(from: image) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: .png)
    }

    /// 把文件路径文本写入剪贴板（覆盖原有内容，包括截图时自动复制的图像）
    static func copyPathToPasteboard(_ path: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(path, forType: .string)
    }

    private static func pngData(from image: CGImage) throws -> Data {
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "ScreenPin",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "PNG 编码失败"]
            )
        }
        return data
    }
}
