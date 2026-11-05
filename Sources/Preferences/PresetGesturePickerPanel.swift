//
//  PresetGesturePickerPanel.swift
//  MacStroke
//
//  The "Draw Gesture!" dialog: every preset gesture the original picker offers
//  (8 arrows + 4 box corners and 26 letters, each with a reversed twin = 68)
//  laid out as a one-page grid of thumbnails, so the shape is visible before
//  it is chosen. A single click applies it, hovering replays the drawing order.
//  Drawing on the live overlay still works, which is what the hint text has to
//  spell out.
//

import AppKit
import GestureEngine
import Storage

final class PresetGesturePickerPanel: NSObject, NSWindowDelegate {
    /// What the user clicked, or `nil` when the dialog was dismissed.
    ///
    /// 结构和这一格留成模块内可见（不是 private）：桩件里跑不了 `NSApp.runModal`，
    /// `pick()` 那条链走不到「点了滚轮格之后 choice 是什么」，判据只能由用例直接
    /// 发那颗格子的 action、再读这一格（见 WheelRuleGestureFlowTests）。
    struct Choice {
        let name: String
        /// 画出来/预设的轨迹；选了下面那一栏的滚轮档时是 nil。
        let stroke: Stroke?
        /// 不画轨迹的那一栏（issue #78 第 2 条）；选了预设轨迹时是 nil。
        let instant: InstantGesture?
    }

    /// Sized so all 68 presets fit on one page — the grid never scrolls.
    private static let columns = 10
    private static let cellSide: CGFloat = 56
    private static let gridPadding: CGFloat = 8

    /// 底部那一栏：不用画就触发的手势（issue #78 第 2 条）。
    /// 滚轮两档要按住起始键；中键/侧键是独立的一击。若某颗键同时也是起手键，
    /// 起手键优先（捕获层先判起手键），偏好页与配规则时会提示冲突。
    static let instantGestures: [InstantGesture] = [
        .wheelUp, .wheelDown, .middleClick, .backClick, .forwardClick,
    ]
    /// 那一栏标题 + 说明两行占的高度（格子本身另有 cellSide 那么高）。
    /// 44 = 标题 14 + 说明两行 26 + 空隙：说明要让「右键增强」那页的名字换得下，
    /// 单行会被截尾，用户读到的是一句半截话。
    private static let instantHeaderHeight: CGFloat = 44
    private static var instantBandHeight: CGFloat {
        instantHeaderHeight + gridPadding + cellSide + gridPadding
    }

    private var window: PickerWindow!
    private var cells: [PresetGestureCell] = []
    var choice: Choice?

    /// Show the grid modally. Returns the preset the user clicked; `nil` when the
    /// dialog was closed or cancelled. A gesture drawn on the live overlay saves
    /// itself, so the caller only has to tell "drew one" apart from "cancelled".
    static func pick() -> (name: String, stroke: Stroke?, instant: InstantGesture?)? {
        let panel = PresetGesturePickerPanel()
        guard let choice = panel.run() else { return nil }
        return (choice.name, choice.stroke, choice.instant)
    }

    private func run() -> Choice? {
        window = makeWindow(entries: GestureTemplateProvider.shared.presetPickerEntries)

        // The overlay saves a drawn gesture itself and posts this; close so the
        // caller can tell "drew one" apart from "cancelled".
        let drawnObserver = NotificationCenter.default.addObserver(
            forName: .macStrokeGestureDidRecord, object: nil, queue: .main
        ) { [weak self] _ in
            self?.close()
        }
        defer { NotificationCenter.default.removeObserver(drawnObserver) }

        NSApp.activate(ignoringOtherApps: true)
        window.center()
        window.makeKeyAndOrderFront(nil)
        _ = NSApp.runModal(for: window)
        // A cell hovered when the dialog closed would otherwise keep replaying.
        cells.forEach { $0.stopReplay() }
        window.orderOut(nil)
        return choice
    }

    // MARK: Window

