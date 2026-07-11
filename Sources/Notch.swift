import Cocoa

// Debug trace, gated by CLAUDE_STATUSBAR_DEBUG=1 (same switch the Node hooks use). Prints the
// notch flow so you can watch detection, window placement, and sink routing while wiring it up.
func notchDbg(_ msg: @autoclosure () -> String) {
    if ProcessInfo.processInfo.environment["CLAUDE_STATUSBAR_DEBUG"] == "1" {
        NSLog("ClaudeStatusBar[notch]: \(msg())")
    }
}

// Notch cutout position in AppKit GLOBAL screen coordinates (origin bottom-left of the primary
// screen; y grows upward). Everything downstream — the overlay window frame, the content layout —
// is derived from this one struct, so the coordinate math lives in exactly one place.
struct NotchGeometry {
    let screen: NSScreen
    let notchRect: NSRect      // the physical notch cutout (zero-width when synthetic), global coords
    let menuBarHeight: CGFloat // == safeAreaInsets.top on a notched Mac; 0 on a synthetic pill
    let synthetic: Bool        // true on a screen with no real notch → a floating rounded pill

    var centerX: CGFloat { notchRect.midX }
    var topY: CGFloat { notchRect.maxY }   // == the screen's top edge, global

    // Does ANY currently-attached screen have a physical notch? Used to gate the feature to notched
    // Macs (persisted, so a docked-clamshell MacBook keeps it even when the notch screen is absent).
    // All three APIs are macOS 12+ = our deployment target, so no #available guard is needed.
    static func machineHasNotch() -> Bool {
        NSScreen.screens.contains { $0.safeAreaInsets.top > 0 }
    }

    // Geometry for a SPECIFIC screen: the real notch if this screen has one, otherwise a synthetic
    // top-center pill (external monitors have no notch). CLAUDE_STATUSBAR_FAKE_NOTCH=1 forces a fake
    // real-notch on the main screen for dev on non-notched hardware.
    static func forScreen(_ screen: NSScreen) -> NotchGeometry {
        let f = screen.frame
        if ProcessInfo.processInfo.environment["CLAUDE_STATUSBAR_FAKE_SYNTHETIC"] == "1", screen == NSScreen.main {
            let rect = NSRect(x: f.midX, y: f.origin.y + f.height, width: 0, height: 0)
            return NotchGeometry(screen: screen, notchRect: rect, menuBarHeight: 0, synthetic: true)
        }
        if ProcessInfo.processInfo.environment["CLAUDE_STATUSBAR_FAKE_NOTCH"] == "1", screen == NSScreen.main {
            let h: CGFloat = 32, w: CGFloat = 180
            let rect = NSRect(x: f.midX - w / 2, y: f.maxY - h, width: w, height: h)
            return NotchGeometry(screen: screen, notchRect: rect, menuBarHeight: h, synthetic: false)
        }
        let inset = screen.safeAreaInsets
        if inset.top > 0, let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            // The aux areas are in the screen's OWN space; offset by frame.origin so a docked
            // laptop (notched panel as a SECONDARY display) still lands in global coords.
            let notchLeftX = f.origin.x + left.maxX
            let notchRightX = f.origin.x + right.minX
            let width = max(0, notchRightX - notchLeftX)
            let top = f.origin.y + f.height
            let rect = NSRect(x: notchLeftX, y: top - inset.top, width: width, height: inset.top)
            notchDbg("real notch \(rect) menuBarH=\(inset.top) on screen \(f)")
            return NotchGeometry(screen: screen, notchRect: rect, menuBarHeight: inset.top, synthetic: false)
        }
        // No notch on this screen → a floating pill at top-center (zero-width "notch", no menu-bar band).
        let rect = NSRect(x: f.midX, y: f.origin.y + f.height, width: 0, height: 0)
        notchDbg("synthetic pill at top-center of screen \(f)")
        return NotchGeometry(screen: screen, notchRect: rect, menuBarHeight: 0, synthetic: true)
    }
}

