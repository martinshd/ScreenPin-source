import AppKit

/// 全屏选区覆盖层：先对全屏拍快照（此间不激活本 App，下拉菜单等瞬态 UI 不会收起），
/// 再把快照铺满覆盖层供框选，选区直接从快照裁剪，松手后由调用方原地贴屏。
final class SnipOverlayController {

    private var windows: [OverlayWindow] = []
    private var escMonitor: Any?
    private var didFinish = false
    private(set) var isActive = false

    /// 开始框选。completion 在主线程回调：成功时 image 非空、cocoaFrame 为选区在
    /// 全局 Cocoa 坐标系中的位置（供悬浮窗原地出现）；取消/失败时 image 为 nil。
    func begin(completion: @escaping (CGImage?, CGRect) -> Void) {
        if isActive {
            // 上次流程异常中断（如错误弹窗期间又触发）导致状态卡住：无窗口残留时自愈
            guard windows.isEmpty else { return }
            teardown()
        }
        guard CaptureService.ensurePermission() else {
            CaptureService.showPermissionAlert()
            completion(nil, .zero)
            return
        }
        isActive = true
        didFinish = false

        let finish: (CGImage?, CGRect) -> Void = { [weak self] image, frame in
            guard let self, !self.didFinish else { return }
            self.didFinish = true
            self.teardown()
            completion(image, frame)
        }

        // 先快照再建覆盖层；快照期间不激活本 App，下拉菜单等瞬态 UI 保持展开
        Task {
            do {
                let backdrops = try await CaptureService.captureAllDisplays()
                await MainActor.run { [weak self] in
                    self?.showOverlays(backdrops: backdrops, finish: finish)
                }
            } catch {
                await MainActor.run {
                    DebugLog.log("ScreenPin: snapshot failed: \(error)")
                    Self.showError(error)
                    finish(nil, .zero)
                }
            }
        }
    }

    /// 建覆盖层并进入框选
    private func showOverlays(backdrops: [(frame: CGRect, image: CGImage)],
                              finish: @escaping (CGImage?, CGRect) -> Void) {
        guard isActive, !didFinish else { return }

        for screen in NSScreen.screens {
            let cgFrame = Self.cgRect(fromCocoaRect: screen.frame)
            guard let backdrop = backdrops.first(where: { $0.frame == cgFrame })?.image
                ?? backdrops.max(by: {
                    $0.frame.intersection(cgFrame).width * $0.frame.intersection(cgFrame).height
                        < $1.frame.intersection(cgFrame).width * $1.frame.intersection(cgFrame).height
                })?.image else {
                DebugLog.log("ScreenPin: no backdrop for screen \(screen.frame)")
                Self.showError(CaptureError.noDisplay)
                finish(nil, .zero)
                return
            }
            let window = OverlayWindow(screen: screen, backdrop: backdrop)
            window.selectionView.onComplete = { [weak self] rectInView in
                guard let self, !self.didFinish else { return }
                let cocoaRect = rectInView.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)
                // 直接从快照裁剪，无需再次截图
                if let image = Self.crop(backdrop: backdrop, selection: rectInView, viewSize: screen.frame.size) {
                    DebugLog.log("ScreenPin: crop OK \(image.width)x\(image.height)")
                    finish(image, cocoaRect)
                } else {
                    DebugLog.log("ScreenPin: crop failed view=\(rectInView)")
                    Self.showError(CaptureError.emptyRect)
                    finish(nil, .zero)
                }
            }
            window.selectionView.onCancel = { finish(nil, .zero) }
            windows.append(window)
        }

        NSApplication.shared.activate()
        // 淡入显示：快照突然铺满 + 压暗会有"屏幕跳一下"的感觉，0.12s 淡入让定格过渡平滑
        for window in windows {
            window.alphaValue = 0
            window.orderFrontRegardless()
        }
        // 让鼠标所在那块屏的覆盖层成为 key window，接收 ESC
        let mouse = NSEvent.mouseLocation
        if let keyWindow = windows.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? windows.first {
            keyWindow.makeKey()
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            for window in windows { window.animator().alphaValue = 1 }
        }

        // 兜底：本地 ESC 监听
        escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // ESC
                finish(nil, .zero)
                return nil
            }
            return event
        }
    }

    /// 快照裁剪：selection 为视图坐标（左下原点，point），backdrop 为整屏快照（像素）
    static func crop(backdrop: CGImage, selection: CGRect, viewSize: CGSize) -> CGImage? {
        let pixelScale = CGFloat(backdrop.width) / viewSize.width
        let pixelRect = CGRect(
            x: selection.minX * pixelScale,
            y: (viewSize.height - selection.maxY) * pixelScale, // 视图 y 轴翻转为图像 y 轴
            width: selection.width * pixelScale,
            height: selection.height * pixelScale
        ).integral
        let imageBounds = CGRect(x: 0, y: 0, width: backdrop.width, height: backdrop.height)
        let clipped = pixelRect.intersection(imageBounds)
        guard clipped.width >= 1, clipped.height >= 1 else { return nil }
        return backdrop.cropping(to: clipped)
    }

    private func hideOverlays() {
        if let monitor = escMonitor {
            NSEvent.removeMonitor(monitor)
            escMonitor = nil
        }
        windows.forEach { $0.orderOut(nil) }
    }

    private func teardown() {
        hideOverlays()
        windows.removeAll()
        isActive = false
    }

    /// 全局 Cocoa 坐标（左下原点）→ 全局 CG 坐标（左上原点，单位 point）
    static func cgRect(fromCocoaRect cocoaRect: CGRect) -> CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? cocoaRect.maxY
        return CGRect(
            x: cocoaRect.minX,
            y: primaryHeight - cocoaRect.maxY,
            width: cocoaRect.width,
            height: cocoaRect.height
        )
    }

    private static func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Snip Failed")
        alert.informativeText = error.localizedDescription
        alert.runModal()
    }
}