    func makeWindow(entries: [(name: String, stroke: Stroke)]) -> PickerWindow {
        let rows = (entries.count + Self.columns - 1) / Self.columns
        let gridWidth = Self.cellSide * CGFloat(Self.columns) + Self.gridPadding * 2
        let gridHeight = Self.cellSide * CGFloat(rows) + Self.gridPadding * 2
        let contentWidth = gridWidth + 20
        let hintHeight: CGFloat = 84
        // 网格下面还要塞一整栏滚轮档，所以网格的底边不再是原来的 46。
        let gridBottom: CGFloat = 46 + Self.instantBandHeight
        let contentHeight = gridHeight + hintHeight + gridBottom

        let window = PickerWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
                                  styleMask: [.titled, .closable],
                                  backing: .buffered,
                                  defer: false)
        // 关窗有三条入口，必须都只结束模态、不走 AppKit 的关窗动画：
        // 动画的 display link 会在 `pick()` 返回、面板释放之后还在跑
        // （2026-11-03 两次 `EXC_BAD_ACCESS` 都落在 `_NSWindowTransformAnimation`）。
        //  - 红叉：实测它的 action 是私有的 `_close:`，**不**经过 `performClose(_:)`，
        //    所以必须直接接管按钮；只拦 performClose 会让窗口照关、模态永挂；
        //  - ⌘W：菜单发 `performClose(_:)`，由 PickerWindow 拦；
        //  - 其他 close 路径：`windowWillClose` 兜底，且 `animationBehavior = .none`
        //    保证这些路径也没有动画可残留。
        window.delegate = self
        window.animationBehavior = .none
        window.isReleasedWhenClosed = false
        window.onCloseRequested = { [weak self] in self?.cancelClicked() }
        window.standardWindowButton(.closeButton)?.target = self
        window.standardWindowButton(.closeButton)?.action = #selector(cancelClicked)
        window.title = L("Draw Gesture!")

        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))

        let title = NSTextField(labelWithString: L("Draw Gesture!"))
        title.font = .boldSystemFont(ofSize: 13)
        title.frame = NSRect(x: 18, y: contentHeight - 30, width: contentWidth - 36, height: 20)

        let hint = NSTextField(labelWithString: L("You can draw a gesture anywhere on the screen, or select the preset gesture below."))
        hint.font = .systemFont(ofSize: 11)
        hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 18, y: contentHeight - 50, width: contentWidth - 36, height: 16)

        let clickHint = NSTextField(labelWithString: L("Click a preset gesture to apply it at once"))
        clickHint.font = .systemFont(ofSize: 11)
        clickHint.textColor = .secondaryLabelColor
        clickHint.frame = NSRect(x: 18, y: contentHeight - 66, width: contentWidth - 36, height: 16)

        let header = NSTextField(labelWithString: LFormat("Preset Gestures (%d)", entries.count))
        header.font = .systemFont(ofSize: 11, weight: .medium)
        header.frame = NSRect(x: 18, y: contentHeight - 82, width: 150, height: 14)

        // Without the replay there is no way to tell a preset from its reversed twin.
        let hoverHint = NSTextField(labelWithString: L("Hover a preset to replay how it is drawn"))
        hoverHint.font = .systemFont(ofSize: 11)
        hoverHint.textColor = .secondaryLabelColor
        hoverHint.alignment = .right
        hoverHint.frame = NSRect(x: 174, y: contentHeight - 82,
                                 width: contentWidth - 192, height: 14)

        let grid = FlippedGrid(frame: NSRect(x: 10, y: gridBottom, width: gridWidth, height: gridHeight))
        grid.identifier = NSUserInterfaceItemIdentifier("PresetGestureGrid")
        grid.wantsLayer = true
        grid.layer?.borderColor = NSColor.separatorColor.cgColor
        grid.layer?.borderWidth = 1
        grid.layer?.cornerRadius = 6
        for (index, entry) in entries.enumerated() {
            let column = index % Self.columns
            let row = index / Self.columns
            let cell = PresetGestureCell(
                stroke: entry.stroke,
                title: entry.name,
                frame: NSRect(x: Self.gridPadding + CGFloat(column) * Self.cellSide,
                              y: Self.gridPadding + CGFloat(row) * Self.cellSide,
                              width: Self.cellSide, height: Self.cellSide)
            )
            cell.target = self
            cell.action = #selector(cellClicked(_:))
            grid.addSubview(cell)
            cells.append(cell)
        }

        // 「不用画的手势」那一栏：滚轮上/下、中键、侧键各一格，点一下就把这条规则改成
        // 对应的瞬时触发。五格仍比网格窄，所以窗口宽度不用跟着变。
        // 两行文案压在格子上方：格子顶边到这里正好还剩 gridPadding 的空隙才接上网格。
        let bandTop = 46 + Self.gridPadding * 2 + Self.cellSide
        let bandHeader = NSTextField(labelWithString: L("Wheel Rule Gesture Header"))
        bandHeader.font = .systemFont(ofSize: 11, weight: .medium)
        bandHeader.frame = NSRect(x: 18, y: bandTop + 2, width: contentWidth - 36, height: 14)

        let bandHint = NSTextField(labelWithString: L("Wheel Rule Gesture Hint"))
        bandHint.font = .systemFont(ofSize: 11)
        bandHint.textColor = .secondaryLabelColor
        bandHint.lineBreakMode = .byWordWrapping
        bandHint.maximumNumberOfLines = 2
        // labelWithString 默认单行，不显式打开换行，上面那两行高度只是留白。
        bandHint.usesSingleLineMode = false
        bandHint.cell?.wraps = true
        bandHint.cell?.isScrollable = false
        bandHint.frame = NSRect(x: 18, y: bandTop + 16, width: contentWidth - 36, height: 26)

        let bandWidth = Self.cellSide * CGFloat(Self.instantGestures.count) + Self.gridPadding * 2
        let band = FlippedGrid(frame: NSRect(x: 10, y: 46, width: bandWidth,
                                             height: Self.cellSide + Self.gridPadding * 2))
        band.identifier = NSUserInterfaceItemIdentifier("InstantGestureBand")
        for (index, gesture) in Self.instantGestures.enumerated() {
            let cell = InstantGestureCell(
                gesture: gesture,
                frame: NSRect(x: Self.gridPadding + CGFloat(index) * Self.cellSide,
                              y: Self.gridPadding, width: Self.cellSide, height: Self.cellSide)
            )
            cell.target = self
            cell.action = #selector(instantCellClicked(_:))
            band.addSubview(cell)
        }

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: contentWidth - 96, y: 10, width: 86, height: 28)

        [title, hint, clickHint, header, hoverHint, grid, bandHeader, bandHint, band, cancel]
            .forEach(content.addSubview)
        window.contentView = content
        return window
    }

    @objc private func cellClicked(_ sender: PresetGestureCell) {
        choice = Choice(name: sender.gestureName, stroke: sender.stroke, instant: nil)
        close()
    }

    @objc private func instantCellClicked(_ sender: InstantGestureCell) {
        choice = Choice(name: L(sender.gesture.locKey), stroke: nil, instant: sender.gesture)
        close()
    }

    @objc private func cancelClicked() {
        choice = nil
        close()
    }

    /// 兜底：任何没被上面两条入口接住的关窗（例如别的代码直接 `close()`）也必须
    /// 结束模态，否则窗口没了、模态会话还在，整个 App 的点击和键盘都会被吃掉。
    func windowWillClose(_ notification: Notification) {
        guard choice == nil else { return }
        close()
    }

    private func close() {
        NSApp.stopModal(withCode: choice == nil ? .cancel : .OK)
    }

    private final class FlippedGrid: NSView {
        override var isFlipped: Bool { true }
    }
}