// Borderless, transparent, click-through-aware panel that floats over the notch region above the
// menu bar. It never becomes key/main, so clicking it does not deactivate the user's frontmost app.
final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        // .statusBar (25) sits above .mainMenu (24) so we draw over the menu bar at the notch.
        // If a future macOS renders the clock above us, bump to:
        //   NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        level = .statusBar
        // Show on every Space and over full-screen apps, and stay out of window cycling.
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // Slide-in/out parks the window fully ABOVE the screen edge (clipped = hidden) and animates its
    // y back into place. AppKit's default constraining would silently clamp those frames back onto
    // the screen, so opt out entirely — the controller owns this window's geometry.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

// One clickable row in the expanded island's menu. Rounds a subtle highlight under the pointer and
// fires onClick on mouse-up. Used for session rows, setting choices, and actions like Quit.
final class IslandRow: NSView {
    var onClick: (() -> Void)?
    private let hi = CALayer()

    init(height: CGFloat) {
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: height))
        wantsLayer = true
        hi.cornerRadius = 7
        hi.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hi)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() { super.layout(); hi.frame = bounds.insetBy(dx: 4, dy: 1) }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hi.backgroundColor = NSColor(white: 1, alpha: 0.14).cgColor }
    override func mouseExited(with event: NSEvent) { hi.backgroundColor = NSColor.clear.cgColor }
    override func mouseUp(with event: NSEvent) { onClick?() }
}

// A small on/off switch drawn with explicit colors (brand when on, translucent white when off) so it
// always renders correctly on the black panel — unlike NSSwitch / the menu's ToggleView, which infer
// their color from effectiveAppearance and drew invisible inside this borderless panel.
final class IslandSwitch: NSView {
    static let w: CGFloat = 34, h: CGFloat = 20
    private let track = CALayer()
    private let knob = CALayer()
    private let brand: NSColor
    var isOn: Bool { didSet { update(animated: true) } }
    var onToggle: ((Bool) -> Void)?

