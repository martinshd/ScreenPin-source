import AppKit

/// 抠图悬浮窗：置顶显示在选区原位置，可拖动、调透明度、点击穿透，
/// 支持画笔 / 箭头标注（保存与复制时合成进图像），
/// 右键菜单 / 快捷键保存或复制，不需要时关闭丢弃。
final class PinWindowController: NSObject {

    var onClose: (() -> Void)?

    private let cgImage: CGImage
    private var window: PinPanel?
    private var pinView: PinImageView?

    /// - Parameters:
    ///   - image: 抠出的图像
    ///   - cocoaFrame: 选区在全局 Cocoa 坐标系中的位置（point），悬浮窗原地出现
    init(image: CGImage, cocoaFrame: CGRect) {
        self.cgImage = image
        super.init()

        let view = PinImageView(image: image, frame: NSRect(origin: .zero, size: cocoaFrame.size))
        let panel = PinPanel(
            contentRect: NSRect(origin: cocoaFrame.origin, size: cocoaFrame.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating // 置顶
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary] // 所有桌面空间可见
        panel.contentView = view
        panel.isReleasedWhenClosed = false

        view.onSave = { [weak self, weak view] in
            guard let self else { return }
            do {
                _ = try SaveService.savePNGToDesktop(view?.annotatedImage() ?? self.cgImage)
                view?.flashBorder() // 静默保存，边框闪一下作为反馈
            } catch {
                NSSound.beep()
            }
        }
        view.onCopy = { [weak self, weak view] in
            guard let self else { return }
            SaveService.copyToPasteboard(view?.annotatedImage() ?? self.cgImage)
            view?.flashBorder()
        }
        view.onSaveCopyPath = { [weak self, weak view] in
            guard let self else { return }
            do {
                // 与 ⌘S 一样存桌面，区别仅是剪贴板放路径文本而非图像（方便发给 agent）
                let url = try SaveService.savePNGToDesktop(view?.annotatedImage() ?? self.cgImage)
                SaveService.copyPathToPasteboard(url.path)
                view?.flashBorder()
            } catch {
                NSSound.beep()
            }
        }
        // 标注内容一变就静默刷新剪贴板：画完直接 ⌘V 就是最新标注图，
        // 撤销/清空后剪贴板也跟着回退，无需再手动 ⌘C
        view.onAnnotationsChanged = { [weak self, weak view] in
            guard let self else { return }
            SaveService.copyToPasteboard(view?.annotatedImage() ?? self.cgImage)
        }
        view.onClose = { [weak self] in self?.close() }
        view.onOpacity = { [weak panel] opacity in panel?.alphaValue = opacity }
        view.onToggleClickThrough = { [weak panel] in
            guard let panel else { return false }
            panel.ignoresMouseEvents.toggle()
            return panel.ignoresMouseEvents
        }

        self.window = panel
        self.pinView = view
    }

    func show() {
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
        window = nil
        onClose?()
    }
}

private final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// 标注工具：画笔（自由笔迹）、箭头（拖拽起点到终点）或文字（单击落点输入）
private enum AnnotationTool {
    case pen, arrow, text
}

/// 一笔标注：折线笔迹、箭头或文字，含颜色与线宽
private struct Annotation {
    enum Shape {
        case stroke([CGPoint])
        case arrow(from: CGPoint, to: CGPoint)
        /// 文字：origin 为折行后文本块左下角（视图坐标），渲染时向右上铺开、超宽自动换行
        case text(String, origin: CGPoint)
    }
    var shape: Shape
    var color: NSColor
    var lineWidth: CGFloat
}

/// 悬浮图内容视图：绘制图像 + 处理拖动 / 标注 / 右键菜单 / 快捷键
final class PinImageView: NSView {

    var onSave: (() -> Void)?
    var onCopy: (() -> Void)?
    /// ⇧⌘S：保存到桌面 + 剪贴板写入文件路径文本
    var onSaveCopyPath: (() -> Void)?
    var onClose: (() -> Void)?
    var onOpacity: ((CGFloat) -> Void)?
    /// 标注增删（画一笔 / 撤销 / 清空）后回调，用于同步剪贴板
    var onAnnotationsChanged: (() -> Void)?
    /// 返回切换后的穿透状态（用于菜单勾选）
    var onToggleClickThrough: (() -> Bool)?

    private let cgImage: CGImage
    private var borderVisible = false