/// 红叉/⌘W 只结束模态会话，不交给 AppKit 的关窗动画 —— 模态一停，
/// 面板与窗口就会在 `pick()` 返回时一起释放，动画的 display link 还在跑。
final class PickerWindow: NSWindow {
    var onCloseRequested: (() -> Void)?

    override func performClose(_ sender: Any?) {
        onCloseRequested?()
    }
}

// MARK: - Thumbnail cell

private final class PresetGestureCell: NSControl {
    let gestureName: String
    let stroke: Stroke
    private let points: [CGPoint]
    private lazy var replay = GestureReplayAnimator(view: self)
    private var trackingArea: NSTrackingArea?

    init(stroke: Stroke, title: String, frame: NSRect) {
        self.stroke = stroke
        self.gestureName = title
        self.points = stroke.points.map { CGPoint(x: $0.x, y: $0.y) }
        super.init(frame: frame)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 3, dy: 3)
        let background = NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6)
        background.lineWidth = 1
        let replaying = replay.progress < 1
        if replaying {
            NSColor.selectedControlColor.withAlphaComponent(0.3).setFill()
            background.fill()
            NSColor.controlAccentColor.setStroke()
        } else {
            NSColor.separatorColor.setStroke()
        }
        background.stroke()

        guard let scaled = scaledPoints(fit: tile.insetBy(dx: 11, dy: 11)) else { return }
        GestureStrokeRenderer.draw(scaled, progress: replay.progress)
    }

    /// Fit the stroke's bounding box into `rect`, keeping its aspect and centring
    /// it — the table cell offsets by 12pt instead because its row is taller.
    private func scaledPoints(fit rect: NSRect) -> [CGPoint]? {
        guard points.count > 1 else { return nil }
        let xs = points.map(\.x)
        let ys = points.map(\.y)
        let width = abs((xs.max() ?? 0) - (xs.min() ?? 0))
        let height = abs((ys.max() ?? 0) - (ys.min() ?? 0))
        let span = max(width, height)
        guard span > 0 else { return nil }
        let zoom = min(rect.width, rect.height) / span
        let offsetX = rect.midX - (width * zoom) / 2
        let offsetY = rect.midY - (height * zoom) / 2
        let minX = xs.min() ?? 0
        let minY = ys.min() ?? 0
        return points.map {
            CGPoint(x: ($0.x - minX) * zoom + offsetX, y: ($0.y - minY) * zoom + offsetY)
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        replay.start()
    }

    override func mouseExited(with event: NSEvent) {
        replay.stop()
    }

    /// Called when the dialog closes while the pointer still rests on the cell.
    func stopReplay() {
        replay.stop()
    }
}

// MARK: - 滚轮档格子

/// 「不用画的手势」那一栏的一格（issue #78 第 2 条）：外观与预设格子同一套语言，
/// 只是里面画的是滚轮图标而不是轨迹，也没有回放（它不是一笔一画出来的）。
final class InstantGestureCell: NSControl {
    let gesture: InstantGesture
    private let title: String

    init(gesture: InstantGesture, frame: NSRect) {
        self.gesture = gesture
        self.title = L(gesture.locKey)
        super.init(frame: frame)
        toolTip = title
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel(title)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        let tile = bounds.insetBy(dx: 3, dy: 3)
        let background = NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6)
        background.lineWidth = 1
        NSColor.separatorColor.setStroke()
        background.stroke()
        WheelGestureGlyph.draw(gesture, in: tile)
    }

    override func mouseDown(with event: NSEvent) {
        guard let action else { return }
        NSApp.sendAction(action, to: target, from: self)
    }
}