    init(isOn: Bool, brand: NSColor) {
        self.isOn = isOn
        self.brand = brand
        super.init(frame: NSRect(x: 0, y: 0, width: Self.w, height: Self.h))
        wantsLayer = true
        layer = CALayer()
        track.frame = bounds
        track.cornerRadius = Self.h / 2
        layer?.addSublayer(track)
        let kd = Self.h - 4
        knob.bounds = CGRect(x: 0, y: 0, width: kd, height: kd)
        knob.cornerRadius = kd / 2
        knob.backgroundColor = NSColor.white.cgColor
        knob.shadowColor = NSColor.black.cgColor
        knob.shadowOpacity = 0.25
        knob.shadowRadius = 1.5
        knob.shadowOffset = CGSize(width: 0, height: -0.5)
        layer?.addSublayer(knob)
        update(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func knobCenter() -> CGPoint {
        let kd = Self.h - 4
        return CGPoint(x: isOn ? bounds.width - kd / 2 - 2 : kd / 2 + 2, y: bounds.height / 2)
    }
    private func update(animated: Bool) {
        let col = (isOn ? brand : NSColor(white: 1, alpha: 0.22)).cgColor
        let pos = knobCenter()
        CATransaction.begin()
        if animated {
            let move = CASpringAnimation(keyPath: "position")
            move.damping = 16; move.stiffness = 260; move.mass = 1
            move.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            move.toValue = NSValue(point: pos)
            move.duration = move.settlingDuration
            knob.add(move, forKey: "position")
            let c = CABasicAnimation(keyPath: "backgroundColor")
            c.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            c.toValue = col; c.duration = 0.2
            track.add(c, forKey: "bg")
        } else { CATransaction.setDisableActions(true) }
        knob.position = pos
        track.backgroundColor = col
        CATransaction.commit()
    }
    override func mouseDown(with event: NSEvent) { isOn.toggle(); onToggle?(isOn) }
    // Swallow the mouse-up so it does NOT bubble to the parent IslandRow, whose onClick would
    // toggle a SECOND time — the net no-op that made clicking the switch itself appear dead.
    override func mouseUp(with event: NSEvent) {}
}

// An indeterminate progress bar: a rounded track with a brand-tinted highlight that sweeps left→right
// on a loop while a turn is working. Static dim when inactive. Pure CoreAnimation (no timers/Date).
final class NotchProgressBar: NSView {
    private let track = CALayer()
    private let sweep = CAGradientLayer()
    private var animating = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true
        track.backgroundColor = NSColor(white: 1, alpha: 0.12).cgColor
        layer?.addSublayer(track)
        sweep.startPoint = CGPoint(x: 0, y: 0.5)
        sweep.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(sweep)
        sweep.isHidden = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        track.frame = bounds
        // The sweeping highlight is one-third the width; it travels from off-left to off-right.
        sweep.frame = NSRect(x: 0, y: 0, width: bounds.width / 3, height: bounds.height)
        sweep.cornerRadius = bounds.height / 2
        if animating { startSweep() }
    }

    func setActive(_ working: Bool, color: NSColor) {
        sweep.colors = [NSColor.clear.cgColor, color.withAlphaComponent(0.95).cgColor, NSColor.clear.cgColor]
        if working {
            sweep.isHidden = false
            animating = true
            startSweep()
        } else {
            animating = false
            sweep.removeAnimation(forKey: "sweep")
            sweep.isHidden = true
        }
    }

    private func startSweep() {
        let w = bounds.width
        let anim = CABasicAnimation(keyPath: "position.x")
        anim.fromValue = -w / 3
        anim.toValue = w + w / 3
        anim.duration = 1.1
        anim.repeatCount = .infinity
        anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        sweep.add(anim, forKey: "sweep")
    }
}

// A compact horizontal segmented control (like UISegmentedControl): N equal segments, the selected
// one highlighted by a brand-colored pill that slides between positions. Keeps settings to one row
// each instead of a stack of choice rows.
final class IslandSegmented: NSView {
    private let items: [String]
    private(set) var selected: Int
    var onSelect: ((Int) -> Void)?
    private let sel = CALayer()
    private var fields: [NSTextField] = []
    private let brand: NSColor

