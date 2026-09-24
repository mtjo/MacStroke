//
//  PresetGesturePickerPanel.swift
//  MacStroke
//
//  The "Draw Gesture!" dialog: every preset gesture the original picker offers
//  (8 arrows + 4 box corners and 26 letters, each with a reversed twin = 68)
//  laid out as a one-page grid of thumbnails, so the shape is visible before
//  it is chosen. A single click applies it. Drawing on the live overlay still
//  works, which is what the hint text has to spell out.
//

import AppKit
import GestureEngine
import Storage

final class PresetGesturePickerPanel: NSObject, NSWindowDelegate {
    /// What the user clicked, or `nil` when the dialog was dismissed.
    private struct Choice {
        let name: String
        let stroke: Stroke
    }

    /// Sized so all 68 presets fit on one page — the grid never scrolls.
    private static let columns = 10
    private static let cellSide: CGFloat = 56
    private static let gridPadding: CGFloat = 8

    private var window: NSWindow!
    private var cells: [PresetGestureCell] = []
    private var choice: Choice?

    /// Show the grid modally. Returns the preset the user clicked, `nil` when it
    /// was cancelled or when a gesture was drawn on the screen instead.
    static func pick() -> (name: String, stroke: Stroke)? {
        let panel = PresetGesturePickerPanel()
        guard let choice = panel.run() else { return nil }
        return (choice.name, choice.stroke)
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
        window.orderOut(nil)
        return choice
    }

    // MARK: Window

    func makeWindow(entries: [(name: String, stroke: Stroke)]) -> NSWindow {
        let rows = (entries.count + Self.columns - 1) / Self.columns
        let gridWidth = Self.cellSide * CGFloat(Self.columns) + Self.gridPadding * 2
        let gridHeight = Self.cellSide * CGFloat(rows) + Self.gridPadding * 2
        let contentWidth = gridWidth + 20
        let hintHeight: CGFloat = 84
        let contentHeight = gridHeight + hintHeight + 46

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: contentWidth, height: contentHeight),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        // The close button must end the modal session, or the loop never returns.
        window.delegate = self
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
        header.frame = NSRect(x: 18, y: contentHeight - 88, width: contentWidth - 36, height: 16)

        let grid = FlippedGrid(frame: NSRect(x: 10, y: 46, width: gridWidth, height: gridHeight))
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

        let cancel = NSButton(title: L("Cancel"), target: self, action: #selector(cancelClicked))
        cancel.bezelStyle = .rounded
        cancel.keyEquivalent = "\u{1b}"
        cancel.frame = NSRect(x: contentWidth - 96, y: 10, width: 86, height: 28)

        [title, hint, clickHint, header, grid, cancel].forEach(content.addSubview)
        window.contentView = content
        return window
    }

    @objc private func cellClicked(_ sender: PresetGestureCell) {
        cells.forEach { $0.isSelected = $0 === sender }
        choice = Choice(name: sender.gestureName, stroke: sender.stroke)
        close()
    }

    @objc private func cancelClicked() {
        choice = nil
        close()
    }

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

// MARK: - Thumbnail cell

private final class PresetGestureCell: NSControl {
    let gestureName: String
    let stroke: Stroke
    private let points: [CGPoint]
    var isSelected = false { didSet { needsDisplay = true } }

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
        if isSelected {
            NSColor.selectedControlColor.setFill()
            background.fill()
        }
        NSColor.separatorColor.setStroke()
        background.lineWidth = 1
        background.stroke()

        guard let scaled = scaledPoints(fit: tile.insetBy(dx: 11, dy: 11)) else { return }
        let segments = Double(scaled.count - 1)
        for i in 0..<(scaled.count - 1) {
            // Same ramp the rule table's gesture column uses (DrawGesture.m).
            let t = Double(i) / max(segments, 1)
            NSColor(red: 0.5 * t, green: 0.47 + 0.53 * t, blue: 0.9, alpha: 1).setStroke()
            let path = NSBezierPath()
            path.lineWidth = 2
            path.lineCapStyle = .round
            path.move(to: scaled[i])
            path.line(to: scaled[i + 1])
            path.stroke()
        }
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
}
