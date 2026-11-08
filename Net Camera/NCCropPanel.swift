import Cocoa

// MARK: - Crop panel

/// The dialog for cutting margins off the camera's picture.
///
/// A panel beside the window rather than a sheet on it, because a sheet drops
/// down over the top of the very picture whose top edge is being trimmed.
/// Every change is handed back at once, so the window, the web stream and a
/// saved image all show the crop while it is being set; Cancel — or closing the
/// panel — hands back the crop that was in force when it opened.
final class NCCropPanel: NSObject, NSWindowDelegate, NSTextFieldDelegate {
    // MARK: - Edges

    private enum Edge: Int, CaseIterable {
        case top, left, bottom, right

        var title: String {
            switch self {
            case .top: return "Top:"
            case .left: return "Left:"
            case .bottom: return "Bottom:"
            case .right: return "Right:"
            }
        }
    }

    // MARK: - Properties

    private let panel: NSPanel
    private let original: NCFrameCrop
    private var crop: NCFrameCrop

    /// The camera's picture size, which bounds the margins. `nil` with no
    /// camera, when the margins can be set but nothing bounds them yet.
    private let sourceSize: (width: Int, height: Int)?

    private let onChange: (NCFrameCrop) -> Void
    private let onFinish: () -> Void

    private var fields: [Edge: NSTextField] = [:]
    private var steppers: [Edge: NSStepper] = [:]
    private let sizeLabel = NSTextField(labelWithString: "")

    /// Whether OK or Cancel has already settled the outcome, so that the panel
    /// closing afterwards is not taken for a second Cancel.
    private var isFinished = false

    /// The upper bound for a margin when there is no camera to bound it.
    private static let unboundedMaximum = 9999

    // MARK: - Lifecycle