    init(items: [String], selected: Int, height: CGFloat, brand: NSColor) {
        self.items = items
        self.selected = max(0, min(items.count - 1, selected))
        self.brand = brand
        super.init(frame: NSRect(x: 0, y: 0, width: 10, height: height))
        wantsLayer = true
        layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        layer?.cornerRadius = 8
        layer?.masksToBounds = true   // the sliding pill can never spill past the track
        sel.cornerRadius = 6
        sel.backgroundColor = brand.withAlphaComponent(0.92).cgColor
        layer?.addSublayer(sel)
        for it in items {
            let f = NSTextField(labelWithString: it)
            f.alignment = .center
            f.font = .systemFont(ofSize: 11, weight: .medium)
            addSubview(f)
            fields.append(f)
        }
        updateColors()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func updateColors() {
        for (i, f) in fields.enumerated() {
            f.textColor = i == selected ? .white : NSColor(white: 1, alpha: 0.55)
            f.font = .systemFont(ofSize: 11, weight: i == selected ? .semibold : .medium)
        }
    }

    override func layout() {
        super.layout()
        let n = CGFloat(items.count)
        let segW = bounds.width / n
        sel.frame = NSRect(x: CGFloat(selected) * segW + 2, y: 2, width: segW - 4, height: bounds.height - 4)
        for (i, f) in fields.enumerated() {
            f.frame = NSRect(x: CGFloat(i) * segW, y: (bounds.height - 15) / 2, width: segW, height: 15)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let idx = max(0, min(items.count - 1, Int(p.x / (bounds.width / CGFloat(items.count)))))
        if idx != selected { selected = idx; updateColors(); needsLayout = true }
        onSelect?(idx)
    }
}

// The Dynamic Island content: a black rounded-bottom panel that fuses with the physical notch
// (square top corners, rounded bottom). The always-visible HEADER pill shows [icon] [label] [timer]
// centered just below the notch; hovering expands the panel and reveals the BODY (a full menu of
// sessions + settings, built by the controller). Content is forced white for legibility on black.
final class NotchContentView: NSView {
    let iconView = NSImageView()
    let labelField = NSTextField(labelWithString: "")
    let timerField = NSTextField(labelWithString: "")
    let body = NSView()              // the controller fills this with IslandRows when expanded
    private let bg = CAShapeLayer()      // panel shape — pure black so it fuses with the notch
    var notchWidth: CGFloat
    var menuBarHeight: CGFloat
    var bodyHeight: CGFloat = 0      // set by the controller from the built rows
    var synthetic = false            // no real notch (external monitor) → round all four corners
    var expanded = false
    var onHoverEnter: (() -> Void)?
    var onHoverExit: (() -> Void)?

    static let bodyInset: CGFloat = 10   // margin around the body; the controller matches it for row width
    private let iconSize: CGFloat = 17
    private let gap: CGFloat = 7
    static let sideGap: CGFloat = 12     // collapsed: gap between flanking content and the notch cutout
    static let sidePad: CGFloat = 14     // collapsed: outer padding at each end
    private let maxSide: CGFloat = 190   // cap on each flank so a long label can't overrun the menu bar

    // Accurate rendered width of a label's text. NSTextField.attributedStringValue.size() under-reports
    // for a bare label field (it omits the cell's internal insets), which left the collapsed pill a few
    // px too narrow and truncated "Working…" → "Workin…". Measure against the field's own font instead.
    private func fieldWidth(_ f: NSTextField) -> CGFloat {
        guard !f.stringValue.isEmpty, let font = f.font else { return 0 }
        return ceil((f.stringValue as NSString).size(withAttributes: [.font: font]).width) + 8
    }

    // Content width of the flanking region on ONE side (icon+label on the left, timer on the right).
    private func leftContentWidth() -> CGFloat {
        let iconW = iconView.image != nil ? iconSize : 0
        let labelW = fieldWidth(labelField)
        return iconW + ((iconW > 0 && labelW > 0) ? gap : 0) + labelW
    }

    // Total inner width the collapsed island wants: two symmetric flanks around the notch cutout, so
    // the notch stays dead-center. Returns 0 when idle (no label, no timer) → the panel shrinks to the
    // bare notch. The controller adds outer padding.
    func desiredContentWidth() -> CGFloat {
        let leftW = leftContentWidth()
        let rightW = fieldWidth(timerField)
        if leftW == 0 && rightW == 0 { return 0 }
        let side = min(maxSide, max(leftW, rightW))
        return side * 2 + Self.sideGap * 2 + notchWidth
    }

    func setExpanded(_ on: Bool, bodyHeight: CGFloat) {
        expanded = on
        self.bodyHeight = bodyHeight
        body.isHidden = !on
        needsLayout = true
    }

    // Collapsed flank content (icon + label + timer) fades as one unit during the island's
    // expand-out-of / contract-into-the-camera animations, so text never visibly clips while
    // the width changes underneath it.
    func setFlankAlpha(_ a: CGFloat) {
        iconView.alphaValue = a; labelField.alphaValue = a; timerField.alphaValue = a
    }
    func animateFlankAlpha(_ a: CGFloat) {
        iconView.animator().alphaValue = a
        labelField.animator().alphaValue = a
        timerField.animator().alphaValue = a
    }

    init(frame: NSRect, notchWidth: CGFloat, menuBarHeight: CGFloat) {
        self.notchWidth = notchWidth
        self.menuBarHeight = menuBarHeight
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(bg)
        bg.fillColor = NSColor.black.cgColor   // match the physical notch

        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.contentTintColor = .white
        addSubview(iconView)

        labelField.textColor = .white
        labelField.font = .systemFont(ofSize: 13, weight: .medium)
        labelField.lineBreakMode = .byTruncatingTail
        addSubview(labelField)

        timerField.textColor = .white
        timerField.font = .monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        addSubview(timerField)

        body.wantsLayer = true
        body.isHidden = true
        addSubview(body)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // The menu-bar band we vertically center collapsed content in (a synthetic pill has no menu bar,
    // so fall back to a fixed height).
    private var bandHeight: CGFloat { menuBarHeight > 0 ? menuBarHeight : 30 }

    override func layout() {
        super.layout()
        let w = bounds.width, h = bounds.height
        // Collapsed bottom corners match the physical camera housing's curve (~12pt), not the old
        // lip-capped 6pt that read as a sharp box next to the real notch. Bare-notch idle sits
        // entirely over the cutout, so its (smaller) rounding is invisible either way.
        let r: CGFloat = expanded ? 18 : min(12, h / 2)
        let path = CGMutablePath()
        if synthetic {
            // No physical notch to fuse with (external monitor pill): round all four corners.
            path.addRoundedRect(in: CGRect(x: 0, y: 0, width: w, height: h),
                                cornerWidth: min(r, w / 2), cornerHeight: min(r, h / 2))
        } else {
            // Square top corners (fuse with the notch / top edge); rounded bottom only.
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w, y: r))
            path.addArc(center: CGPoint(x: w - r, y: r), radius: r, startAngle: 0, endAngle: -.pi / 2, clockwise: true)
            path.addLine(to: CGPoint(x: r, y: 0))
            path.addArc(center: CGPoint(x: r, y: r), radius: r, startAngle: -.pi / 2, endAngle: .pi, clockwise: true)
            path.closeSubpath()
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        bg.path = path
        bg.frame = bounds
        CATransaction.commit()

        if expanded {
            // Expanded: the drawer supplies its own header, so hide the collapsed flanking fields.
            iconView.frame = .zero; labelField.frame = .zero; timerField.frame = .zero
            let inset = NotchContentView.bodyInset
            body.frame = NSRect(x: inset, y: inset, width: w - 2 * inset, height: bodyHeight)
            return
        }

        // COLLAPSED: split content around the notch cutout, centered in the menu-bar band. Icon+label
        // flank the LEFT of the camera, the timer flanks the RIGHT — no drop below (design).
        body.frame = .zero
        let cy = h - bandHeight / 2                // vertical center of the band (below the top edge)
        let center = w / 2, half = notchWidth / 2
        let leftEdge = center - half - Self.sideGap  // right boundary of the left flank
        let rightEdge = center + half + Self.sideGap // left boundary of the right flank

        var x = Self.sidePad
        let iconW = iconView.image != nil ? iconSize : 0
        if iconW > 0 {
            iconView.frame = NSRect(x: x, y: cy - iconSize / 2, width: iconSize, height: iconSize)
            x += iconSize + gap
        } else { iconView.frame = .zero }
        let labelW = fieldWidth(labelField)
        if labelW > 0 {
            labelField.frame = NSRect(x: x, y: cy - 8, width: max(0, min(labelW, leftEdge - x)), height: 16)
        } else { labelField.frame = .zero }

        let timerW = fieldWidth(timerField)
        if timerW > 0 {
            timerField.alignment = .right
            let tx = max(rightEdge, w - Self.sidePad - timerW)
            timerField.frame = NSRect(x: tx, y: cy - 8, width: w - Self.sidePad - tx, height: 16)
        } else { timerField.frame = .zero }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { onHoverEnter?() }
    override func mouseExited(with event: NSEvent) { onHoverExit?() }
    override func mouseDown(with event: NSEvent) { onHoverEnter?() }   // tap also expands (trackpad)
}