// MARK: - 覆盖层窗口

private final class OverlayWindow: NSWindow {

    let selectionView: SnipSelectionView

    init(screen: NSScreen, backdrop: CGImage) {
        selectionView = SnipSelectionView(
            frame: NSRect(origin: .zero, size: screen.frame.size),
            backdrop: backdrop
        )
        // 注意：必须调指定初始化器（不带 screen: 的版本）。
        // 带 screen: 的是便捷初始化器，AppKit 内部会 self-call 回指定初始化器，
        // Swift 子类定义了自己的指定初始化器后未继承它，动态分发过去会 SIGTRAP。
        // 窗口位置由全局坐标 contentRect 决定，配合下方 constrainFrameRect 不做钳制，
        // 可精确落到任意屏幕（含扩展屏）。
        super.init(
            contentRect: screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        level = .screenSaver
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        animationBehavior = .none // 去掉系统默认的窗口出现动画，配合淡入避免"屏幕凸一下"
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentView = selectionView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    /// 不做屏幕钳制：默认实现会把初始位置不在主屏上的窗口钳回主屏可见区，
    /// 导致扩展屏覆盖层错位（扩展屏没有覆盖层、主屏叠两层）
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

// MARK: - 选区绘制与鼠标交互

final class SnipSelectionView: NSView {

    /// 框选完成（rect 为视图坐标，已钳制在本屏范围内）
    var onComplete: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var startPoint: NSPoint?
    private var currentPoint: NSPoint?
    /// 整屏快照
    private let backdrop: NSImage

    init(frame frameRect: NSRect, backdrop: CGImage) {
        self.backdrop = NSImage(cgImage: backdrop, size: frameRect.size)
        super.init(frame: frameRect)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func mouseDown(with event: NSEvent) {
        let point = clampedToBounds(convert(event.locationInWindow, from: nil))
        startPoint = point
        currentPoint = point
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        currentPoint = clampedToBounds(convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = startPoint else { return }
        let end = clampedToBounds(convert(event.locationInWindow, from: nil))
        startPoint = nil
        currentPoint = nil
        needsDisplay = true
        let rect = Self.normalized(start, end)
        if rect.width < 4 || rect.height < 4 {
            onCancel?() // 误触：单击或选区过小
        } else {
            onComplete?(rect)
        }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    /// 钳制在视图范围内：拖过屏幕边缘时坐标不外溢，避免越界/跨屏选区
    private func clampedToBounds(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    override func draw(_ dirtyRect: NSRect) {
        // 先铺快照，选区外压暗以突出所选内容
        backdrop.draw(in: bounds)
        NSColor.black.withAlphaComponent(startPoint == nil ? 0.15 : 0.35).setFill()
        if let start = startPoint, let current = currentPoint {
            let r = Self.normalized(start, current)
            NSRect(x: bounds.minX, y: r.maxY,
                   width: bounds.width, height: max(0, bounds.maxY - r.maxY)).fill()
            NSRect(x: bounds.minX, y: bounds.minY,
                   width: bounds.width, height: max(0, r.minY - bounds.minY)).fill()
            NSRect(x: bounds.minX, y: r.minY,
                   width: max(0, r.minX - bounds.minX), height: r.height).fill()
            NSRect(x: r.maxX, y: r.minY,
                   width: max(0, bounds.maxX - r.maxX), height: r.height).fill()
        } else {
            bounds.fill()
        }

        guard let start = startPoint, let current = currentPoint else { return }
        let rect = Self.normalized(start, current)
        guard rect.width > 0, rect.height > 0 else { return }

        // 选区边框
        NSColor.controlAccentColor.setStroke()
        let border = NSBezierPath(rect: rect.insetBy(dx: 0.75, dy: 0.75))
        border.lineWidth = 1.5
        border.stroke()

        // 尺寸标注
        let label = "\(Int(rect.width)) × \(Int(rect.height))" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white
        ]
        let labelSize = label.size(withAttributes: attrs)
        let padding: CGFloat = 6
        var labelOrigin = NSPoint(x: rect.minX, y: rect.maxY + 6)
        if labelOrigin.y + labelSize.height + padding * 2 > bounds.maxY {
            labelOrigin.y = rect.maxY - labelSize.height - padding * 2 - 6
        }
        labelOrigin.x = min(labelOrigin.x, bounds.maxX - labelSize.width - padding * 2 - 4)
        labelOrigin.x = max(labelOrigin.x, 4)
        let bgRect = NSRect(
            x: labelOrigin.x,
            y: labelOrigin.y,
            width: labelSize.width + padding * 2,
            height: labelSize.height + padding * 2
        )
        NSColor.black.withAlphaComponent(0.65).setFill()
        NSBezierPath(roundedRect: bgRect, xRadius: 4, yRadius: 4).fill()
        label.draw(at: NSPoint(x: bgRect.minX + padding, y: bgRect.minY + padding), withAttributes: attrs)
    }

    private static func normalized(_ a: NSPoint, _ b: NSPoint) -> CGRect {
        CGRect(
            x: min(a.x, b.x),
            y: min(a.y, b.y),
            width: abs(a.x - b.x),
            height: abs(a.y - b.y)
        )
    }
}