    /// - Parameters:
    ///   - crop: The crop in force, which Cancel goes back to.
    ///   - sourceSize: The camera's picture size, or `nil` with no camera.
    ///   - onChange: Called with every new crop, including the original one
    ///     again on Cancel.
    ///   - onFinish: Called once, when the panel has gone.
    init(
        crop: NCFrameCrop, sourceSize: (width: Int, height: Int)?,
        onChange: @escaping (NCFrameCrop) -> Void, onFinish: @escaping () -> Void
    ) {
        self.original = crop
        self.crop = crop
        self.sourceSize = sourceSize
        self.onChange = onChange
        self.onFinish = onFinish
        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 200),
            styleMask: [.titled, .closable], backing: .buffered, defer: true)
        super.init()

        panel.title = "Crop Picture"
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        // Over a borderless window at its raised level, and beside the window
        // in full screen rather than left behind on another space.
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = makeContent()
        refresh()
    }

    // MARK: - Showing

    /// Brings the panel up beside `window` — to its right when the screen has
    /// room, centred otherwise — at a level that keeps it above the window.
    func show(beside window: NSWindow) {
        panel.level = NSWindow.Level(
            rawValue: max(window.level.rawValue, NSWindow.Level.floating.rawValue))

        if !panel.isVisible {
            let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
            let size = panel.frame.size
            let origin = NSPoint(x: window.frame.maxX + 12, y: window.frame.maxY - size.height)
            if visible.contains(NSRect(origin: origin, size: size)) {
                panel.setFrameOrigin(origin)
            } else {
                panel.center()
            }
        }
        panel.makeKeyAndOrderFront(nil)
    }

    // MARK: - Content

    private func makeContent() -> NSView {
        let rows: [[NSView]] = Edge.allCases.map { edge in
            let field = NSTextField()
            field.formatter = Self.makeFormatter()
            field.alignment = .right
            field.delegate = self
            field.tag = edge.rawValue
            field.widthAnchor.constraint(equalToConstant: 64).isActive = true
            fields[edge] = field

            let stepper = NSStepper()
            stepper.minValue = 0
            stepper.increment = 1
            stepper.valueWraps = false
            stepper.autorepeat = true
            stepper.tag = edge.rawValue
            stepper.target = self
            stepper.action = #selector(stepperChanged(_:))
            steppers[edge] = stepper

            return [NSTextField(labelWithString: edge.title), field, stepper,
                    NSTextField(labelWithString: "px")]
        }

        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 6
        grid.column(at: 0).xPlacement = .trailing

        let hint = NSTextField(
            wrappingLabelWithString:
                "Edges of the camera's own picture, before mirroring and rotation.")
        hint.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        hint.textColor = .secondaryLabelColor
        hint.preferredMaxLayoutWidth = 260

        sizeLabel.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        sizeLabel.textColor = .secondaryLabelColor

        let reset = NSButton(title: "Reset", target: self, action: #selector(reset(_:)))
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let ok = NSButton(title: "OK", target: self, action: #selector(ok(_:)))
        ok.keyEquivalent = "\r"

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [reset, spacer, cancel, ok])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [grid, hint, sizeLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        buttons.widthAnchor.constraint(
            equalTo: stack.widthAnchor, constant: -40).isActive = true
        return stack
    }

    private static func makeFormatter() -> NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .none
        formatter.allowsFloats = false
        formatter.minimum = 0
        return formatter
    }

    // MARK: - Values

    private func value(of edge: Edge, in crop: NCFrameCrop) -> Int {
        switch edge {
        case .top: return crop.top
        case .left: return crop.left
        case .bottom: return crop.bottom
        case .right: return crop.right
        }
    }

    /// The most `edge` can take while the opposite margin stays as it is and
    /// at least one pixel of picture is left.
    private func maximum(of edge: Edge) -> Int {
        guard let sourceSize else { return Self.unboundedMaximum }
        switch edge {
        case .top: return max(0, sourceSize.height - 1 - crop.bottom)
        case .bottom: return max(0, sourceSize.height - 1 - crop.top)
        case .left: return max(0, sourceSize.width - 1 - crop.right)
        case .right: return max(0, sourceSize.width - 1 - crop.left)
        }
    }

    /// Sets one margin, held within what the picture allows, and hands the
    /// result on. Returns the value actually taken.
    @discardableResult
    private func set(_ edge: Edge, to requested: Int) -> Int {
        let taken = min(max(0, requested), maximum(of: edge))
        crop = NCFrameCrop(
            top: edge == .top ? taken : crop.top,
            left: edge == .left ? taken : crop.left,
            bottom: edge == .bottom ? taken : crop.bottom,
            right: edge == .right ? taken : crop.right)
        onChange(crop)
        return taken
    }

    /// Brings every control and the size line into line with the crop.
    /// `editing` is left alone, so that a field being typed into does not have
    /// its text replaced under the cursor.
    private func refresh(except editing: Edge? = nil) {
        for edge in Edge.allCases {
            let current = value(of: edge, in: crop)
            let limit = maximum(of: edge)
            if let stepper = steppers[edge] {
                stepper.maxValue = Double(limit)
                stepper.integerValue = current
            }
            if let formatter = fields[edge]?.formatter as? NumberFormatter {
                formatter.maximum = NSNumber(value: limit)
            }
            if edge != editing {
                fields[edge]?.integerValue = current
            }
        }

        if let sourceSize {
            let kept = crop.keptSize(width: sourceSize.width, height: sourceSize.height)
            sizeLabel.stringValue =
                "Picture: \(kept.width) × \(kept.height) of \(sourceSize.width) × \(sourceSize.height)"
        } else {
            sizeLabel.stringValue = "No camera: the margins apply when one starts."
        }
    }

    // MARK: - Actions

    @objc private func stepperChanged(_ sender: NSStepper) {
        guard let edge = Edge(rawValue: sender.tag) else { return }
        set(edge, to: sender.integerValue)
        refresh()
    }

    /// Typing takes effect as it happens, not only on Return, so the picture
    /// follows the number being typed.
    func controlTextDidChange(_ notification: Notification) {
        guard let field = notification.object as? NSTextField,
            let edge = Edge(rawValue: field.tag)
        else { return }
        let typed = Int(field.stringValue) ?? 0
        let taken = set(edge, to: typed)
        refresh(except: taken == typed ? edge : nil)
    }

    @objc private func reset(_ sender: Any?) {
        crop = .none
        onChange(crop)
        refresh()
    }

    @objc private func cancel(_ sender: Any?) {
        finish(with: original)
    }

    @objc private func ok(_ sender: Any?) {
        // A field still being edited has already been taken as typed.
        finish(with: crop)
    }

    /// Settles the outcome once. `closingPanel` is false when the panel is
    /// already on its way out, which must not be asked to close a second time.
    private func finish(with outcome: NCFrameCrop, closingPanel: Bool = true) {
        guard !isFinished else { return }
        isFinished = true
        if outcome != crop {
            crop = outcome
            onChange(outcome)
        }
        if closingPanel {
            panel.close()
        }
        onFinish()
    }

    // MARK: - NSWindowDelegate

    /// Closing the panel by its close button is Cancel.
    func windowWillClose(_ notification: Notification) {
        finish(with: original, closingPanel: false)
    }
}