    /// 当前标注工具；nil 表示未进入标注模式（按住拖动为移动窗口）
    private var tool: AnnotationTool?
    private var penColor: NSColor = .systemRed
    private var annotations: [Annotation] = []
    /// 拖拽中的那一笔（实时预览）
    private var draft: Annotation?
    private let annotationLineWidth: CGFloat = 3
    /// 进入标注模式时的标注数检查点：ESC 退出标注时回滚到这里（丢弃本次画的标记）
    private var annotationCheckpoint = 0

    init(image: CGImage, frame: NSRect) {
        cgImage = image
        super.init(frame: frame)
        let m = buildMenu()
        m.delegate = self // 打开菜单前同步勾选状态（工具 / 颜色 / 撤销可用性）
        menu = m
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func resetCursorRects() {
        super.resetCursorRects()
        // 标注模式下给十字光标提示（文字模式用 I 型光标）；普通模式保持箭头（拖动窗口）
        guard tool != nil else { return }
        addCursorRect(bounds, cursor: tool == .text ? .iBeam : .crosshair)
        addCursorRect(exitButtonRect(), cursor: .arrow) // 按钮区域恢复箭头，暗示可点
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.draw(cgImage, in: bounds)
        for annotation in annotations { Self.stroke(annotation, in: ctx, clipWidth: bounds.width) }
        if let draft { Self.stroke(draft, in: ctx, clipWidth: bounds.width) }
        if tool != nil { drawAnnotateModeIndicator() }
        if borderVisible {
            NSColor.controlAccentColor.setStroke()
            let path = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
            path.lineWidth = 2
            path.stroke()
        }
    }

    /// 标注模式的常驻标识：笔色描边 + 左上角「退出标注」按钮，
    /// 和拖动模式一眼可辨（否则 ESC 前后看不出状态区别）；
    /// 按钮可点击退出，仅作屏幕 UI，不进入保存/复制的图像
    private func drawAnnotateModeIndicator() {
        penColor.setStroke()
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1.5, dy: 1.5))
        border.lineWidth = 3
        border.stroke()

        let rect = exitButtonRect()
        NSColor.black.withAlphaComponent(0.75).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
        // 笔色细描边，让按钮和模式描边呼应、更像可点控件
        penColor.setStroke()
        let outline = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4)
        outline.lineWidth = 1
        outline.stroke()
        (Self.exitButtonTitle as NSString).draw(
            at: NSPoint(x: rect.minX + Self.exitButtonPadding, y: rect.minY + Self.exitButtonPadding),
            withAttributes: Self.exitButtonAttrs
        )
    }

    private static var exitButtonTitle: String { L("✕ Exit Annotation") }
    private static let exitButtonPadding: CGFloat = 5
    private static let exitButtonAttrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.white
    ]

    /// 退出按钮布局，draw 与 mouseDown 命中测试共用
    private func exitButtonRect() -> NSRect {
        let size = (Self.exitButtonTitle as NSString).size(withAttributes: Self.exitButtonAttrs)
        let p = Self.exitButtonPadding
        return NSRect(
            x: 6, y: bounds.maxY - size.height - p * 2 - 6,
            width: size.width + p * 2,
            height: size.height + p * 2
        )
    }

    /// 在任意 CGContext（视图或离屏位图）中画出一笔标注。
    /// clipWidth 为所在画面的逻辑宽度（point），供文字标注计算换行宽度。
    private static func stroke(_ annotation: Annotation, in ctx: CGContext, clipWidth: CGFloat) {
        ctx.saveGState()
        ctx.setStrokeColor(annotation.color.cgColor)
        ctx.setLineWidth(annotation.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        switch annotation.shape {
        case .stroke(let points):
            guard points.count > 1 else { break }
            ctx.beginPath()
            ctx.move(to: points[0])
            for point in points.dropFirst() { ctx.addLine(to: point) }
            ctx.strokePath()
        case .arrow(let from, let to):
            ctx.beginPath()
            ctx.move(to: from)
            ctx.addLine(to: to)
            ctx.strokePath()
            // 箭头头部：从终点向回张开两条短线
            let angle = atan2(to.y - from.y, to.x - from.x)
            let headLength = max(12, annotation.lineWidth * 4)
            let spread = CGFloat.pi / 7
            for sign in [CGFloat(1), -1] {
                let a = angle + .pi + sign * spread
                ctx.beginPath()
                ctx.move(to: to)
                ctx.addLine(to: CGPoint(x: to.x + headLength * cos(a),
                                        y: to.y + headLength * sin(a)))
                ctx.strokePath()
            }
        case .text(let string, let origin):
            drawText(string, at: origin, clipWidth: clipWidth, color: annotation.color, in: ctx)
        }
        ctx.restoreGState()
    }

    private static let textFont = NSFont.systemFont(ofSize: 16, weight: .bold)

    /// 文字渲染：以 origin 为文本块左下角，限制在 clipWidth 内自动换行。
    /// NSString 绘制需要 NSGraphicsContext，离屏位图里临时包一层即可（坐标系同为左下原点）。
    private static func drawText(_ string: String, at origin: CGPoint, clipWidth: CGFloat,
                                 color: NSColor, in ctx: CGContext) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: textFont,
            .foregroundColor: color
        ]
        let wrapWidth = max(clipWidth - origin.x - 4, 40)
        let constraint = CGSize(width: wrapWidth, height: .greatestFiniteMagnitude)
        let height = (string as NSString).boundingRect(
            with: constraint,
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).height
        let rect = CGRect(x: origin.x, y: origin.y, width: wrapWidth, height: height)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        (string as NSString).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading],
                                  attributes: attrs)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// 把标注合成进图像（保存 / 复制用）；无标注时直接返回原图。
    /// 视图坐标与位图上下文同为左下原点，按像素比例放大后直接重画即可。
    func annotatedImage() -> CGImage {
        guard !annotations.isEmpty else { return cgImage }
        let scale = CGFloat(cgImage.width) / max(bounds.width, 1)
        guard let ctx = CGContext(
            data: nil, width: cgImage.width, height: cgImage.height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return cgImage }
        ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: cgImage.width, height: cgImage.height))
        ctx.scaleBy(x: scale, y: scale)
        for annotation in annotations { Self.stroke(annotation, in: ctx, clipWidth: bounds.width) }
        return ctx.makeImage() ?? cgImage
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        if tool != nil {
            let point = convert(event.locationInWindow, from: nil)
            if exitButtonRect().contains(point) { // 点击「✕ 退出标注」按钮
                setTool(nil)
            } else {
                beginDraft(at: point)
            }
        } else {
            window?.performDrag(with: event) // 按住任意位置拖动窗口
        }
    }

    override func mouseDragged(with event: NSEvent) {
        updateDraft(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        endDraft()
    }

    override func rightMouseDown(with event: NSEvent) {
        // 右键弹菜单不会激活 panel：不补 makeKey 的话，焦点在别的窗口时
        // ⌘C/⌘S 会落空，剪贴板里一直是截图时的旧原图（标注丢失的假象）
        window?.makeKey()
        super.rightMouseDown(with: event)
    }

    /// 钳制在图像范围内：拖出窗口的笔迹不外溢，合成位图时也不越界
    private func clampedToBounds(_ point: NSPoint) -> NSPoint {
        NSPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func beginDraft(at point: NSPoint) {
        guard let tool else { return }
        let p = clampedToBounds(point)
        switch tool {
        case .pen:
            draft = Annotation(shape: .stroke([p]), color: penColor, lineWidth: annotationLineWidth)
        case .arrow:
            draft = Annotation(shape: .arrow(from: p, to: p), color: penColor, lineWidth: annotationLineWidth)
        case .text:
            beginTextInput(at: p) // 文字不走拖拽草稿，单击落点直接出输入框
        }
        needsDisplay = true
    }

    private func updateDraft(to point: NSPoint) {
        guard var d = draft else { return }
        let p = clampedToBounds(point)
        switch d.shape {
        case .stroke(var points):
            // 稀疏采样：过近的点直接丢弃，笔迹已足够平滑
            if let last = points.last, hypot(p.x - last.x, p.y - last.y) >= 1.5 {
                points.append(p)
                d.shape = .stroke(points)
            }
        case .arrow(let from, _):
            d.shape = .arrow(from: from, to: p)
        case .text:
            break
        }
        draft = d
        needsDisplay = true
    }

    private func endDraft() {
        guard let d = draft else { return }
        draft = nil
        switch d.shape {
        case .stroke(let points) where points.count < 2:
            break // 单击误触，丢弃
        case .arrow(let from, let to) where hypot(to.x - from.x, to.y - from.y) < 4:
            break // 过短的箭头视为误触
        case .text:
            break // 文字在输入框提交时已入列
        default:
            annotations.append(d)
            onAnnotationsChanged?()
        }
        needsDisplay = true
    }

    private func undoLastAnnotation() {
        guard !annotations.isEmpty else { NSSound.beep(); return }
        annotations.removeLast()
        onAnnotationsChanged?()
        needsDisplay = true
    }

    private func clearAnnotations() {
        guard !annotations.isEmpty else { return }
        annotations.removeAll()
        onAnnotationsChanged?()
        needsDisplay = true
    }

    // MARK: - 文字标注输入

    /// 文字标注的输入框（文字模式下同时只开一个）
    private var textField: NSTextField?

    /// 文字模式下单击：在落点放输入框，Enter / 点别处提交，ESC 取消
    private func beginTextInput(at point: NSPoint) {
        commitTextInput() // 已有输入框先提交落地
        let p = clampedToBounds(point)
        let field = NSTextField(frame: .zero)
        field.font = Self.textFont
        field.textColor = penColor
        field.bezelStyle = .roundedBezel
        field.isBezeled = true
        field.focusRingType = .none
        field.target = self
        field.action = #selector(commitTextFieldAction)
        field.delegate = self
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        // 宽度铺到右边缘，至少 120；落点太靠右则整体左移
        let width = max(bounds.maxX - p.x - 6, 120)
        let height: CGFloat = 26
        let x = min(p.x, bounds.maxX - width - 6)
        let y = min(max(p.y - height / 2, bounds.minY + 4), bounds.maxY - height - 4)
        field.frame = NSRect(x: x, y: y, width: width, height: height)
        addSubview(field)
        window?.makeFirstResponder(field)
        textField = field
    }

    /// 提交输入框内容为一笔文字标注（空内容直接丢弃）。
    /// 返回是否真正落地了一笔。
    @discardableResult
    private func commitTextInput() -> Bool {
        guard let field = textField else { return false }
        textField = nil // 先清引用：endEditing 会回调 controlTextDidEndEditing，避免重入
        let string = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        field.removeFromSuperview()
        window?.makeFirstResponder(self) // 焦点还给本视图，B/A/T/C/ESC 恢复可用
        guard !string.isEmpty else { needsDisplay = true; return false }
        // 文本块顶部对齐输入框顶部；origin 存文本块左下角，超宽按剩余宽度折行
        let originX = field.frame.minX + 2
        let wrapWidth = max(bounds.width - originX - 4, 40)
        let attrs: [NSAttributedString.Key: Any] = [.font: Self.textFont, .foregroundColor: penColor]
        let height = (string as NSString).boundingRect(
            with: CGSize(width: wrapWidth, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs
        ).height
        let origin = CGPoint(x: originX, y: max(field.frame.maxY - 4 - height, 2))
        annotations.append(Annotation(shape: .text(string, origin: origin),
                                      color: penColor, lineWidth: annotationLineWidth))
        onAnnotationsChanged?()
        needsDisplay = true
        return true
    }

    /// ESC 取消本次输入（不落盘、不退出标注模式）
    private func cancelTextInput() {
        guard let field = textField else { return }
        textField = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
    }

    @objc private func commitTextFieldAction() { commitTextInput() }

    /// 退出标注模式。discard 为 true 时丢弃本次进入标注以来画的标记
    /// （回滚到进入前的检查点），剪贴板随 onAnnotationsChanged 同步回滚
    private func exitAnnotateMode(discard: Bool) {
        setTool(nil)
        if discard, annotations.count > annotationCheckpoint {
            annotations.removeLast(annotations.count - annotationCheckpoint)
            onAnnotationsChanged?()
            needsDisplay = true
        }
    }

    /// C 键循环切换标注颜色（顺序同右键菜单）；模式描边/按钮描边色跟随，充当当前色指示
    private func cycleColor() {
        let colors = Self.annotationColors.map(\.1)
        let index = colors.firstIndex(of: penColor) ?? -1
        penColor = colors[(index + 1) % colors.count]
        needsDisplay = true
    }

    private func setTool(_ newTool: AnnotationTool?) {
        commitTextInput() // 切换/退出工具前，未提交的文字先落地
        // 从普通模式进入标注模式时记下检查点，供 ESC 回滚
        if tool == nil, newTool != nil { annotationCheckpoint = annotations.count }
        tool = newTool
        draft = nil
        // 从菜单选工具后 panel 未必是 key，主动抢回键盘焦点，
        // 保证随后的 B/A 切换、ESC 退出、⌘C/⌘S 都能落到本视图
        window?.makeKey()
        window?.invalidateCursorRects(for: self)
        needsDisplay = true
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags.contains(.command), let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "s": flags.contains(.shift) ? onSaveCopyPath?() : onSave?() // ⇧⌘S 存桌面+复制路径
            case "c": onCopy?()
            case "w": onClose?()
            case "z": undoLastAnnotation()
            default: super.keyDown(with: event)
            }
        } else if event.keyCode == 53 { // ESC
            // ESC = 取消并丢弃：文字输入由输入框 delegate 拦截（只取消本次输入）；
            // 标注模式 = 退出标注并丢弃本次画的标记；普通贴图 = 丢弃贴图
            if tool != nil { exitAnnotateMode(discard: true) } else { onClose?() }
        } else if event.keyCode == 36 || event.keyCode == 76 { // Enter / 小键盘回车
            // 确认并逐层退出：文字输入由输入框自身 Enter 提交，到不了这里；
            // 标注模式下先退出标注（恢复拖动），普通模式下确认完成、关闭贴图
            if tool != nil { setTool(nil) } else { onClose?() }
        } else if flags.isEmpty, let chars = event.charactersIgnoringModifiers?.lowercased() {
            switch chars {
            case "b": setTool(tool == .pen ? nil : .pen)     // 画笔开关
            case "a": setTool(tool == .arrow ? nil : .arrow) // 箭头开关
            case "t": setTool(tool == .text ? nil : .text)   // 文字开关
            case "c": cycleColor()                           // 循环换色
            default: super.keyDown(with: event)
            }
        } else {
            super.keyDown(with: event)
        }
    }

    /// 保存/复制成功的轻量反馈：边框闪烁一次
    func flashBorder() {
        borderVisible = true
        needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.borderVisible = false
            self?.needsDisplay = true
        }
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
            let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
            mi.target = self
            return mi
        }

        menu.addItem(item(L("Save to Desktop"), #selector(saveAction), "s"))
        let savePathItem = item(L("Save to Desktop & Copy Path"), #selector(saveCopyPathAction), "s")
        savePathItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(savePathItem)
        menu.addItem(item(L("Copy to Clipboard"), #selector(copyAction), "c"))
        menu.addItem(.separator())

        // 标注：画笔 / 箭头 / 文字（B / A / T 键开关），可换颜色、撤销、清除
        let annotateMenu = NSMenu()
        let penItem = NSMenuItem(title: L("Pen"), action: #selector(penAction(_:)), keyEquivalent: "b")
        penItem.keyEquivalentModifierMask = [] // 仅作快捷键提示，实际由 keyDown 处理
        penItem.target = self
        annotateMenu.addItem(penItem)
        let arrowItem = NSMenuItem(title: L("Arrow"), action: #selector(arrowAction(_:)), keyEquivalent: "a")
        arrowItem.keyEquivalentModifierMask = []
        arrowItem.target = self
        annotateMenu.addItem(arrowItem)
        let textItem = NSMenuItem(title: L("Text"), action: #selector(textAction(_:)), keyEquivalent: "t")
        textItem.keyEquivalentModifierMask = []
        textItem.target = self
        annotateMenu.addItem(textItem)
        let exitItem = NSMenuItem(title: L("Exit Annotation (Back to Dragging)"), action: #selector(exitAnnotateAction), keyEquivalent: "")
        exitItem.target = self
        annotateMenu.addItem(exitItem)
        annotateMenu.addItem(.separator())
        for (title, color) in Self.annotationColors {
            let mi = NSMenuItem(title: title, action: #selector(colorAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = color
            annotateMenu.addItem(mi)
        }
        annotateMenu.addItem(.separator())
        let undoItem = NSMenuItem(title: L("Undo Last Stroke"), action: #selector(undoAction), keyEquivalent: "z")
        undoItem.target = self
        annotateMenu.addItem(undoItem)
        let clearItem = NSMenuItem(title: L("Clear All Annotations"), action: #selector(clearAnnotationsAction), keyEquivalent: "")
        clearItem.target = self
        annotateMenu.addItem(clearItem)
        let annotateItem = NSMenuItem(title: L("Annotate"), action: nil, keyEquivalent: "")
        annotateItem.submenu = annotateMenu
        menu.addItem(annotateItem)

        menu.addItem(.separator())

        let opacityMenu = NSMenu()
        for (title, value) in [("100%", CGFloat(1.0)), ("75%", CGFloat(0.75)), ("50%", CGFloat(0.5)), ("25%", CGFloat(0.25))] {
            let mi = NSMenuItem(title: title, action: #selector(opacityAction(_:)), keyEquivalent: "")
            mi.target = self
            mi.representedObject = value
            opacityMenu.addItem(mi)
        }
        let opacityItem = NSMenuItem(title: L("Opacity"), action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        menu.addItem(item(L("Click Through"), #selector(clickThroughAction(_:))))
        menu.addItem(.separator())
        menu.addItem(item(L("Close"), #selector(closeAction), "w"))
        return menu
    }

    @objc private func saveAction() { onSave?() }
    @objc private func saveCopyPathAction() { onSaveCopyPath?() }
    @objc private func copyAction() { onCopy?() }
    @objc private func closeAction() { onClose?() }

    /// 可选标注颜色（菜单勾选与默认值都取自这里）
    private static let annotationColors: [(String, NSColor)] = [
        (L("Red"), .systemRed),
        (L("Yellow"), .systemYellow),
        (L("Green"), .systemGreen),
        (L("Blue"), .systemBlue),
        (L("Black"), .black),
        (L("White"), .white),
    ]

    @objc private func penAction(_ sender: NSMenuItem) {
        setTool(tool == .pen ? nil : .pen)
    }

    @objc private func arrowAction(_ sender: NSMenuItem) {
        setTool(tool == .arrow ? nil : .arrow)
    }

    @objc private func textAction(_ sender: NSMenuItem) {
        setTool(tool == .text ? nil : .text)
    }

    @objc private func colorAction(_ sender: NSMenuItem) {
        guard let color = sender.representedObject as? NSColor else { return }
        penColor = color
        if tool == nil { setTool(.pen) } // 还没选工具时，选颜色顺带进入画笔
    }

    @objc private func undoAction() { undoLastAnnotation() }
    @objc private func clearAnnotationsAction() { clearAnnotations() }
    @objc private func exitAnnotateAction() { setTool(nil) }

    @objc private func opacityAction(_ sender: NSMenuItem) {
        if let value = sender.representedObject as? CGFloat {
            onOpacity?(value)
        }
    }

    @objc private func clickThroughAction(_ sender: NSMenuItem) {
        if let isOn = onToggleClickThrough?() {
            sender.state = isOn ? .on : .off
        }
    }
}

// MARK: - 文字输入框 delegate

extension PinImageView: NSTextFieldDelegate {
    /// 点别处 / Enter 结束编辑时提交（commitTextInput 内部有重入保护）
    func controlTextDidEndEditing(_ obj: Notification) {
        commitTextInput()
    }

    /// 输入框里的 ESC 只取消本次输入，不冒泡成退出标注/关闭贴图。
    /// 注意：macOS 文本系统默认把 ESC 绑给 complete:（自动补全）而非 cancelOperation:，
    /// 两个都要拦，否则 ESC 在输入框里会"没反应"
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:))
            || commandSelector == #selector(NSTextView.complete(_:)) {
            cancelTextInput()
            return true
        }
        return false
    }
}

// MARK: - 菜单状态同步

extension PinImageView: NSMenuDelegate {
    /// 每次打开右键菜单前刷新：工具勾选、当前颜色勾选、撤销/清除可用性
    func menuNeedsUpdate(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu {
                menuNeedsUpdate(submenu)
                continue
            }
            switch item.action {
            case #selector(penAction(_:)):
                item.state = tool == .pen ? .on : .off
            case #selector(arrowAction(_:)):
                item.state = tool == .arrow ? .on : .off
            case #selector(textAction(_:)):
                item.state = tool == .text ? .on : .off
            case #selector(colorAction(_:)):
                let color = item.representedObject as? NSColor
                item.state = color == penColor ? .on : .off
            case #selector(undoAction), #selector(clearAnnotationsAction):
                item.isEnabled = !annotations.isEmpty
            case #selector(exitAnnotateAction):
                item.isEnabled = tool != nil
            default:
                break
            }
        }
    }
}
