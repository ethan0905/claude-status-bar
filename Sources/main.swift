import Cocoa
import ApplicationServices  // AXIsProcessTrustedWithOptions (Accessibility check for keystroke posting)

// Custom-drawn toggle. NSSwitch can't show its accent inside a menu (the menu's vibrant, non-key
// window draws the implicit accent gray), so we render the track + knob as layers and fill the
// "on" color explicitly. Layer-hosted so the knob can slide on Apple's switch spring (CASpringAnimation),
// with the track color crossfading; CA animations run in the render server, so they play during menu tracking.
final class ToggleView: NSView {
    static let w: CGFloat = 33, h: CGFloat = 16
    private let track = CALayer()
    private let knob = CALayer()
    private var lastToggle = Date.distantPast   // debounce: ignore a re-click within a short window
    private var hovered = false
    var isOn: Bool { didSet { updateState(animated: true) } }
    var onToggle: ((Bool) -> Void)?

    init(isOn: Bool) {
        self.isOn = isOn
        super.init(frame: NSRect(x: 0, y: 0, width: ToggleView.w, height: ToggleView.h))
        layer = CALayer()
        wantsLayer = true
        track.frame = bounds
        track.cornerRadius = bounds.height / 2
        layer?.addSublayer(track)
        let kh = bounds.height - 4, kw = kh + 3   // capsule: a touch wider than tall, like modern macOS
        knob.bounds = CGRect(x: 0, y: 0, width: kw, height: kh)
        knob.cornerRadius = kh / 2
        knob.backgroundColor = NSColor.white.cgColor
        layer?.addSublayer(knob)
        updateState(animated: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var intrinsicContentSize: NSSize { NSSize(width: ToggleView.w, height: ToggleView.h) }

    private func knobCenter() -> CGPoint {
        let kw = knob.bounds.width
        return CGPoint(x: isOn ? bounds.width - kw / 2 - 2 : kw / 2 + 2, y: bounds.height / 2)
    }

    // Track fill. ON = accent. OFF = an explicit mid gray (the system's faint off color disappears on a
    // light menu, and a dynamic NSColor's .cgColor can latch the wrong appearance → white-on-white), so
    // pick black-on-light / white-on-dark from our OWN effectiveAppearance. Hover nudges it darker.
    private func trackColor() -> CGColor {
        if isOn {
            let accent = NSColor.controlAccentColor
            return (hovered ? (accent.blended(withFraction: 0.10, of: .white) ?? accent) : accent).cgColor
        }
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let base: CGFloat = dark ? 1.0 : 0.0
        let alpha: CGFloat = (dark ? 0.30 : 0.34) + (hovered ? 0.10 : 0)
        return NSColor(white: base, alpha: alpha).cgColor
    }

    private func updateState(animated: Bool) {
        let toColor = trackColor()
        let toPos = knobCenter()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated {
            let spring = CASpringAnimation(keyPath: "position")
            spring.fromValue = NSValue(point: knob.presentation()?.position ?? knob.position)
            spring.toValue = NSValue(point: toPos)
            spring.damping = 16; spring.stiffness = 260; spring.mass = 1; spring.initialVelocity = 0
            spring.duration = spring.settlingDuration
            knob.add(spring, forKey: "position")
            let col = CABasicAnimation(keyPath: "backgroundColor")
            col.fromValue = track.presentation()?.backgroundColor ?? track.backgroundColor
            col.toValue = toColor
            col.duration = 0.2
            track.add(col, forKey: "backgroundColor")
        }
        knob.position = toPos
        track.backgroundColor = toColor
        CATransaction.commit()
    }

    // Recolor when the view actually lands in the menu (its effectiveAppearance only resolves to the
    // menu's light/dark then, not at init), so the off gray matches the menu it's drawn on.
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateState(animated: false)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true; updateState(animated: false) }
    override func mouseExited(with event: NSEvent) { hovered = false; updateState(animated: false) }

    override func mouseDown(with event: NSEvent) {
        guard Date().timeIntervalSince(lastToggle) > 0.1 else { return }
        lastToggle = Date()
        isOn.toggle()
        onToggle?(isOn)
    }
}

// A session row as a custom view so a flexible spacer can pin the timer + pill to the true trailing
// edge (a plain menu-item title can't cross the menu's reserved shortcut/submenu-arrow column).
// Layout: [icon] name  <spacer>  timer  [pill], with timer+pill pinned right via autoresizing.
final class SessionRowView: NSView {
    let id: String
    var onClick: (() -> Void)?
    private let iconView = NSImageView()
    private let spinner = NSProgressIndicator()
    private let nameField = NSTextField(labelWithString: "")
    private let timerField = NSTextField(labelWithString: "")
    private let pillView = NSImageView()
    private let pad: CGFloat = 14, iconSize: CGFloat = 16, rowH: CGFloat = 24
    private let highlightView = NSVisualEffectView()  // system selection material = exact native highlight
    private var hovered = false
    private var iconBaseTint: NSColor?       // tint when not hovered (template icons); white on hover
    private var pillNormal: NSImage?, pillSelected: NSImage?
    private var nameText = "", branchText = ""

    init(id: String, width: CGFloat) {
        self.id = id
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        highlightView.material = .selection
        highlightView.state = .active
        highlightView.isEmphasized = true
        highlightView.wantsLayer = true
        highlightView.layer?.cornerRadius = 5
        highlightView.isHidden = true
        addSubview(highlightView)
        iconView.frame = NSRect(x: pad, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.autoresizingMask = [.maxXMargin]
        addSubview(iconView)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.isDisplayedWhenStopped = false
        spinner.frame = iconView.frame
        spinner.autoresizingMask = [.maxXMargin]
        spinner.isHidden = true
        addSubview(spinner)
        nameField.font = .menuFont(ofSize: 0)
        nameField.textColor = .labelColor
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: pad + iconSize + 8, y: (rowH - 16) / 2, width: 160, height: 16)
        nameField.autoresizingMask = [.maxXMargin]
        addSubview(nameField)
        timerField.font = NSFont.monospacedSystemFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2, weight: .regular)
        timerField.textColor = .secondaryLabelColor
        timerField.alignment = .right
        timerField.autoresizingMask = [.minXMargin]
        addSubview(timerField)
        pillView.imageScaling = .scaleNone
        pillView.autoresizingMask = [.minXMargin]
        addSubview(pillView)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(icon: NSImage?, iconTint: NSColor?, spinning: Bool, name: String, branch: String, timer: String?,
                   pillNormal: NSImage?, pillSelected: NSImage?, pillInset: CGFloat, timerGap: CGFloat) {
        let w = bounds.width
        iconView.image = icon
        iconBaseTint = iconTint
        iconView.contentTintColor = hovered ? .white : iconTint
        if spinning {
            iconView.isHidden = true
            spinner.isHidden = false
            spinner.startAnimation(nil)
        } else {
            spinner.stopAnimation(nil)
            spinner.isHidden = true
            iconView.isHidden = false
        }
        nameText = name; branchText = branch
        renderName()
        self.pillNormal = pillNormal; self.pillSelected = pillSelected
        let pill = hovered ? pillSelected : pillNormal
        var pillLeft = w - pillInset
        if let pill = pill {
            pillView.isHidden = false
            pillView.image = pill
            pillView.frame = NSRect(x: w - pillInset - pill.size.width, y: (rowH - pill.size.height) / 2,
                                    width: pill.size.width, height: pill.size.height)
            pillLeft = pillView.frame.minX
        } else { pillView.isHidden = true }
        if let timer = timer {
            timerField.isHidden = false
            timerField.stringValue = timer
            // Fit the column to the text (mono font, right edge anchored at the pill): a fixed-width
            // column reserved ~50pt of blank space that pixel-truncated the name · branch next to it.
            let font = timerField.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
            let tw = ceil(timer.size(withAttributes: [.font: font]).width) + 2
            // The timer font is 2pt smaller than the name font; equal-height boxes at the same y center
            // the text, which leaves the smaller font's baseline higher and the digits visibly floating
            // next to the name. Offset the frame so the two baselines coincide.
            let nf = nameField.font ?? NSFont.menuFont(ofSize: 0)
            let baseline = { (f: NSFont) in (16 - (f.ascender - f.descender)) / 2 - f.descender }
            let dy = baseline(nf) - baseline(font)
            timerField.frame = NSRect(x: pillLeft - timerGap - tw, y: (rowH - 16) / 2 + dy, width: tw, height: 16)
        } else { timerField.isHidden = true }
        // Name stretches to whatever the timer/pill leave free (branch text made the fixed 160 tight);
        // pixel truncation via the paragraph style handles overflow.
        let nameRight = timer != nil ? timerField.frame.minX : pillLeft
        nameField.frame.size.width = max(40, nameRight - timerGap - nameField.frame.minX)
    }
    // name in the label color, " · branch" dimmed — mirrored on hover, where setting textColor
    // can't restyle an attributed string.
    private func renderName() {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        // Barely-overflowing text otherwise gets its tracking silently condensed to fit ("default
        // tightening"), so the same name renders visibly squished on a row whose timer narrows the
        // field. Constant tracking on every row; overflow shows an honest ellipsis instead.
        para.allowsDefaultTighteningForTruncation = false
        let font = NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: nameText, attributes: [
            .font: font, .paragraphStyle: para,
            .foregroundColor: hovered ? NSColor.white : .labelColor,
        ])
        if !branchText.isEmpty {
            text.append(NSAttributedString(string: " · " + branchText, attributes: [
                .font: font, .paragraphStyle: para,
                .foregroundColor: hovered ? NSColor.white.withAlphaComponent(0.75) : .secondaryLabelColor,
            ]))
        }
        nameField.attributedStringValue = text
    }
    // Custom views don't get the menu's automatic hover highlight, so draw it ourselves.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }
    private func setHover(_ h: Bool) {
        hovered = h
        highlightView.isHidden = !h
        renderName()
        timerField.textColor = h ? .white : .secondaryLabelColor
        iconView.contentTintColor = h ? .white : iconBaseTint
        if !pillView.isHidden { pillView.image = h ? pillSelected : pillNormal }
    }
    override func layout() {
        super.layout()
        highlightView.frame = bounds.insetBy(dx: 5, dy: 0)
    }
    override func mouseDown(with event: NSEvent) { onClick?() }
}

// Indented mini-row under a session: [● dot] "agentType · task…"  <spacer>  timer.
// One per RUNNING subagent. The dot follows Claude Code's own task-list styling: dim grey
// while running, green once finished. Not clickable (no highlight/tracking): it's a status
// readout, not a target — there is nowhere to jump for a subagent.
final class AgentRowView: NSView {
    let sessionId: String, agentId: String
    private let iconView = NSImageView()     // the status dot
    private let nameField = NSTextField(labelWithString: "")
    private let timerField = NSTextField(labelWithString: "")
    private let pad: CGFloat = 14, iconSize: CGFloat = 16
    private let rowH: CGFloat
    private var finished = false

    init(sessionId: String, agentId: String, width: CGFloat, rowH: CGFloat, indent: CGFloat) {
        self.sessionId = sessionId; self.agentId = agentId; self.rowH = rowH
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: rowH))
        autoresizingMask = [.width]
        let iconX = pad + indent
        iconView.frame = NSRect(x: iconX, y: (rowH - iconSize) / 2, width: iconSize, height: iconSize)
        iconView.imageScaling = .scaleNone   // the dot renders at its natural (small) size, centered
        iconView.autoresizingMask = [.maxXMargin]
        addSubview(iconView)
        let font = NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)
        nameField.font = font
        nameField.lineBreakMode = .byTruncatingTail
        nameField.frame = NSRect(x: iconX + iconSize + 6, y: (rowH - 16) / 2, width: 160, height: 16)
        nameField.autoresizingMask = [.maxXMargin]
        addSubview(nameField)
        timerField.font = NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: .regular)
        timerField.textColor = .tertiaryLabelColor
        timerField.alignment = .right
        timerField.autoresizingMask = [.minXMargin]
        addSubview(timerField)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(dot: NSImage?, agentType: String, task: String, timer: String, rightInset: CGFloat, timerGap: CGFloat) {
        if finished { return }   // settled: green dot, dimmed text, no timer
        iconView.image = dot
        renderName(agentType: agentType, task: task)
        timerField.stringValue = timer
        let tfont = timerField.font ?? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let tw = ceil(timer.size(withAttributes: [.font: tfont]).width) + 2
        // Same baseline alignment as the session row: the mono timer sits on the text's baseline.
        let nf = nameField.font ?? NSFont.menuFont(ofSize: 0)
        let baseline = { (f: NSFont) in (16 - (f.ascender - f.descender)) / 2 - f.descender }
        let dy = baseline(nf) - baseline(tfont)
        timerField.frame = NSRect(x: bounds.width - rightInset - tw, y: (rowH - 16) / 2 + dy, width: tw, height: 16)
        nameField.frame.size.width = max(40, timerField.frame.minX - timerGap - nameField.frame.minX)
    }
    private func renderName(agentType: String, task: String) {
        let para = NSMutableParagraphStyle()
        para.lineBreakMode = .byTruncatingTail
        para.allowsDefaultTighteningForTruncation = false  // constant tracking, honest ellipsis (see SessionRowView)
        let font = nameField.font ?? NSFont.menuFont(ofSize: 0)
        let text = NSMutableAttributedString(string: agentType, attributes: [
            .font: font, .paragraphStyle: para,
            .foregroundColor: finished ? NSColor.tertiaryLabelColor : .secondaryLabelColor,
        ])
        if !task.isEmpty {
            text.append(NSAttributedString(string: " · " + task, attributes: [
                .font: font, .paragraphStyle: para,
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]))
        }
        nameField.attributedStringValue = text
    }
    // The agent finished while the menu is open. NSMenu can't remove items mid-track, so the row
    // settles in place: green dot, dimmed text, timer hidden (elapsed time only means something
    // while it's still climbing). The next menu open simply doesn't rebuild the row.
    func markFinished(dot: NSImage?) {
        guard !finished else { return }
        finished = true
        iconView.image = dot
        timerField.isHidden = true
        // Re-dim the type text (task text is already tertiary).
        if let s = nameField.attributedStringValue.mutableCopy() as? NSMutableAttributedString {
            s.addAttribute(.foregroundColor, value: NSColor.tertiaryLabelColor, range: NSRange(location: 0, length: s.length))
            nameField.attributedStringValue = s
        }
    }
}

final class StatusController: NSObject, NSMenuDelegate {
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let stateDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/state.d")
    let claudeDesktopBundleID = "com.anthropic.claudefordesktop"

    var pollTimer: Timer?
    var animTimer: Timer?
    var frameIdx = 0

    let launchedAt = Date()
    var notNeededSince: Date?
    let launchGrace: TimeInterval = 5   // settle time after launch before we may quit
    let idleQuitDelay: TimeInterval = 3 // "not needed" must persist this long before quitting
    // "Hide idle after" setting (seconds): hide a resting session's ROW once it's been quiet this long.
    // Render-only — it never deletes the file or affects liveness (that's pid-driven now), and the
    // most-recent session is always kept visible (floor at one). 0 = Never. Defaults to 30 min.
    var stalePruneAge: TimeInterval { UserDefaults.standard.object(forKey: "hideIdleAfter") as? Double ?? 900 }

    struct Session {
        var id: String, state: String, label: String, project: String, projectPath: String, transcript: String
        var cwd: String         // session working directory; "" on pre-upgrade files
        var tool: String        // raw tool name from the hook (Bash, Edit, …); "" outside tool/permission
        var entrypoint: String  // CLAUDE_CODE_ENTRYPOINT: "cli", "claude-desktop", …
        var termProgram: String // TERM_PROGRAM for CLI sessions: "Apple_Terminal", "iTerm.app", …
        var tty: String         // controlling tty (e.g. /dev/ttys003) for exact focus + permission keystroke
        var tmux: Bool          // session runs inside tmux → keystrokes route via `tmux send-keys`
        var pid: Int32          // the session's `claude` process; kill(pid,0) drives liveness. 0 = pre-upgrade file.
        var started: Bool       // true once the session had real activity (a prompt/tool); a merely-opened
                                // conversation seeds started=false and stays out of the dropdown.
        var startedAt: Double, ts: Double
        var eff: String = ""   // effective state, recomputed once per tick in evaluate()
        var branch: String = ""      // git branch (or short SHA when detached); "" outside a repo
        var displayName: String = "" // project, parent-qualified when two live sessions share a name

        init(json o: [String: Any], id: String) {
            self.id = id
            self.state = o["state"] as? String ?? "idle"
            self.label = o["label"] as? String ?? ""
            self.project = o["project"] as? String ?? ""
            self.projectPath = o["project_path"] as? String ?? ""
            self.transcript = o["transcript"] as? String ?? ""
            self.cwd = o["cwd"] as? String ?? ""
            self.tool = o["tool"] as? String ?? ""
            self.entrypoint = o["entrypoint"] as? String ?? ""
            self.termProgram = o["term_program"] as? String ?? ""
            self.tty = o["tty"] as? String ?? ""
            self.tmux = o["tmux"] as? Bool ?? false
            self.pid = Int32(truncatingIfNeeded: (o["pid"] as? NSNumber)?.intValue ?? 0)
            self.started = o["started"] as? Bool ?? false
            self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
            self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
        }
    }
    // One RUNNING subagent of a session (a file in <sid>.agents.d/, written by agents.js on
    // SubagentStart, removed on SubagentStop).
    struct AgentInfo {
        var id: String          // agent_id (the filename)
        var agentType: String   // "Explore", "general-purpose", custom names; "" if absent
        var task: String        // one-line delegation prompt snippet (hook truncates to 200 chars)
        var parentAgentId: String // "" unless nested; stored for future tree display, rendered flat
        var startedAt: Double, ts: Double

        init(json o: [String: Any], id: String) {
            self.id = id
            self.agentType = o["agentType"] as? String ?? ""
            self.task = o["task"] as? String ?? ""
            self.parentAgentId = o["parentAgentId"] as? String ?? ""
            self.startedAt = (o["startedAt"] as? NSNumber)?.doubleValue ?? 0
            self.ts = (o["ts"] as? NSNumber)?.doubleValue ?? 0
        }
    }
    var sessions: [String: Session] = [:]  // id -> latest parsed per-session state
    var fileMTimes: [String: Date] = [:]   // "<id>.json" -> last-parsed mtime (re-parse only on change)
    // Kept OFF Session on purpose: reloadSessions() skips a session whose own file is unchanged,
    // which is exactly the quiet stretch while a Task runs — agents stored on Session would go
    // stale right when they matter. Parallel dicts keyed by session id sidestep that.
    var sessionAgents: [String: [AgentInfo]] = [:]  // session id -> running agents, spawn order
    var agentDirMTimes: [String: Date] = [:]        // session id -> agents.d mtime last parsed
    var gitHeadCache: [String: String] = [:]  // cwd -> resolved HEAD path ("" = confirmed non-git)
    var prevState: [String: String] = [:]  // id -> previous raw state per session
    var soundPrev: [String: String] = [:]  // id -> previous raw state (completion-sound / done-flash edge)
    var turnStart: [String: Double] = [:]  // id -> active turn start (5-min sound gate, done-flash duration)
    var menuIsOpen = false                  // refresh the dropdown's per-session timers only while open
    var sessionMenuItems: [(item: NSMenuItem, id: String)] = []
    var agentMenuItems: [(item: NSMenuItem, sessionId: String, agentId: String)] = []
    var agentOverflowItems: [(item: NSMenuItem, sessionId: String)] = []
    var activeBase = ""        // label without the elapsed clock
    var startedAt: Double = 0  // unix seconds the current turn began (0 = no clock)
    var activeColor: NSColor? = nil

    let brand = NSColor(srgbRed: 0.851, green: 0.467, blue: 0.341, alpha: 1) // #d97757, Anthropic's official "Orange" accent
    let amber = NSColor(srgbRed: 0.95, green: 0.73, blue: 0.18, alpha: 1) // "awaiting permission" yellow dot
    let islandGreen = NSColor(srgbRed: 0.31, green: 0.62, blue: 0.415, alpha: 1) // #4f9e6a, "done" state on the island
    let islandGray = NSColor(srgbRed: 0.541, green: 0.522, blue: 0.486, alpha: 1) // #8a857c, "idle"/muted on the island
    let frames: [NSImage] = StatusController.loadFrames()
    let spriteFPS: Double = 9 // tune: 8 frames per loop -> ~0.9s/cycle

    enum AnimStyle: String { case web, code, crab }
    var animStyle: AnimStyle = .web
    var showTimer = false
    var iconSystem = false // false = brand Orange; true = adaptive black/white (template image)
    var useThinkingWords = true     // rotate a playful verb ("Manifesting…") in place of "Thinking…"
    var showAtNotch = true          // on a notched Mac, render at the notch and hide the menu bar item
    var exactTerminalFocus = false  // experimental: iTerm exact-tab focus + Allow/Deny keystroke (AppleScript, one-time macOS Automation grant). tmux keystrokes need no grant and work regardless.
    var sessionWord: [String: String] = [:] // id -> current thinking word; re-picked on each entry into "thinking"

    // Notch overlay. Present only on a notched Mac with "Show at notch" on; nil => the menu bar item
    // is the surface (unchanged legacy path). The state pipeline never touches these — only the three
    // render sinks branch on notchView (see setSinkImage / applyTitle).
    let statusMenu = NSMenu()       // shared dropdown: attached to the status item OR popped at the notch
    var notchWindow: NotchWindow?
    var notchView: NotchContentView?
    var notchGeo: NotchGeometry?
    var notchScreen: NSScreen?      // the display the island is currently on (follows the cursor)
    var activeDot = false           // last render's permission-dot flag, so resize/rebuild can redraw it
    var stateAccent: NSColor?       // lead state's accent (amber/green/brand) — colors the pill timer + ping ring
    var flashDone = false           // brief green "Done ✓" state after a turn ends (design's done flash)
    var flashDoneDur = 0            // that finished turn's duration in seconds (0 = unknown)
    let doneFlashSecs: Double = 4.2 // how long the done flash holds before settling to Idle
    var doneInfo: [String: (at: Double, dur: Int)] = [:] // id -> last working→done edge (drives the flash)
    var playCompletionSound = false // chime when a turn longer than ~5 min finishes
    lazy var completionSound: NSSound? = {
        guard let p = Bundle.main.path(forResource: "completion", ofType: "mp3"),
              let s = NSSound(contentsOfFile: p, byReference: true) else { return nil }
        s.volume = 0.7 // the clip is loud at full system volume; play it a bit softer
        return s
    }()
    let notchDrop: CGFloat = 12     // expanded: gap between the notch and the dashboard body
    let collapsedLip: CGFloat = 6   // collapsed: thin rounded lip below the menu-bar band (content flanks the notch, no big drop)
    let notchContentPad: CGFloat = 12 // horizontal padding around the island's content row
    let notchExpandedWidth: CGFloat = 404 // width of the expanded (hover) dashboard panel (compact design)
    var notchCollapseWork: DispatchWorkItem? // pending collapse after the pointer leaves the island
    var notchResting = true         // last render's idle flag; a synthetic (external) pill hides while resting
    // Expanded dashboard state.
    enum NotchPage { case dashboard, settings }
    var notchPage: NotchPage = .dashboard
    var leadSession: Session?               // the session the island currently surfaces (hero card)
    weak var notchHeroIcon: NSImageView?    // big animated icon in the dashboard hero; animStep drives it
    weak var notchHeroTimer: NSTextField?   // big elapsed clock in the hero; animStep keeps it live
    weak var notchProgress: NotchProgressBar? // the working-shimmer bar in the hero
    // Claude Code's SPINNER_VERBS, minus the hyphenated/tongue-twister ones. Longest kept is ~14 chars
    // ("Hullaballooing"/"Metamorphosing"); with the timer showing they can get wide in a crowded menu bar.
    let thinkingWords = [
        "Accomplishing", "Actioning", "Actualizing", "Architecting", "Baking", "Beaming", "Beboppin'",
        "Befuddling", "Billowing", "Blanching", "Bloviating", "Boogieing", "Boondoggling", "Booping",
        "Bootstrapping", "Brewing", "Bunning", "Burrowing", "Calculating", "Canoodling", "Caramelizing",
        "Cascading", "Catapulting", "Cerebrating", "Channeling", "Channelling", "Churning", "Clauding",
        "Coalescing", "Cogitating", "Combobulating", "Composing", "Computing", "Concocting", "Considering",
        "Contemplating", "Cooking", "Crafting", "Creating", "Crunching", "Crystallizing", "Cultivating",
        "Deciphering", "Deliberating", "Determining", "Doing", "Doodling", "Drizzling", "Ebbing",
        "Effecting", "Elucidating", "Embellishing", "Enchanting", "Envisioning", "Evaporating", "Fermenting",
        "Finagling", "Flambéing", "Flowing", "Flummoxing", "Fluttering", "Forging", "Forming", "Frolicking",
        "Gallivanting", "Galloping", "Garnishing", "Generating", "Gesticulating", "Germinating", "Gitifying",
        "Grooving", "Gusting", "Harmonizing", "Hashing", "Hatching", "Herding", "Honking", "Hullaballooing",
        "Hyperspacing", "Ideating", "Imagining", "Improvising", "Incubating", "Inferring", "Infusing",
        "Ionizing", "Jitterbugging", "Julienning", "Kneading", "Leavening", "Levitating", "Lollygagging",
        "Manifesting", "Marinating", "Meandering", "Metamorphosing", "Misting", "Moonwalking", "Moseying",
        "Mulling", "Mustering", "Musing", "Nebulizing", "Nesting", "Noodling", "Nucleating", "Orbiting",
        "Orchestrating", "Osmosing", "Perambulating", "Percolating", "Perusing", "Pollinating", "Pondering",
        "Pontificating", "Pouncing", "Precipitating", "Processing", "Proofing", "Propagating", "Puttering",
        "Puzzling", "Quantumizing", "Razzmatazzing", "Reticulating", "Roosting", "Ruminating", "Sautéing",
        "Scampering", "Schlepping", "Scurrying", "Seasoning", "Shenaniganing", "Shimmying", "Simmering",
        "Skedaddling", "Sketching", "Slithering", "Smooshing", "Spelunking", "Spinning", "Sprouting",
        "Stewing", "Sublimating", "Swirling", "Swooping", "Symbioting", "Synthesizing", "Tempering",
        "Thinking", "Thundering", "Tinkering", "Tomfoolering", "Transfiguring", "Transmuting", "Twisting",
        "Undulating", "Unfurling", "Unravelling", "Vibing", "Waddling", "Wandering", "Warping",
        "Whirlpooling", "Whirring", "Whisking", "Wibbling", "Working", "Wrangling", "Zesting", "Zigzagging"]
    var iconColor: NSColor? { iconSystem ? nil : brand } // nil => render as an adaptive template
    let codeGlyphs = ["✻", "✽", "✶", "✳", "✢"]
    let codePeaks: [CGFloat] = [1.0, 1.0, 1.0, 1.0, 1.0]
    let codeDip: CGFloat = 0.14 // glyph shrinks to this at each swap
    let codeSub = 18            // sub-frames per glyph (tween smoothness)
    let codeCycle: Double = 3.8 // seconds for the full loop (lower = faster)
    lazy var codeGlyphMasks: [NSImage] = codeGlyphs.map { StatusController.glyphMask($0) }
    let crabFPS: Double = 12.5 // matches the source GIF's 0.08s frame delay
    lazy var crabFrames: [NSImage] = StatusController.decodePNGs(clawdCrabFramePNGs)
    // Template frames: bright pixels (white eyes) become transparent holes so they're
    // visible as negative space against the menu bar in System color mode.
    lazy var crabTemplateFrames: [NSImage] = crabFrames.map { adaptiveCrabFrame($0) }
    var fps: Double {
        switch animStyle {
        case .web: return spriteFPS
        case .code: return Double(codeGlyphs.count * codeSub) / codeCycle
        case .crab: return crabFPS
        }
    }
    var frameCount: Int {
        switch animStyle {
        case .web: return sparkleFrameCount   // smooth rotation steps for the SF Symbol sparkle
        case .code: return codeGlyphs.count * codeSub
        case .crab: return max(1, crabFrames.count)
        }
    }
    let sparkleFrameCount = 30

    override init() {
        super.init()
        let d = UserDefaults.standard
        if d.object(forKey: "showTimer") != nil { showTimer = d.bool(forKey: "showTimer") }
        if d.object(forKey: "iconSystem") != nil { iconSystem = d.bool(forKey: "iconSystem") }
        if d.object(forKey: "thinkingWords") != nil { useThinkingWords = d.bool(forKey: "thinkingWords") }
        if d.object(forKey: "completionSound") != nil { playCompletionSound = d.bool(forKey: "completionSound") }
        if d.object(forKey: "showAtNotch") != nil { showAtNotch = d.bool(forKey: "showAtNotch") }
        if d.object(forKey: "exactTerminalFocus") != nil { exactTerminalFocus = d.bool(forKey: "exactTerminalFocus") }
        if let s = d.string(forKey: "animStyle"), let st = AnimStyle(rawValue: s) { animStyle = st }
        statusMenu.delegate = self
        setupNotch()   // builds the notch window (and hides the status item) when a notch is present
        render(label: "", color: iconColor, animate: false, startedAt: 0)
        let t = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        pollTimer = t
        // A notch can appear/vanish at runtime (dock/undock, lid open/close) — rebuild on change.
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        tick()
        ensureHooksInstalled()
        checkForUpdate()
    }

    // MARK: notch overlay

    // Idempotent: build or tear down the notch window to match (notch present? && showAtNotch), and
    // flip the status item so exactly one surface is visible. Called from init, the toggle, and on
    // screen reconfiguration.
    func setupNotch() {
        // Once we've ever seen a physical notch, remember it — a docked-clamshell MacBook has no
        // notch screen attached yet still wants the island (on its external).
        if NotchGeometry.machineHasNotch() { UserDefaults.standard.set(true, forKey: "machineHasNotch") }
        let enabled = showAtNotch && UserDefaults.standard.bool(forKey: "machineHasNotch")
        if enabled {
            let screen = activeScreen()
            let geo = NotchGeometry.forScreen(screen)
            notchGeo = geo
            notchScreen = screen
            // Start on the bare-notch frame — exactly the physical cutout, no lip, visually nothing.
            // resizeNotchToFit() slides the flanks in when a turn becomes active.
            let band = geo.menuBarHeight > 0 ? geo.menuBarHeight : 30
            let frame = NSRect(x: geo.centerX - max(geo.notchRect.width, 1) / 2, y: geo.topY - band,
                               width: max(geo.notchRect.width, 1), height: band)
            let win = notchWindow ?? NotchWindow(contentRect: frame)
            win.setFrame(frame, display: true)
            let view = notchView ?? NotchContentView(frame: NSRect(origin: .zero, size: frame.size),
                                                     notchWidth: geo.notchRect.width, menuBarHeight: geo.menuBarHeight)
            view.frame = NSRect(origin: .zero, size: frame.size)
            view.notchWidth = geo.notchRect.width
            view.menuBarHeight = geo.menuBarHeight
            view.synthetic = geo.synthetic
            view.timerField.textColor = brand   // the live clock in the pill pops brand orange
            view.onHoverEnter = { [weak self] in self?.notchHoverEnter() }
            view.onHoverExit = { [weak self] in self?.notchHoverExit() }
            win.contentView = view
            notchWindow = win
            notchView = view
            win.orderFrontRegardless()   // the pill stays visible so it's always hoverable
            statusItem.menu = nil
            statusItem.isVisible = false
            resizeNotchToFit()           // fit the current header content on the (re)built pill
            notchDbg("notch active on \(screen.frame) synthetic=\(geo.synthetic)")
        } else {
            notchWindow?.orderOut(nil)
            notchWindow = nil
            notchView = nil
            notchGeo = nil
            notchScreen = nil
            statusItem.isVisible = true
            statusItem.menu = statusMenu
            notchDbg("notch inactive, using menu bar item")
        }
        // Repaint the current state into whichever sink is now active.
        evaluate()
    }

    // The screen the user is currently on = the one under the mouse cursor. Falls back to main.
    func activeScreen() -> NSScreen {
        let p = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(p) } ?? NSScreen.main ?? NSScreen.screens.first!
    }

    // Collapsed window frame: content flanks the notch in the menu-bar band (split design), so height
    // is just the band + a thin lip — no big drop. Width = the two symmetric flanks + the notch, or the
    // bare notch when idle. Centered on the notch.
    func collapsedFrame(_ geo: NotchGeometry, _ view: NotchContentView) -> NSRect {
        let band = geo.menuBarHeight > 0 ? geo.menuBarHeight : 30
        let dcw = view.desiredContentWidth()
        // Idle (bare notch): match the physical cutout EXACTLY — same width, same height, no lip —
        // so the resting island is indistinguishable from the camera housing. The lip only exists
        // while there's flanking content to underline.
        let panelH = dcw <= 0 ? band : band + collapsedLip
        let panelW = dcw <= 0 ? max(geo.notchRect.width, 1) : dcw + 2 * NotchContentView.sidePad
        return NSRect(x: geo.centerX - panelW / 2, y: geo.topY - panelH, width: panelW, height: panelH)
    }

    // Called every tick: if the cursor moved to a different display, move the island onto it,
    // reconfiguring real-notch vs synthetic-pill for that screen. Cheap when nothing changed.
    func updateActiveNotchScreen() {
        guard let win = notchWindow, let view = notchView else { return }
        let screen = activeScreen()
        if screen == notchScreen { return }
        if view.expanded { collapseNotch() }
        let geo = NotchGeometry.forScreen(screen)
        notchGeo = geo
        notchScreen = screen
        view.notchWidth = geo.notchRect.width
        view.menuBarHeight = geo.menuBarHeight
        view.synthetic = geo.synthetic
        win.setFrame(collapsedFrame(geo, view), display: true)
        view.needsLayout = true
        applyNotchVisibility()   // moving onto an external (synthetic) screen must not re-show an idle pill
        notchDbg("repositioned to \(screen.frame) synthetic=\(geo.synthetic)")
    }

    // Grow/shrink the collapsed pill to hug the current header content, keeping it centered on the
    // notch and never narrower than the notch itself (so the top always fuses with the cutout). No-op
    // while expanded — the expanded frame is owned by expandNotch().
    // Collapsed-frame transitions, animated like the iPhone island: activation slides DOWN from the
    // top screen edge (not sideways out of the notch), deactivation retracts fully INTO the edge
    // (height -> ~0) before parking on the bare-notch frame — so the resting state never flashes
    // the band+lip box. Width-only changes while active glide instead of jumping.
    func resizeNotchToFit() {
        guard let geo = notchGeo, let win = notchWindow, let view = notchView, !view.expanded else { return }
        let frame = collapsedFrame(geo, view)
        let cur = win.frame
        if abs(frame.width - cur.width) <= 0.5 && abs(frame.height - cur.height) <= 0.5 {
            view.needsLayout = true
            return
        }
        let bareW = max(geo.notchRect.width, 1)
        let wasBare = cur.width <= bareW + 0.5
        let isBare = frame.width <= bareW + 0.5
        if wasBare && !isBare {
            // Activating: the island expands OUT of the camera housing — width grows from the bare
            // notch to the final size, anchored on the notch center. Content fades in only after
            // the flanks have room, so text never pops in clipped.
            view.setFlankAlpha(0)
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.26
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrame(frame, display: true)
            }, completionHandler: { [weak self] in
                guard let view = self?.notchView else { return }
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.14
                    view.animateFlankAlpha(1)
                }
            })
        } else if !wasBare && isBare {
            // Deactivating: content fades first, then the island contracts back INTO the camera
            // housing — it ends at exactly the cutout's size, with no visible travel anywhere else.
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.10
                view.animateFlankAlpha(0)
            }, completionHandler: { [weak self] in
                guard let self = self, let win = self.notchWindow, let geo = self.notchGeo,
                      let view = self.notchView, !view.expanded else { return }
                // Reactivated during the fade? Bail; the activation/glide branch owns the frame now.
                guard view.desiredContentWidth() <= 0 else { view.setFlankAlpha(1); return }
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.24
                    ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    win.animator().setFrame(self.collapsedFrame(geo, view), display: true)
                }, completionHandler: { [weak self] in
                    self?.notchView?.setFlankAlpha(1)   // fields are empty while idle; ready for next turn
                })
            })
        } else {
            // Active-width change (label/timer grew or shrank): quick glide, no jump. Also restores
            // flank alpha in case a new turn interrupted a mid-fade deactivation.
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                win.animator().setFrame(frame, display: true)
                view.animateFlankAlpha(1)
            }
        }
        view.needsLayout = true
    }

    // MARK: notch expand / collapse (hover)

    // Hover is driven by a mouse-LOCATION poll, not raw enter/exit events. The small collapsed pill
    // (whose width also jitters while a turn animates) produced constant enter/exit right at its edge,
    // toggling expand/collapse. Instead: expand on a genuine enter, then poll the real cursor position
    // and collapse only once it has truly left the current (large, when expanded) window frame. The big
    // expanded frame gives wide hysteresis, so edge jitter can't flip it.
    func notchHoverEnter() {
        guard let win = notchWindow, let view = notchView else { return }
        guard win.frame.contains(NSEvent.mouseLocation) else { return }   // ignore stray enters
        if !view.expanded { notchPage = .dashboard; expandNotch() }        // fresh open → dashboard
        startNotchHoverPoll()
    }
    func notchHoverExit() { startNotchHoverPoll() }

    private func startNotchHoverPoll() {
        notchCollapseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.notchHoverPoll() }
        notchCollapseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }
    private func notchHoverPoll() {
        guard let win = notchWindow, let view = notchView, view.expanded else { notchCollapseWork = nil; return }
        if win.frame.contains(NSEvent.mouseLocation) {
            startNotchHoverPoll()          // still inside the panel → keep it open, keep watching
        } else {
            notchCollapseWork = nil
            collapseNotch()                // pointer genuinely left → collapse
        }
    }

    func expandNotch(animated: Bool = true) {
        guard let geo = notchGeo, let win = notchWindow, let view = notchView else { return }
        let bodyH = populateNotchBody()
        view.setExpanded(true, bodyHeight: bodyH)
        let w = notchExpandedWidth
        let h = geo.menuBarHeight + notchDrop + bodyH + 2 * NotchContentView.bodyInset
        let frame = NSRect(x: geo.centerX - w / 2, y: geo.topY - h, width: w, height: h)
        guard animated else { win.setFrame(frame, display: true); view.needsLayout = true; return }
        view.body.alphaValue = 0
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            // Slight overshoot on the trailing control point → a soft spring, like boring.notch.
            ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.22, 0.9, 0.28, 1.06)
            ctx.allowsImplicitAnimation = true
            win.animator().setFrame(frame, display: true)
            view.body.animator().alphaValue = 1   // content fades in as the panel drops
        }, completionHandler: { [weak self] in
            // Pin the exact target frame — the animator can settle a hair off after the overshoot,
            // which would leave the wide content clipped by a slightly-narrow window.
            guard let self = self, self.notchView?.expanded == true else { return }
            win.setFrame(frame, display: true)
            notchDbg("expanded settled at \(win.frame), target=\(frame), bodyH=\(bodyH)")
        })
        notchDbg("expanding to \(frame), bodyH=\(bodyH)")
    }

    func collapseNotch() {
        guard let geo = notchGeo, let win = notchWindow, let view = notchView, view.expanded else { return }
        let panelW = max(geo.notchRect.width, view.desiredContentWidth() + 2 * notchContentPad)
        let panelH = geo.menuBarHeight + notchDrop
        let frame = NSRect(x: geo.centerX - panelW / 2, y: geo.topY - panelH, width: panelW, height: panelH)
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.24
            ctx.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().setFrame(frame, display: true)
            view.body.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // Tear down the rows only after the fade, so nothing pops out mid-collapse.
            self?.notchView?.setExpanded(false, bodyHeight: 0)
            self?.notchView?.body.subviews.forEach { $0.removeFromSuperview() }
            self?.notchView?.body.alphaValue = 1
            self?.notchHeroIcon = nil
            self?.notchHeroTimer = nil
            self?.notchProgress = nil
            self?.notchPage = .dashboard   // always reopen on the dashboard
        })
        notchDbg("collapsed to \(frame)")
    }

    // Rebuild the expanded body in place (after a setting toggles). No fade/resize animation, so
    // flipping a switch just updates the list under the pointer without a flash.
    func refreshNotchExpanded() {
        guard let view = notchView, view.expanded else { return }
        expandNotch(animated: false)
    }

    // MARK: notch expanded body (dashboard / settings)

    // Build the expanded panel into view.body: a top toolbar plus the current page (dashboard or
    // settings). Returns the total height. Stacked with the body origin at bottom-left.
    func populateNotchBody() -> CGFloat {
        guard let view = notchView else { return 0 }
        view.body.subviews.forEach { $0.removeFromSuperview() }
        // CRITICAL: the body is still at the collapsed width when we build into it (expandNotch grows
        // the window AFTER this returns). AppKit autoresizing is delta-based, so letting the body
        // resize its children when it later jumps to full width would shove every right-anchored
        // (.minXMargin) subview off-screen by that delta. We lay out at the fixed expanded width and
        // forbid the body from touching child frames on resize.
        view.body.autoresizesSubviews = false
        let innerW = notchExpandedWidth - 2 * NotchContentView.bodyInset

        let toolbar = islandToolbar(width: innerW)
        let page = (notchPage == .settings) ? buildSettingsPage(width: innerW) : buildDashboard(width: innerW)
        let gap: CGFloat = 4
        let total = toolbar.frame.height + gap + page.frame.height

        page.frame = NSRect(x: 0, y: 0, width: innerW, height: page.frame.height)
        toolbar.frame = NSRect(x: 0, y: total - toolbar.frame.height, width: innerW, height: toolbar.frame.height)
        page.autoresizingMask = [.width]; toolbar.autoresizingMask = [.width]
        view.body.addSubview(page)
        view.body.addSubview(toolbar)
        return total
    }

    // Top bar (design's header row): dashboard → serif "Claude" wordmark + "STATUS", right "N active"
    // chip + boxed gear; settings → back chevron + "Settings". A hairline separates it from the page.
    func islandToolbar(width: CGFloat) -> NSView {
        let h: CGFloat = 36, cy: CGFloat = (h - 1) / 2 + 1   // content centered above the hairline
        let bar = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        let sep = NSView(frame: NSRect(x: 2, y: 0, width: width - 4, height: 1))
        sep.wantsLayer = true
        sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        sep.autoresizingMask = [.width]
        bar.addSubview(sep)

        if notchPage == .settings {
            let back = islandIconButton("chevron.left") { [weak self] in self?.showNotchDashboard() }
            back.frame = NSRect(x: 2, y: cy - 11, width: 26, height: 22)
            bar.addSubview(back)
            let title = islandLabel("Settings", size: 14, weight: .medium, color: .white)
            title.frame = NSRect(x: 32, y: cy - 8, width: width - 64, height: 17)
            bar.addSubview(title)
            return bar
        }

        // "Claude" in a serif face (New York ≈ the design's Newsreader) + a letterspaced "STATUS".
        let wordmark = NSTextField(labelWithString: "Claude")
        let serif: NSFont = {
            let base = NSFont.systemFont(ofSize: 18, weight: .medium)
            if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: 18) { return f }
            return base
        }()
        wordmark.font = serif
        wordmark.textColor = NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)
        let ww = ceil(("Claude" as NSString).size(withAttributes: [.font: serif]).width) + 6
        wordmark.frame = NSRect(x: 4, y: cy - 12, width: ww, height: 24)
        bar.addSubview(wordmark)
        let status = NSTextField(labelWithString: "")
        status.attributedStringValue = NSAttributedString(string: "STATUS", attributes: [
            .font: NSFont.systemFont(ofSize: 9.5, weight: .semibold),
            .kern: 1.6,
            .foregroundColor: islandGray,
        ])
        status.frame = NSRect(x: 4 + ww + 6, y: cy - 8, width: 70, height: 13)
        bar.addSubview(status)

        // Boxed sliders button (design: 28×28 rounded square) — right edge.
        let gear = islandIconButton("slider.horizontal.3", boxed: true) { [weak self] in self?.showNotchSettings() }
        gear.frame = NSRect(x: width - 2 - 28, y: cy - 14, width: 28, height: 28)
        gear.autoresizingMask = [.minXMargin]
        bar.addSubview(gear)

        // "N active" count pill just before the gear.
        let now = Date().timeIntervalSince1970
        let n = sessions.values.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            return eff == "thinking" || eff == "tool" || eff == "permission"
        }.count
        let chipLabel = islandLabel("\(n) active", size: 11, weight: .semibold, color: NSColor(white: 1, alpha: 0.7))
        let lw = ceil(("\(n) active" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11, weight: .semibold)]).width) + 4
        let chipW = lw + 18, chipH: CGFloat = 21
        let chip = NSView(frame: NSRect(x: width - 2 - 28 - 8 - chipW, y: cy - chipH / 2, width: chipW, height: chipH))
        chip.wantsLayer = true
        chip.layer?.backgroundColor = NSColor(white: 1, alpha: 0.07).cgColor
        chip.layer?.cornerRadius = chipH / 2
        chip.autoresizingMask = [.minXMargin]
        chipLabel.frame = NSRect(x: 9, y: (chipH - 14) / 2, width: lw, height: 14)
        chip.addSubview(chipLabel)
        bar.addSubview(chip)
        return bar
    }

    // Design's state accent: amber while a permission waits, green on done, dim gray at rest,
    // brand orange while working/thinking. Drives the session-row status dot on the island.
    func islandStateColor(_ eff: String, state: String) -> NSColor {
        switch eff {
        case "permission":       return amber
        case "thinking", "tool": return brand
        default:                 return state == "done" ? islandGreen : islandGray
        }
    }

    // ── Icon design system ────────────────────────────────────────────────────────
    // One SF Symbol config for the whole panel so every glyph shares a family/weight — a lightweight,
    // dependency-free icon system (SF Symbols is the native "library"). Returns a TEMPLATE image; the
    // caller sets contentTintColor. (Palette-colored symbol configs can render empty inside a non-key
    // borderless panel, so template + tint is the reliable path here.)
    func panelIcon(_ symbol: String, size: CGFloat = 13, weight: NSFont.Weight = .semibold) -> NSImage? {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
        img?.isTemplate = true
        return img
    }

    func islandIconButton(_ symbol: String, boxed: Bool = false, action: @escaping () -> Void) -> IslandRow {
        let w: CGFloat = boxed ? 28 : 26, h: CGFloat = boxed ? 28 : 22
        let btn = IslandRow(height: h)
        btn.frame = NSRect(x: 0, y: 0, width: w, height: h)
        if boxed {   // design's 28×28 rounded-square button chrome
            btn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.06).cgColor
            btn.layer?.cornerRadius = 8
        }
        let iv = NSImageView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        iv.image = panelIcon(symbol)   // central icon config → template glyph
        iv.contentTintColor = NSColor(white: 1, alpha: 0.85)
        iv.imageScaling = .scaleProportionallyUpOrDown
        btn.addSubview(iv)
        btn.onClick = action
        return btn
    }

    func showNotchSettings() { notchPage = .settings; expandNotch(animated: false) }
    func showNotchDashboard() { notchPage = .dashboard; expandNotch(animated: false) }

    // Dashboard = a single vertical column (matches the design): full-width hero card on top,
    // then a "SESSIONS" header over a card of clickable session rows.
    func buildDashboard(width: CGFloat) -> NSView {
        let now = Date().timeIntervalSince1970
        let hero = islandHeroCard(width: width)
        let all = notchVisibleSessions(now: now)
        let shown = Array(all.prefix(5))
        let header = islandSectionHeader("Sessions", width: width)
        let rows: [NSView] = shown.map { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            return islandSessionRow(s, eff: eff, width: width)
        }
        // Design: bare rows with a 2px gap (hover/lead highlight per row) — no grouped card.
        let rowGap: CGFloat = 2
        let listH = rows.reduce(0) { $0 + $1.frame.height } + rowGap * CGFloat(max(0, rows.count - 1))
        let list = NSView(frame: NSRect(x: 0, y: 0, width: width, height: listH))
        var ly = listH
        for r in rows {
            ly -= r.frame.height
            r.frame = NSRect(x: 0, y: ly, width: width, height: r.frame.height)
            r.autoresizingMask = [.width]
            list.addSubview(r)
            ly -= rowGap
        }
        if all.count > shown.count { notchDbg("sessions list hid \(all.count - shown.count) rows") }

        let gHero: CGFloat = 10, gHdr: CGFloat = 4
        let total = hero.frame.height + gHero + header.frame.height + gHdr + list.frame.height
        let c = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        var y = total
        for (v, before): (NSView, CGFloat) in [(hero, 0), (header, gHero), (list, gHdr)] {
            y -= before + v.frame.height
            v.frame = NSRect(x: 0, y: y, width: width, height: v.frame.height)
            v.autoresizingMask = [.width]
            c.addSubview(v)
        }
        return c
    }

    // Full-width hero: accent-soft icon tile + name/project, right-aligned status + big timer,
    // optional "$ tool" chip, working shimmer, and a jump-to-session button. Stacked top→down.
    func islandHeroCard(width: CGFloat) -> NSView {
        let now = Date().timeIntervalSince1970
        let lead = leadSession
        let eff = lead.map { $0.eff.isEmpty ? effectiveState($0, now: now) : $0.eff } ?? "idle"
        let working = (eff == "thinking" || eff == "tool")
        let doneNow = flashDone && lead != nil          // green "Done ✓" flash mirrors the pill
        let toolText = lead?.tool ?? ""
        let hasChip = (eff == "tool" || eff == "permission") && !toolText.isEmpty
        let hasJump = lead != nil
        // Allow/Deny keystroke row: only when a permission is waiting AND we can reliably target the
        // session's prompt (tmux pane, or iTerm with the grant on). Otherwise the buttons are hidden.
        let hasPermActions = eff == "permission" && (lead.map(canSendPermissionKey) ?? false)

        let accent: NSColor = eff == "permission" ? amber
                            : doneNow ? islandGreen
                            : working ? brand
                            : NSColor(white: 1, alpha: 0.35)
        let hasProgress = (eff == "tool")   // running command → shimmer (design: working only)

        // Block heights (compact design): a 34px top row, then optional progress / tool chip / jump link.
        let pad: CGFloat = 12, topRow: CGFloat = 34
        let progBlk: CGFloat = hasProgress ? 11 + 3 : 0
        let chipBlk: CGFloat = hasChip ? 11 + 30 : 0
        let permBlk: CGFloat = hasPermActions ? 10 + 32 : 0   // Allow/Deny button row
        let jumpBlk: CGFloat = hasJump ? 9 + 16 : 0
        let h = pad + topRow + progBlk + chipBlk + permBlk + jumpBlk + pad
        let card = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        card.wantsLayer = true
        card.layer?.backgroundColor = accent.withAlphaComponent(0.11).cgColor  // accent-soft wash (design)
        card.layer?.cornerRadius = 14
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.08).cgColor
        card.layer?.masksToBounds = true
        // Top accent hairline across the card (design's glowing edge).
        let hair = CAGradientLayer()
        hair.frame = NSRect(x: 0, y: h - 1, width: width, height: 1)
        hair.startPoint = CGPoint(x: 0, y: 0.5); hair.endPoint = CGPoint(x: 1, y: 0.5)
        hair.colors = [NSColor.clear.cgColor, accent.withAlphaComponent(0.6).cgColor, NSColor.clear.cgColor]
        hair.autoresizingMask = [.layerWidthSizable, .layerMinYMargin]
        card.layer?.addSublayer(hair)

        var y = h - pad   // running cursor at the TOP of the content box, moving down

        // ── top row: dark icon tile + [name … timer] over [status · path] ──────────
        let tileD: CGFloat = 34
        let tile = NSView(frame: NSRect(x: pad, y: y - tileD, width: tileD, height: tileD))
        tile.wantsLayer = true
        tile.layer?.backgroundColor = NSColor(white: 0, alpha: 0.28).cgColor   // dark well (design)
        tile.layer?.cornerRadius = 10
        tile.layer?.borderWidth = 1
        tile.layer?.borderColor = NSColor(white: 1, alpha: 0.05).cgColor
        tile.layer?.masksToBounds = true
        let iconD: CGFloat = 24
        let icon = NSImageView(frame: NSRect(x: (tileD - iconD) / 2, y: (tileD - iconD) / 2, width: iconD, height: iconD))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.contentTintColor = .white
        if working { icon.image = iconImage(color: nil, frame: frameIdx); notchHeroIcon = icon }
        else if eff == "permission" { icon.image = restingIcon(color: amber) }
        else if doneNow { icon.image = doneIcon() }
        else { icon.image = restingIcon(color: nil) }
        // Soft accent halo behind the icon while active (design: diffuse pulsing glow, not a hard ring).
        if working || eff == "permission" {
            let haloD: CGFloat = 26
            let halo = CALayer()
            halo.frame = NSRect(x: (tileD - haloD) / 2, y: (tileD - haloD) / 2, width: haloD, height: haloD)
            halo.cornerRadius = haloD / 2
            halo.backgroundColor = accent.withAlphaComponent(0.5).cgColor
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3; pulse.toValue = 0.75
            pulse.duration = 1.15; pulse.autoreverses = true; pulse.repeatCount = .infinity
            halo.add(pulse, forKey: "halo")
            tile.layer?.insertSublayer(halo, at: 0)
        }
        tile.addSubview(icon)
        card.addSubview(tile)

        let cx: CGFloat = pad + tileD + 12   // content column left edge
        // Timer text: turn while working, wait while a permission sits, duration on done.
        var timerText = ""
        if working, let st = lead?.startedAt, st > 0 { timerText = elapsed(max(0, Int(now - st))) }
        else if eff == "permission", let ts = lead?.ts { timerText = elapsed(max(0, Int(now - ts))) }
        else if doneNow, flashDoneDur > 0 { timerText = elapsed(flashDoneDur) }

        // Row A: big timer pinned right, name fills the rest (truncating against it).
        var nameRight = width - pad
        if !timerText.isEmpty {
            let tw: CGFloat = 92
            let t = islandLabel(timerText, size: 17, weight: .semibold, color: NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1), mono: true)
            t.alignment = .right
            t.frame = NSRect(x: width - pad - tw, y: y - 20, width: tw, height: 20)
            t.autoresizingMask = [.minXMargin]
            card.addSubview(t)
            notchHeroTimer = t
            nameRight = width - pad - tw - 8
        }
        let name = islandLabel(lead.map(sessionName) ?? "Idle", size: 14, weight: .semibold, color: NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1))
        name.frame = NSRect(x: cx, y: y - 18, width: max(20, nameRight - cx), height: 17)
        name.autoresizingMask = [.width]; card.addSubview(name)

        // Row B: status (accent) · path (mono gray), inline with a middot separator.
        let statusStr = doneNow ? "Done" : (lead.map { statusText($0, eff: eff) } ?? "Waiting for a session")
        let stFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
        let stw = ceil((statusStr as NSString).size(withAttributes: [.font: stFont]).width) + 8
        let status = islandLabel(statusStr, size: 11.5, weight: .semibold,
                                 color: (working || eff == "permission" || doneNow) ? accent : NSColor(white: 1, alpha: 0.55))
        status.frame = NSRect(x: cx, y: y - 34, width: stw, height: 14); card.addSubview(status)
        var sub = lead?.projectPath ?? ""
        if sub.isEmpty, let l = lead {
            sub = surfaceTag(l.entrypoint) == "APP" ? "Claude Desktop" : l.termProgram
        }
        if !sub.isEmpty {
            let dotX = cx + stw + 6
            let midDot = NSView(frame: NSRect(x: dotX, y: y - 34 + 6, width: 3, height: 3))
            midDot.wantsLayer = true
            midDot.layer?.backgroundColor = NSColor(white: 0.42, alpha: 1).cgColor
            midDot.layer?.cornerRadius = 1.5
            card.addSubview(midDot)
            let projX = dotX + 3 + 6
            let proj = islandLabel(sub, size: 11, weight: .regular, color: NSColor(srgbRed: 0.541, green: 0.518, blue: 0.482, alpha: 1), mono: true)
            proj.frame = NSRect(x: projX, y: y - 34, width: max(10, width - pad - projX), height: 14)
            proj.autoresizingMask = [.width]; card.addSubview(proj)
        }
        y -= topRow

        // ── working shimmer (design: before the tool chip) ─────────────────────────
        if hasProgress {
            y -= 11
            let prog = NotchProgressBar(frame: NSRect(x: pad, y: y - 3, width: width - 2 * pad, height: 3))
            prog.autoresizingMask = [.width]
            prog.setActive(true, color: brand)
            card.addSubview(prog); notchProgress = prog
            y -= 3
        }

        // ── tool chip ("$ npm run …") ─────────────────────────────────────────────
        if hasChip {
            y -= 11
            let chip = NSView(frame: NSRect(x: pad, y: y - 30, width: width - 2 * pad, height: 30))
            chip.wantsLayer = true
            chip.layer?.backgroundColor = NSColor(white: 0, alpha: 0.36).cgColor
            chip.layer?.cornerRadius = 9
            chip.layer?.borderWidth = 1
            chip.layer?.borderColor = NSColor(white: 1, alpha: 0.06).cgColor
            chip.autoresizingMask = [.width]
            let dollar = islandLabel("$", size: 11.5, weight: .bold, color: NSColor(srgbRed: 0.91, green: 0.65, blue: 0.18, alpha: 1), mono: true)
            dollar.frame = NSRect(x: 11, y: 8, width: 10, height: 15); chip.addSubview(dollar)
            let cmd = islandLabel(toolText, size: 11.5, weight: .regular, color: NSColor(white: 0.9, alpha: 1), mono: true)
            cmd.frame = NSRect(x: 25, y: 8, width: width - 2 * pad - 36, height: 15); cmd.autoresizingMask = [.width]; chip.addSubview(cmd)
            card.addSubview(chip)
            y -= 30
        }

        // ── Allow / Deny keystroke buttons (permission only, when we can target the prompt) ──
        if hasPermActions, let lead = lead {
            y -= 10
            let rowH: CGFloat = 32
            let gap: CGFloat = 8
            let btnW = (width - 2 * pad - gap) / 2
            let denyBtn = islandPermButton("Deny", filled: false, accent: NSColor(srgbRed: 0.86, green: 0.35, blue: 0.32, alpha: 1),
                                           frame: NSRect(x: pad, y: y - rowH, width: btnW, height: rowH)) { [weak self] in
                self?.answerPermission(lead, .deny)
            }
            let allowBtn = islandPermButton("Allow", filled: true, accent: islandGreen,
                                            frame: NSRect(x: pad + btnW + gap, y: y - rowH, width: btnW, height: rowH)) { [weak self] in
                self?.answerPermission(lead, .allow)
            }
            denyBtn.autoresizingMask = [.width]
            allowBtn.autoresizingMask = [.width, .minXMargin]
            card.addSubview(denyBtn); card.addSubview(allowBtn)
            y -= rowH
        }

        // ── jump to session (subtle right-aligned text link, design) ───────────────
        if let lead = lead {
            y -= 9
            let jText = "Jump to session"
            let jFont = NSFont.systemFont(ofSize: 12, weight: .medium)
            let jlw = ceil((jText as NSString).size(withAttributes: [.font: jFont]).width) + 8
            let arrowD: CGFloat = 12, jgap: CGFloat = 5
            let groupW = jlw + jgap + arrowD
            let jx = width - pad - groupW
            let jump = IslandRow(height: 16)
            jump.frame = NSRect(x: jx - 6, y: y - 16, width: groupW + 12, height: 16)
            jump.autoresizingMask = [.minXMargin]
            let linkColor = NSColor(srgbRed: 0.761, green: 0.733, blue: 0.694, alpha: 1)
            let jl = islandLabel(jText, size: 12, weight: .medium, color: linkColor)
            jl.frame = NSRect(x: 6, y: 0, width: jlw, height: 15); jump.addSubview(jl)
            let arrow = NSImageView(frame: NSRect(x: 6 + jlw + jgap, y: (16 - arrowD) / 2, width: arrowD, height: arrowD))
            arrow.image = panelIcon("arrow.right", size: 11, weight: .semibold)
            arrow.contentTintColor = linkColor
            arrow.imageScaling = .scaleProportionallyUpOrDown
            jump.addSubview(arrow)
            let sid = lead.id, ep = lead.entrypoint, tp = lead.termProgram, tt = lead.tty, tx = lead.tmux
            jump.onClick = { [weak self] in self?.collapseNotch(); self?.openSession(sid, entrypoint: ep, termProgram: tp, tty: tt, tmux: tx) }
            card.addSubview(jump)
        }
        return card
    }

    // A permission Allow/Deny button: a filled accent pill (Allow) or an outlined one (Deny), with a
    // centered label. Reuses IslandRow for the hover highlight + click.
    func islandPermButton(_ title: String, filled: Bool, accent: NSColor, frame: NSRect, action: @escaping () -> Void) -> IslandRow {
        let btn = IslandRow(height: frame.height)
        btn.frame = frame
        btn.wantsLayer = true
        btn.layer?.cornerRadius = 9
        btn.layer?.borderWidth = 1
        if filled {
            btn.layer?.backgroundColor = accent.withAlphaComponent(0.22).cgColor
            btn.layer?.borderColor = accent.withAlphaComponent(0.55).cgColor
        } else {
            btn.layer?.backgroundColor = NSColor(white: 1, alpha: 0.04).cgColor
            btn.layer?.borderColor = accent.withAlphaComponent(0.45).cgColor
        }
        let labelColor = filled ? accent.blended(withFraction: 0.35, of: .white) ?? accent : accent
        let lbl = islandLabel(title, size: 12.5, weight: .semibold, color: labelColor)
        lbl.alignment = .center
        lbl.frame = NSRect(x: 0, y: (frame.height - 15) / 2, width: frame.width, height: 15)
        lbl.autoresizingMask = [.width]
        btn.addSubview(lbl)
        btn.onClick = action
        return btn
    }

    // Answer the waiting permission by delivering the keystroke, then collapse the notch so focus
    // returns to the session. Guarded by canSendPermissionKey (buttons only render when we can send).
    func answerPermission(_ s: Session, _ answer: PermAnswer) {
        switch sendPermissionKey(s, answer) {
        case .sent:
            collapseNotch()          // let the user see the result in their terminal
        case .denied:
            handleGrantDenied()      // iTerm Automation grant declined → turn the toggle off
            collapseNotch()
        case .unsupported:
            // Shouldn't happen (buttons gated by canSendPermissionKey), but fall back to focusing.
            openSession(s.id, entrypoint: s.entrypoint, termProgram: s.termProgram, tty: s.tty, tmux: s.tmux)
        }
    }

    // Compact settings (new design): a grouped "Icon style / Accent" card, a grouped toggles card,
    // a Hide-idle segmented control, then update/quit and a centered version footer.
    func buildSettingsPage(width: CGFloat) -> NSView {
        var blocks: [(view: NSView, gapBefore: CGFloat)] = []
        func add(_ v: NSView, gap: CGFloat) { blocks.append((v, gap)) }

        add(settingsCard([iconStyleRow(width: width), accentRow(width: width)], width: width), gap: 0)

        let toggles: [(String, Bool, (Bool) -> Void)] = [
            ("Show elapsed timer", showTimer, { [weak self] on in
                self?.showTimer = on; UserDefaults.standard.set(on, forKey: "showTimer"); self?.applyTitle() }),
            ("Completion sound", playCompletionSound, { [weak self] on in
                self?.playCompletionSound = on; UserDefaults.standard.set(on, forKey: "completionSound") }),
            ("Playful thinking words", useThinkingWords, { [weak self] on in
                self?.useThinkingWords = on; UserDefaults.standard.set(on, forKey: "thinkingWords"); self?.evaluate() }),
            ("Live at the notch", showAtNotch, { [weak self] on in
                self?.showAtNotch = on; UserDefaults.standard.set(on, forKey: "showAtNotch"); self?.setupNotch() }),
        ]
        add(settingsCard(toggles.map { toggleRowCompact($0.0, isOn: $0.1, width: width, onToggle: $0.2) }, width: width), gap: 10)

        let hideLabel = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 14))
        let hl = islandLabel("Hide idle sessions after", size: 11, weight: .semibold, color: islandGray)
        hl.frame = NSRect(x: 2, y: 0, width: width - 4, height: 13); hl.autoresizingMask = [.width]; hideLabel.addSubview(hl)
        add(hideLabel, gap: 13)
        let hideVals: [Double] = [0, 300, 900, 1800, 3600]
        let seg = IslandSegmented(items: ["Never", "5m", "15m", "30m", "1h"],
                                  selected: hideVals.firstIndex(of: stalePruneAge) ?? 3, height: 30, brand: brand)
        seg.frame = NSRect(x: 0, y: 0, width: width, height: 30)
        seg.onSelect = { i in UserDefaults.standard.set(hideVals[i], forKey: "hideIdleAfter") }
        add(seg, gap: 6)

        let hasUpdate = (UserDefaults.standard.string(forKey: "latestVersion")).map { versionIsNewer($0, than: currentVersion) } ?? false
        if hasUpdate {
            add(islandActionRow("Update available", trailing: "", width: width) { [weak self] in self?.openLatestRelease() }, gap: 11)
        }
        add(islandActionRow("Quit Claude Status Bar", trailing: "", width: width) { NSApp.terminate(nil) }, gap: hasUpdate ? 2 : 11)

        let foot = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 16))
        let fl = islandLabel("Claude Status Bar · v\(currentVersion)", size: 10.5, weight: .regular,
                             color: NSColor(srgbRed: 0.373, green: 0.353, blue: 0.322, alpha: 1))
        fl.alignment = .center
        fl.frame = NSRect(x: 0, y: 2, width: width, height: 13); fl.autoresizingMask = [.width]; foot.addSubview(fl)
        add(foot, gap: 12)

        let total = blocks.reduce(0) { $0 + $1.gapBefore + $1.view.frame.height }
        let c = NSView(frame: NSRect(x: 0, y: 0, width: width, height: total))
        var y = total
        for b in blocks {
            y -= b.gapBefore + b.view.frame.height
            b.view.frame = NSRect(x: 0, y: y, width: width, height: b.view.frame.height)
            b.view.autoresizingMask = [.width]
            c.addSubview(b.view)
        }
        return c
    }

    // A grouped rounded card that stacks rows top→down with hairline dividers between them (design).
    func settingsCard(_ rows: [NSView], width: CGFloat) -> NSView {
        let totalH = rows.reduce(0) { $0 + $1.frame.height } + CGFloat(max(0, rows.count - 1))
        let card = NSView(frame: NSRect(x: 0, y: 0, width: width, height: totalH))
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(white: 1, alpha: 0.035).cgColor
        card.layer?.cornerRadius = 13
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(white: 1, alpha: 0.07).cgColor
        var y = totalH
        for (i, r) in rows.enumerated() {
            y -= r.frame.height
            r.frame = NSRect(x: 0, y: y, width: width, height: r.frame.height)
            r.autoresizingMask = [.width]
            card.addSubview(r)
            if i < rows.count - 1 {
                y -= 1
                let sep = NSView(frame: NSRect(x: 12, y: y, width: width - 24, height: 1))
                sep.wantsLayer = true
                sep.layer?.backgroundColor = NSColor(white: 1, alpha: 0.05).cgColor
                sep.autoresizingMask = [.width]
                card.addSubview(sep)
            }
        }
        return card
    }

    // "Icon style" row: label left, a dark segmented pill of 3 icon-only buttons right.
    func iconStyleRow(width: CGFloat) -> NSView {
        let h: CGFloat = 47
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        let l = islandLabel("Icon style", size: 13, weight: .medium, color: NSColor(srgbRed: 0.949, green: 0.929, blue: 0.894, alpha: 1))
        l.frame = NSRect(x: 12, y: (h - 16) / 2, width: 120, height: 16); row.addSubview(l)

        let styles: [AnimStyle] = [.web, .code, .crab]
        let btnW: CGFloat = 36, btnH: CGFloat = 27, gap: CGFloat = 3, pad: CGFloat = 3
        let pillW = pad * 2 + btnW * 3 + gap * 2, pillH = pad * 2 + btnH
        let pill = NSView(frame: NSRect(x: width - 12 - pillW, y: (h - pillH) / 2, width: pillW, height: pillH))
        pill.wantsLayer = true
        pill.layer?.backgroundColor = NSColor(white: 0, alpha: 0.3).cgColor
        pill.layer?.cornerRadius = 9
        pill.autoresizingMask = [.minXMargin]
        for (i, st) in styles.enumerated() {
            let on = animStyle == st
            let b = IslandRow(height: btnH)
            b.frame = NSRect(x: pad + CGFloat(i) * (btnW + gap), y: pad, width: btnW, height: btnH)
            b.layer?.cornerRadius = 6
            if on { b.layer?.backgroundColor = brand.withAlphaComponent(0.9).cgColor }
            let iv = NSImageView(frame: NSRect(x: (btnW - 16) / 2, y: (btnH - 16) / 2, width: 16, height: 16))
            iv.imageScaling = .scaleProportionallyUpOrDown
            switch st {
            case .web:  iv.image = sparkleIcon(color: on ? .white : islandGray, frame: 0)
            case .code: iv.image = codeIcon(color: on ? .white : islandGray, glyph: 3, scale: 1)
            case .crab: iv.image = crabIcon(color: nil, frame: 0); iv.contentTintColor = on ? .white : islandGray
            }
            b.addSubview(iv)
            b.onClick = { [weak self] in
                self?.animStyle = st; UserDefaults.standard.set(st.rawValue, forKey: "animStyle")
                self?.evaluate(); self?.refreshNotchExpanded()
            }
            pill.addSubview(b)
        }
        row.addSubview(pill)
        return row
    }

    // "Accent" row: label left, two circular color swatches (Brand / Adaptive) right.
    func accentRow(width: CGFloat) -> NSView {
        let h: CGFloat = 44
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: h))
        let l = islandLabel("Accent", size: 13, weight: .medium, color: NSColor(srgbRed: 0.949, green: 0.929, blue: 0.894, alpha: 1))
        l.frame = NSRect(x: 12, y: (h - 16) / 2, width: 120, height: 16); row.addSubview(l)

        let opts: [(Bool, NSColor)] = [(false, brand), (true, NSColor(srgbRed: 0.906, green: 0.886, blue: 0.847, alpha: 1))]
        let swD: CGFloat = 24, gap: CGFloat = 10
        let totalW = swD * 2 + gap
        let startX = width - 12 - totalW
        for (i, o) in opts.enumerated() {
            let on = iconSystem == o.0
            let b = IslandRow(height: swD)
            b.frame = NSRect(x: startX + CGFloat(i) * (swD + gap), y: (h - swD) / 2, width: swD, height: swD)
            b.layer?.cornerRadius = swD / 2
            b.layer?.masksToBounds = true
            b.layer?.backgroundColor = o.1.cgColor
            b.layer?.borderWidth = 2
            b.layer?.borderColor = (on ? NSColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1) : NSColor(white: 1, alpha: 0.2)).cgColor
            b.autoresizingMask = [.minXMargin]
            let sys = o.0
            b.onClick = { [weak self] in
                self?.iconSystem = sys; UserDefaults.standard.set(sys, forKey: "iconSystem")
                self?.evaluate(); self?.refreshNotchExpanded()
            }
            row.addSubview(b)
        }
        return row
    }

    // One compact toggle row: label left, switch right (no description).
    func toggleRowCompact(_ title: String, isOn: Bool, width: CGFloat, onToggle: @escaping (Bool) -> Void) -> NSView {
        let h: CGFloat = 40
        let row = IslandRow(height: h)
        row.frame = NSRect(x: 0, y: 0, width: width, height: h)
        let sw = IslandSwitch(isOn: isOn, brand: brand)
        sw.frame = NSRect(x: width - 12 - IslandSwitch.w, y: (h - IslandSwitch.h) / 2, width: IslandSwitch.w, height: IslandSwitch.h)
        sw.autoresizingMask = [.minXMargin]
        sw.onToggle = onToggle
        row.addSubview(sw)
        let l = islandLabel(title, size: 13, weight: .medium, color: NSColor(srgbRed: 0.949, green: 0.929, blue: 0.894, alpha: 1))
        l.frame = NSRect(x: 12, y: (h - 16) / 2, width: width - 24 - IslandSwitch.w - 8, height: 16)
        row.addSubview(l)
        row.onClick = { [weak sw] in guard let s = sw else { return }; s.isOn.toggle(); onToggle(s.isOn) }
        return row
    }

    // The same visible-session set the dropdown computes (gated desktop sessions + hide-idle), floored
    // at one so the list is never empty while a session is alive.
    func notchVisibleSessions(now: Double) -> [Session] {
        let ordered = sessions.values.sorted { $0.ts > $1.ts }.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
            return s.entrypoint != "claude-desktop" || s.started || !resting
        }
        var visible = ordered.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }
        return visible
    }

    private func islandLabel(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor, mono: Bool = false) -> NSTextField {
        let f = NSTextField(labelWithString: text)
        f.font = mono ? .monospacedDigitSystemFont(ofSize: size, weight: weight) : .systemFont(ofSize: size, weight: weight)
        f.textColor = color
        f.lineBreakMode = .byTruncatingTail
        return f
    }

    func islandSectionHeader(_ title: String, width: CGFloat) -> NSView {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 15))
        let l = NSTextField(labelWithString: "")
        // Design: 10px bold, 1.5px letterspacing, muted warm gray.
        l.attributedStringValue = NSAttributedString(string: title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .kern: 1.5,
            .foregroundColor: NSColor(srgbRed: 0.486, green: 0.463, blue: 0.427, alpha: 1), // #7c766d
        ])
        l.lineBreakMode = .byTruncatingTail
        l.frame = NSRect(x: 6, y: 0, width: width - 12, height: 14)
        l.autoresizingMask = [.width]
        v.addSubview(l)
        return v
    }


    // A design-style session row: state dot (soft ring, blinking while active) + name over a state
    // line, with a live timer and a colored state badge (RUN/THINK/WAIT/DONE/IDLE) on the right.
    func islandSessionRow(_ s: Session, eff: String, width: CGFloat) -> NSView {
        // Compact single line (design): dot · name · status (fills, truncates) · timer.
        let h: CGFloat = 32
        let row = IslandRow(height: h)
        row.frame = NSRect(x: 0, y: 0, width: width, height: h)
        row.layer?.cornerRadius = 9
        let active = (eff == "thinking" || eff == "tool" || eff == "permission")
        let color = islandStateColor(eff, state: s.state)
        if s.id == leadSession?.id { row.layer?.backgroundColor = color.withAlphaComponent(0.1).cgColor }

        // 7px status dot with a soft pulsing glow while active (design: dotGlow).
        let dotD: CGFloat = 7
        let dot = NSView(frame: NSRect(x: 10, y: (h - dotD) / 2, width: dotD, height: dotD))
        dot.wantsLayer = true
        dot.layer?.backgroundColor = color.cgColor
        dot.layer?.cornerRadius = dotD / 2
        if active {
            dot.layer?.shadowColor = color.cgColor
            dot.layer?.shadowRadius = 4
            dot.layer?.shadowOffset = .zero
            let glow = CABasicAnimation(keyPath: "shadowOpacity")
            glow.fromValue = 0.1; glow.toValue = 0.95
            glow.duration = 0.9; glow.autoreverses = true; glow.repeatCount = .infinity
            dot.layer?.add(glow, forKey: "glow")
        }
        row.addSubview(dot)

        // Timer pinned right: turn clock while working, wait clock while a permission sits.
        let now = Date().timeIntervalSince1970
        var timerStr = ""
        if (eff == "thinking" || eff == "tool"), s.startedAt > 0 { timerStr = elapsed(max(0, Int(now - s.startedAt))) }
        else if eff == "permission" { timerStr = elapsed(max(0, Int(now - s.ts))) }
        var rightX = width - 10
        if !timerStr.isEmpty {
            let e = islandLabel(timerStr, size: 11, weight: .medium, color: NSColor(white: 1, alpha: 0.5), mono: true)
            let ew = ceil((timerStr as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)]).width) + 4
            e.frame = NSRect(x: rightX - ew, y: (h - 14) / 2, width: ew, height: 14)
            e.autoresizingMask = [.minXMargin]
            row.addSubview(e)
            rightX -= ew + 8
        }

        // Name (fixed width to its content), then the status line filling the middle, truncating.
        let nameX: CGFloat = 27
        let nameFont = NSFont.systemFont(ofSize: 12.5, weight: .medium)
        let nameW = min(width * 0.5, ceil((sessionName(s) as NSString).size(withAttributes: [.font: nameFont]).width) + 8)
        let name = islandLabel(sessionName(s), size: 12.5, weight: .medium, color: NSColor(srgbRed: 0.949, green: 0.929, blue: 0.894, alpha: 1))
        name.frame = NSRect(x: nameX, y: (h - 15) / 2, width: nameW, height: 15)
        row.addSubview(name)
        let lineX = nameX + nameW + 9
        let line = islandLabel(statusText(s, eff: eff), size: 11, weight: .regular, color: NSColor(srgbRed: 0.486, green: 0.463, blue: 0.427, alpha: 1))
        line.frame = NSRect(x: lineX, y: (h - 14) / 2, width: max(10, rightX - 8 - lineX), height: 14)
        line.autoresizingMask = [.width]
        row.addSubview(line)

        let sid = s.id, ep = s.entrypoint, tp = s.termProgram, tt = s.tty, tx = s.tmux
        row.onClick = { [weak self] in self?.collapseNotch(); self?.openSession(sid, entrypoint: ep, termProgram: tp, tty: tt, tmux: tx) }
        return row
    }

    func islandActionRow(_ title: String, trailing: String, width: CGFloat, action: @escaping () -> Void) -> NSView {
        let h: CGFloat = 28
        let row = IslandRow(height: h)
        row.frame = NSRect(x: 0, y: 0, width: width, height: h)
        let l = islandLabel(title, size: 13, weight: .regular, color: .white)
        l.frame = NSRect(x: 10, y: (h - 16) / 2, width: width - 60, height: 16)
        l.autoresizingMask = [.width]
        row.addSubview(l)
        if !trailing.isEmpty {
            let t = islandLabel(trailing, size: 12, weight: .regular, color: NSColor(white: 1, alpha: 0.4))
            let tw = ceil(t.attributedStringValue.size().width)
            t.frame = NSRect(x: width - 10 - tw, y: (h - 14) / 2, width: tw, height: 14)
            t.autoresizingMask = [.minXMargin]
            row.addSubview(t)
        }
        row.onClick = action
        return row
    }


    @objc func screensChanged() { setupNotch() }

    // The single choke point for the icon image: routes to the notch view or the menu bar button.
    func setSinkImage(_ img: NSImage) {
        if let v = notchView {
            v.iconView.image = img
            v.iconView.contentTintColor = .white   // template frame → white on the black panel
        } else {
            statusItem.button?.contentTintColor = nil
            statusItem.button?.image = img
        }
    }

    // Re-runs on first install AND on every version change, so upgrades pick up hook
    // changes and retire old artifacts.
    func ensureHooksInstalled() {
        let d = UserDefaults.standard
        let current = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? ""
        guard d.string(forKey: "installedVersion") != current,
              let installer = Bundle.main.path(forResource: "install", ofType: "js") else { return }
        DispatchQueue.global().async {
            guard let node = Self.locateNode() else {
                NSLog("ClaudeStatusBar: could not find node; hooks not installed (will retry next launch)")
                return
            }
            let task = Process()
            task.executableURL = URL(fileURLWithPath: node)
            task.arguments = [installer]
            try? task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 { UserDefaults.standard.set(current, forKey: "installedVersion") }
        }
    }

    // `/bin/zsh -lc node` saw only the login PATH, missing nvm/fnm set in .zshrc.
    static func locateNode() -> String? {
        let fm = FileManager.default
        let home = NSHomeDirectory()
        var candidates = [
            "/opt/homebrew/bin/node",
            "/usr/local/bin/node",
            "/usr/bin/node",
            "\(home)/.volta/bin/node",
            "\(home)/.asdf/shims/node",
        ]
        let nvmDir = "\(home)/.nvm/versions/node"
        if let versions = try? fm.contentsOfDirectory(atPath: nvmDir) {
            for v in versions.sorted(by: >) { candidates.append("\(nvmDir)/\(v)/bin/node") }
        }
        for path in candidates where fm.isExecutableFile(atPath: path) { return path }

        for args in [["-ilc", "command -v node"], ["-lc", "command -v node"]] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/zsh")
            p.arguments = args
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            p.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = (String(data: data, encoding: .utf8) ?? "")
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            if !path.isEmpty, fm.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    // MARK: update check

    var currentVersion: String { (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0" }
    let releaseAPIURL = "https://api.github.com/repos/m1ckc3s/claude-status-bar/releases/latest"
    let releasePageURL = "https://github.com/m1ckc3s/claude-status-bar/releases/latest"

    // Once/day: cache GitHub's latest release tag in UserDefaults. Nothing sent to us.
    func checkForUpdate() {
        let d = UserDefaults.standard
        let now = Date().timeIntervalSince1970
        if now - d.double(forKey: "lastUpdateCheck") < 86400 { return }
        guard let url = URL(string: releaseAPIURL) else { return }
        var req = URLRequest(url: url)
        req.setValue("ClaudeStatusBar", forHTTPHeaderField: "User-Agent") // GitHub API requires a UA
        URLSession.shared.dataTask(with: req) { data, _, _ in
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = obj["tag_name"] as? String else { return }
            let ver = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
            UserDefaults.standard.set(ver, forKey: "latestVersion")
            UserDefaults.standard.set(now, forKey: "lastUpdateCheck")
        }.resume()
    }

    // Numeric component-wise compare so "0.0.10" > "0.0.9".
    func versionIsNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    @objc func openLatestRelease() {
        if let url = URL(string: releasePageURL) { NSWorkspace.shared.open(url) }
    }

    // MARK: menu

    // The poll timer runs in .common mode, so it keeps firing while the menu tracks; we use that
    // to live-update the per-session elapsed clocks. menuNeedsUpdate rebuilds the rows on each open.
    func menuWillOpen(_ menu: NSMenu) {
        menuIsOpen = true
    }
    func menuDidClose(_ menu: NSMenu) {
        menuIsOpen = false
        sessionMenuItems.removeAll()
        agentMenuItems.removeAll()
        agentOverflowItems.removeAll()
    }

    // The session SET only changes on reopen (NSMenu can't add/remove rows reliably mid-track).
    func refreshOpenMenuRows() {
        let now = Date().timeIntervalSince1970
        for (item, id) in sessionMenuItems {
            guard let s = sessions[id], let v = item.view as? SessionRowView else { continue }
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            configureSessionRow(v, s, eff: eff)
        }
        // Agent rows: live rows tick their timers; a row whose agent finished (or whose whole turn
        // ended) greys out in place — the set can't shrink mid-track, the next open drops it.
        for (item, sid, aid) in agentMenuItems {
            guard let v = item.view as? AgentRowView else { continue }
            if let s = sessions[sid], let a = visibleAgents(for: s).first(where: { $0.id == aid }) {
                configureAgentRow(v, a, now: now)
            } else {
                v.markFinished(dot: agentDot(done: true))
            }
        }
        for (item, sid) in agentOverflowItems {
            // The overflow line stays put; only its count can change (agents that finish while the
            // menu is open shrink it, floored at the rows we can't remove).
            guard let v = item.view?.subviews.first as? NSTextField else { continue }
            let live = sessions[sid].map { visibleAgents(for: $0).count } ?? 0
            let hidden = max(0, live - agentMenuItems.filter { $0.sessionId == sid }.count)
            v.stringValue = hidden > 0 ? "+ \(hidden) more" : ""
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        checkForUpdate() // refreshes the update cache for next open (gated to once a day)

        // Branches otherwise refresh only on hook events, so re-read on open (one tiny file read per
        // session) to catch a checkout made while a session sat idle.
        for (id, s) in sessions where !s.cwd.isEmpty {
            if gitHeadCache[s.cwd] == "" { gitHeadCache[s.cwd] = nil }  // recheck non-git: may have been git-init'd since
            var u = s; u.branch = branchForCwd(u.cwd); sessions[id] = u
        }

        sessionMenuItems.removeAll()
        agentMenuItems.removeAll()
        agentOverflowItems.removeAll()
        let now = Date().timeIntervalSince1970
        // Gate ONLY the desktop app: opening/clicking a conversation there seeds an idle session without
        // real activity (the click-through clutter), so a desktop session stays out of the dropdown until
        // a prompt/tool fires (started=true). CLI / terminal / editor sessions are launched deliberately,
        // so they surface the moment they start. Any active state counts as started too (and covers
        // pre-upgrade files with no flag).
        let allOrdered = sessions.values.sorted { $0.ts > $1.ts }   // most-recent first
        let ordered = allOrdered.filter { s in
                let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
                let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
                let gated = s.entrypoint == "claude-desktop"   // only the desktop app is gated
                return !gated || s.started || !resting
            }
        // Hide rows idle past the threshold, but ALWAYS keep the most-recent started session (floor at
        // one) so the dropdown never goes empty while a session is alive. Hiding is render-only; the file
        // (and thus liveness) is untouched — see stalePruneAge and the pid-driven reap in evaluate().
        var visible = ordered.filter { s in
            let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
            let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")
            // Background subagents keep working after the parent's turn ends, without bumping the
            // session's ts — a session with live agents is active, not stale, so don't hide it.
            if resting && !visibleAgents(for: s).isEmpty { return true }
            return !(stalePruneAge > 0 && resting && now - s.ts > stalePruneAge)
        }
        if visible.isEmpty, let lead = ordered.first { visible = [lead] }   // floor: never empty while alive

        if !visible.isEmpty {
            menu.addItem(header("Sessions"))
            for s in visible {
                let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff
                let view = SessionRowView(id: s.id, width: CGFloat(uiConfig()["boxWidth"] ?? 300))
                let sid = s.id, ep = s.entrypoint, tp = s.termProgram, tt = s.tty, tx = s.tmux
                view.onClick = { [weak self] in menu.cancelTracking(); self?.openSession(sid, entrypoint: ep, termProgram: tp, tty: tt, tmux: tx) }
                configureSessionRow(view, s, eff: eff)
                let it = NSMenuItem()
                it.view = view
                menu.addItem(it)
                sessionMenuItems.append((it, s.id))  // kept so tick() can live-update the timers

                // Running subagents, indented under their session. Capped so a big fan-out can't
                // swallow the menu; agents that START while the menu is open appear on next open
                // (rows can't be added mid-track), which mirrors how session rows behave.
                let agents = visibleAgents(for: s)
                let cfg = uiConfig()
                let cap = max(1, Int(cfg["agentRowsMax"] ?? 4))
                for a in agents.prefix(cap) {
                    let av = AgentRowView(sessionId: s.id, agentId: a.id,
                                          width: CGFloat(cfg["boxWidth"] ?? 300),
                                          rowH: CGFloat(cfg["agentRowH"] ?? 20),
                                          indent: CGFloat(cfg["agentIndent"] ?? 18))
                    configureAgentRow(av, a, now: now)
                    let ai = NSMenuItem()
                    ai.view = av
                    menu.addItem(ai)
                    agentMenuItems.append((ai, s.id, a.id))
                }
                if agents.count > cap {
                    let oi = NSMenuItem()
                    oi.view = agentOverflowView(count: agents.count - cap, cfg: cfg)
                    menu.addItem(oi)
                    agentOverflowItems.append((oi, s.id))
                }
            }
            menu.addItem(.separator())
        } else if claudeDesktopRunning() {
            // No live session to pin, but the desktop app is up — give a way to jump back in.
            menu.addItem(header("Sessions"))
            let open = NSMenuItem(title: "Open Claude", action: #selector(openClaude), keyEquivalent: "")
            open.target = self
            menu.addItem(open)
            menu.addItem(.separator())
        }

        menu.addItem(header("Options"))
        menu.addItem(toggleRow(title: "Show timer", isOn: showTimer) { [weak self] on in
            self?.showTimer = on
            UserDefaults.standard.set(on, forKey: "showTimer")
            self?.applyTitle()
        })
        menu.addItem(toggleRow(title: "Thinking words", isOn: useThinkingWords) { [weak self] on in
            self?.useThinkingWords = on
            UserDefaults.standard.set(on, forKey: "thinkingWords")
            self?.evaluate()   // re-render the bar label immediately with/without the rotating word
        })
        // Only meaningful on a Mac that has a notch (persisted, so it still shows when docked clamshell).
        if UserDefaults.standard.bool(forKey: "machineHasNotch") || NotchGeometry.machineHasNotch() {
            menu.addItem(toggleRow(title: "Show at notch", isOn: showAtNotch) { [weak self] on in
                self?.showAtNotch = on
                UserDefaults.standard.set(on, forKey: "showAtNotch")
                self?.setupNotch()   // build or tear down the notch window; flips the status item
            })
        }
        // Experimental: iTerm exact-tab focus + Allow/Deny keystroke on permission prompts (one-time
        // Automation grant). tmux Allow/Deny works without this toggle (no grant needed).
        menu.addItem(toggleRow(title: "Exact terminal focus", qualifier: "experimental", isOn: exactTerminalFocus) { [weak self] on in
            self?.setExactTerminalFocus(on)
        })

        let animParent = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
        let animSub = NSMenu()
        for (style, name) in [(AnimStyle.web, "Claude Spark"), (AnimStyle.code, "Claude Code"), (AnimStyle.crab, "Crab Walking")] {
            let it = NSMenuItem(title: name, action: #selector(chooseStyle(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = style.rawValue
            it.state = animStyle == style ? .on : .off
            animSub.addItem(it)
        }
        animParent.submenu = animSub
        menu.addItem(animParent)

        let colorParent = NSMenuItem(title: "Color", action: nil, keyEquivalent: "")
        let colorSub = NSMenu()
        for (sys, name) in [(false, "Orange"), (true, "System")] {
            let it = NSMenuItem(title: name, action: #selector(chooseColor(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = sys
            it.state = iconSystem == sys ? .on : .off
            colorSub.addItem(it)
        }
        colorParent.submenu = colorSub
        menu.addItem(colorParent)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Version \(currentVersion)", action: nil, keyEquivalent: ""))
        if let latest = UserDefaults.standard.string(forKey: "latestVersion"), versionIsNewer(latest, than: currentVersion) {
            let up = NSMenuItem(title: "Update available", action: #selector(openLatestRelease), keyEquivalent: "")
            up.target = self
            menu.addItem(up)
        }
        let q = NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q")
        q.target = self
        menu.addItem(q)
    }

    func header(_ title: String) -> NSMenuItem {
        if #available(macOS 14.0, *) { return NSMenuItem.sectionHeader(title: title) }
        let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    func toggleRow(title: String, qualifier: String? = nil, isOn: Bool, onToggle: @escaping (Bool) -> Void) -> NSMenuItem {
        let width = CGFloat(uiConfig()["boxWidth"] ?? 300), height: CGFloat = 24, leftInset: CGFloat = 14, rightInset: CGFloat = 12
        let row = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        row.autoresizingMask = [.width]

        let labelFont = NSFont.menuFont(ofSize: 0)
        let label = NSTextField(labelWithString: title)
        label.font = labelFont
        label.textColor = .labelColor
        label.sizeToFit()
        label.setFrameOrigin(NSPoint(x: leftInset, y: (height - label.frame.height) / 2))
        label.autoresizingMask = [.maxXMargin]
        row.addSubview(label)

        let toggle = ToggleView(isOn: isOn)
        toggle.onToggle = onToggle
        let toggleX = width - toggle.frame.width - rightInset
        toggle.setFrameOrigin(NSPoint(x: toggleX, y: (height - toggle.frame.height) / 2))
        toggle.autoresizingMask = [.minXMargin]
        row.addSubview(toggle)

        // Optional trailing qualifier ("5 min+") pinned just left of the toggle, in the SAME font/size/color
        // and right-alignment as the session-row timer, so the two read as the same kind of trailing note.
        if let qualifier = qualifier {
            let qW: CGFloat = 74, gap: CGFloat = 8
            let q = NSTextField(labelWithString: qualifier)
            q.font = NSFont.monospacedSystemFont(ofSize: labelFont.pointSize - 2, weight: .regular)
            q.textColor = .secondaryLabelColor
            q.alignment = .right
            q.frame = NSRect(x: toggleX - gap - qW, y: (height - 16) / 2, width: qW, height: 16)
            q.autoresizingMask = [.minXMargin]
            row.addSubview(q)
        }

        let item = NSMenuItem()
        item.view = row
        return item
    }

    func sessionMenuLine(_ s: Session) -> String {
        let now = Date().timeIntervalSince1970
        let eff = s.eff.isEmpty ? effectiveState(s, now: now) : s.eff  // cached by evaluate() each tick
        // The icon carries the state (spinner / amber dot / caret); the row text is just the project,
        // plus a live timer while working since the spinner can't convey elapsed.
        var line = truncated(sessionName(s))
        if !s.branch.isEmpty { line += " · " + truncated(s.branch, max: 22, keep: 20) }
        if eff == "thinking" || eff == "tool", s.startedAt > 0 {
            line += "  " + elapsed(max(0, Int(now - s.startedAt)))
        }
        return line
    }

    // Live layout knobs read fresh from ~/.claude/statusbar/uiconfig.json each render, so numeric
    // tweaks (timer column, pill offset, gap) take effect on the next menu open with NO rebuild.
    func uiConfig() -> [String: Double] {
        let p = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/statusbar/uiconfig.json")
        guard let d = FileManager.default.contents(atPath: p),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j.compactMapValues { ($0 as? NSNumber)?.doubleValue }
    }

    func configureSessionRow(_ v: SessionRowView, _ s: Session, eff: String) {
        let cfg = uiConfig()
        let now = Date().timeIntervalSince1970
        // Generous cap: the row's pixel truncation does the real limiting now that the name field
        // sizes to the free space; this only guards against pathological strings.
        let nameMax = Int(cfg["nameMax"] ?? 30)
        let working = (eff == "thinking" || eff == "tool") && s.startedAt > 0
        let resting = !(eff == "permission" || eff == "thinking" || eff == "tool")  // the dim caret
        let tag = surfaceTag(s.entrypoint)
        v.configure(icon: sessionSymbol(s, eff: eff),
                    iconTint: resting ? .tertiaryLabelColor : .labelColor,  // caret dim; spinner matches the name font; amber image ignores tint
                    spinning: (eff == "thinking" || eff == "tool"),
                    name: truncated(sessionName(s), max: nameMax, keep: nameMax),
                    branch: truncated(s.branch, max: 22, keep: 20),
                    timer: working ? elapsed(max(0, Int(now - s.startedAt))) : nil,
                    pillNormal: tag.isEmpty ? nil : pillImage(tag),
                    pillSelected: tag.isEmpty ? nil : pillImage(tag, selected: true),
                    pillInset: CGFloat(cfg["pillInset"] ?? 12),
                    timerGap: CGFloat(cfg["timerGap"] ?? 10))
        // Truncated rows stay inspectable: full name, branch, and path on hover.
        var tip = sessionName(s)
        if !s.branch.isEmpty { tip += " · " + s.branch }
        if !s.cwd.isEmpty { tip += "\n" + s.cwd }
        v.toolTip = tip
    }

    func configureAgentRow(_ v: AgentRowView, _ a: AgentInfo, now: Double) {
        let cfg = uiConfig()
        v.configure(dot: agentDot(done: false),
                    agentType: a.agentType.isEmpty ? "agent" : a.agentType,
                    task: truncated(a.task, max: 60, keep: 58),
                    timer: elapsed(max(0, Int(now - a.startedAt))),
                    rightInset: CGFloat(cfg["pillInset"] ?? 12),
                    timerGap: CGFloat(cfg["timerGap"] ?? 10))
        v.toolTip = a.task.isEmpty ? a.agentType : a.task   // the full (untruncated) delegation prompt
    }

    // Claude Code-style task dot: dim grey while an agent runs, green once it's done.
    func agentDot(done: Bool) -> NSImage? {
        guard let img = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil) else { return nil }
        let tint: NSColor = done ? .systemGreen : .tertiaryLabelColor
        let size = CGFloat(uiConfig()["agentDotSize"] ?? 7)
        return img.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
                .applying(NSImage.SymbolConfiguration(paletteColors: [tint])))
    }

    // Dim "+ k more" line when a fan-out exceeds agentRowsMax; indented like the agent rows.
    func agentOverflowView(count: Int, cfg: [String: Double]) -> NSView {
        let tf = NSTextField(labelWithString: "+ \(count) more")
        tf.font = NSFont.menuFont(ofSize: NSFont.menuFont(ofSize: 0).pointSize - 2)
        tf.textColor = .tertiaryLabelColor
        let indent = CGFloat(cfg["agentIndent"] ?? 18)
        tf.frame = NSRect(x: 14 + indent + 16 + 6, y: 1, width: 160, height: 16)
        let wrap = NSView(frame: NSRect(x: 0, y: 0, width: CGFloat(cfg["boxWidth"] ?? 300), height: 18))
        wrap.autoresizingMask = [.width]
        wrap.addSubview(tf)
        return wrap
    }

    // Subagents run in the BACKGROUND: they outlive the parent's turn (Stop fires seconds after
    // the spawn), so a row lives exactly as long as its file — SubagentStart to SubagentStop —
    // regardless of what the parent is doing. The session's own liveness (pid reap) bounds them,
    // plus an age cap as the belt for a crash that never fires SubagentStop: session restarts
    // clear the dir, but a long-lived idle session shouldn't show a dead agent forever.
    func visibleAgents(for s: Session) -> [AgentInfo] {
        let cap = uiConfig()["agentMaxAge"] ?? 7200   // same order as the permission cap
        let now = Date().timeIntervalSince1970
        return (sessionAgents[s.id] ?? []).filter { now - $0.startedAt < cap }
    }

    func statusText(_ s: Session, eff: String) -> String {
        switch eff {
        case "permission":       return "Awaiting permission"
        case "thinking", "tool": return workingLabel(s)
        default:                 return s.state == "done" ? "Done" : "Idle"
        }
    }

    // Just the repo/cwd (parent-qualified on a name collision); the surface (CLI/APP) renders as a
    // trailing badge instead of inline.
    func sessionName(_ s: Session) -> String {
        if !s.displayName.isEmpty { return s.displayName }
        return s.project.isEmpty ? "session" : s.project
    }

    // CLAUDE_CODE_ENTRYPOINT -> a short all-caps badge tag.
    // Every surface collapses to a 3-letter pill: the desktop app is APP, everything else (cli,
    // vscode, cursor, windsurf, …) is a terminal/editor context, so CLI. Keeps pills uniform.
    func surfaceTag(_ entrypoint: String) -> String {
        switch entrypoint {
        case "claude-desktop": return "APP"
        case "":               return ""
        default:               return "CLI"
        }
    }

    // CLI/APP pill rendered as an image so it can sit inside the row text (right after the timer)
    // rather than as a system badge pinned to the menu edge with a fixed, uncloseable gap.
    func pillImage(_ text: String, selected: Bool = false) -> NSImage {
        let t = text as NSString
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .semibold)  // mono -> 3 chars = uniform width
        let pad: CGFloat = 7, h: CGFloat = 15
        let cfg = uiConfig()
        let dy = CGFloat(cfg["pillTextY"] ?? -1)  // negative nudges the text down (it reads top-heavy)
        // Pill bg is a tunable gray per mode (black-on-light / white-on-dark at a low alpha) so light
        // mode can be lightened independently. On a selected (blue) row it's a light translucent pill.
        let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let bgAlpha = CGFloat(cfg[dark ? "pillBgDark" : "pillBgLight"] ?? (dark ? 0.14 : 0.10))
        let bg = selected ? NSColor.white.withAlphaComponent(0.22)
                          : (dark ? NSColor.white : NSColor.black).withAlphaComponent(bgAlpha)
        let fg = selected ? NSColor.white : NSColor.labelColor
        let w = ceil(t.size(withAttributes: [.font: font]).width) + pad * 2
        return NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            bg.setFill()
            NSBezierPath(roundedRect: rect, xRadius: h / 2, yRadius: h / 2).fill()
            let a: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg]
            let ts = t.size(withAttributes: a)
            t.draw(at: NSPoint(x: (rect.width - ts.width) / 2, y: (rect.height - ts.height) / 2 + dy), withAttributes: a)
            return true
        }
    }

    func sessionSymbol(_ s: Session, eff: String) -> NSImage? {
        switch eff {
        case "permission":       return symbolImage("exclamationmark.circle.fill", tint: amber)
        case "thinking", "tool": return nil
        default:                 return restingCaret   // done/idle merged: dim "ready for input" caret
        }
    }

    // The shell-style prompt caret (U+276F, what Claude Code shows when idle), dimmed and centered in
    // a square that matches the spinner gutter so the resting rows align with the working ones.
    lazy var restingCaret: NSImage? = {
        let glyph = "\u{276F}" as NSString
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let side: CGFloat = 15
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
            let g = glyph.size(withAttributes: attrs)
            glyph.draw(at: NSPoint(x: (side - g.width) / 2, y: (side - g.height) / 2), withAttributes: attrs)
            return true
        }
        img.isTemplate = true   // tint via contentTintColor: dim (tertiary) normally, white on hover
        return img
    }()

    func symbolImage(_ name: String, tint: NSColor? = nil) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        if let tint = tint, #available(macOS 12.0, *) {
            return img.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [tint]))
        }
        img.isTemplate = true
        return img
    }

    // Keep the bar narrow: over `max` chars, show the first `keep` + an ellipsis (full text stays in the tooltip).
    func truncated(_ s: String, max: Int = 20, keep: Int = 18) -> String {
        s.count > max ? String(s.prefix(keep)) + "…" : s
    }

    // Rank a session's EFFECTIVE state for surfacing (higher = more important), so a session
    // awaiting YOUR permission is never hidden behind one merely thinking. `eff` only ever yields
    // permission / thinking / tool / idle (done collapses to idle; waiting is never emitted).
    func priority(of eff: String) -> Int {
        switch eff {
        case "permission":       return 2
        case "thinking", "tool": return 1
        default:                 return 0   // idle / unknown
        }
    }

    func workingLabel(_ s: Session) -> String {
        if useThinkingWords, s.state == "thinking", let w = sessionWord[s.id], !w.isEmpty { return w + "…" }
        if !s.label.isEmpty { return s.label }
        return s.state == "tool" ? "Working…" : "Thinking…"
    }

    // Re-pick a word each time a session ENTERS the thinking state (prompt, or a tool->thinking `post`),
    // avoiding an immediate repeat, so a tool round-trip lands a different word. Held steady while the
    // session stays thinking. Computed regardless of the toggle so flipping it on shows instantly.
    func updateThinkingWord(_ s: Session) {
        let prev = prevState[s.id] ?? ""
        guard s.state == "thinking", prev != "thinking" else { return }
        var w = thinkingWords.randomElement() ?? "Thinking"
        if thinkingWords.count > 1 { while w == sessionWord[s.id] { w = thinkingWords.randomElement() ?? w } }
        sessionWord[s.id] = w
    }

    // "1m 1s" / "43s" — Claude Code's elapsed-clock style.
    func elapsed(_ secs: Int) -> String {
        let m = secs / 60, s = secs % 60
        return m > 0 ? "\(m)m \(s)s" : "\(s)s"
    }

    @objc func quit() { NSApp.terminate(nil) }

    @objc func openClaude() {
        let ws = NSWorkspace.shared
        if let url = ws.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            ws.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        }
    }

    // Row click. Desktop session: focus the Claude app. Do NOT use claude://resume?session=<id>,
    // that calls importCliSession() and spawns a duplicate "ungrouped" session record
    // (local_<random>.json with cliSessionId=<id>) every click, it's an import verb, not focus.
    // The clean focus path (claude://code/<bridgeSessionId>) needs an opaque session_/cse_ bridge
    // id the app never exposes to us (not in env, not derivable from the UUID, undefined on disk).
    // CLI session: bring its terminal APP to the front (zero permission). Exact window/tab focus
    // (tmux pane or iTerm tab by tty) is layered on for the permission Allow/Deny buttons below.
    func openSession(_ id: String, entrypoint: String, termProgram: String, tty: String, tmux: Bool) {
        if entrypoint == "claude-desktop" { openClaude(); return }
        // tmux session: select the pane so the click lands you on the exact prompt. iTerm tab focus
        // (the pane's host window) is best-effort on top.
        if tmux, !tty.isEmpty { _ = focusTmuxPane(tty: tty) }
        bringTerminalAppToFront(termProgram)
    }

    // Map TERM_PROGRAM to a name `open -a` understands; most terminals match verbatim.
    func terminalAppName(_ termProgram: String) -> String? {
        switch termProgram {
        case "Apple_Terminal": return "Terminal"
        case "iTerm.app":      return "iTerm"
        case "vscode":         return "Visual Studio Code"
        case "WarpTerminal":   return "Warp"
        case "":               return nil  // unknown surface
        default:               return termProgram  // Ghostty, WezTerm, Tabby, Hyper, kitty, …
        }
    }

    // Bring the terminal app to the front (no permission).
    func bringTerminalAppToFront(_ termProgram: String) {
        guard let app = terminalAppName(termProgram) else { return }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        p.arguments = ["-a", app]
        try? p.run()
    }

    // MARK: permission Allow/Deny keystroke
    //
    // A permission prompt sits in the session's own terminal. We answer it by delivering a keystroke
    // to the exact pane/tab that owns the session's tty — never a blind send. Two backends:
    //   • tmux   → `tmux send-keys -t <pane>` to the pane whose #{pane_tty} matches (no macOS grant).
    //   • iTerm  → AppleScript: focus the tab whose tty matches, then System Events keystroke
    //              (needs the one-time Automation grant, gated behind the experimental toggle).
    // The dispatcher only fires when a supported backend can target the exact session; anything else
    // returns .unsupported and the UI hides the buttons, so we never type into the wrong place.

    enum PermAnswer { case allow, deny }
    enum KeyOutcome { case sent, denied, unsupported }

    // True when we can deliver a keystroke to this session's prompt (drives button visibility).
    //   • tmux       → exact pane by tty. Always safe, no grant.               (needs tty)
    //   • iTerm.app  → exact tab by tty via AppleScript.                        (needs tty + grant)
    //   • vscode     → focus VS Code + BLIND keystroke to the focused terminal. (grant, NO exact
    //                  targeting — VS Code can't be addressed by tty, so this types into whatever
    //                  terminal tab is frontmost. Gated behind the toggle so it's opt-in.)
    func canSendPermissionKey(_ s: Session) -> Bool {
        guard s.entrypoint != "claude-desktop" else { return false }
        if s.tmux, !s.tty.isEmpty { return true }                        // tmux: exact, no grant
        if s.termProgram == "iTerm.app", !s.tty.isEmpty { return exactTerminalFocus }  // iTerm: exact + grant
        if s.termProgram == "vscode" || s.entrypoint == "claude-vscode" { return exactTerminalFocus } // vscode: blind + grant
        return false
    }

    // Debug log for the permission keystroke flow (per the "log the flow" workflow). Always on for
    // now while we validate; writes to ~/.claude/statusbar/perm.log.
    func permDbg(_ msg: String) {
        let line = "\(Date()) \(msg)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/statusbar/perm.log")
        if let data = line.data(using: .utf8) {
            if let fh = try? FileHandle(forWritingTo: url) {
                fh.seekToEndOfFile(); fh.write(data); try? fh.close()
            } else {
                try? data.write(to: url)
            }
        }
    }

    func sendPermissionKey(_ s: Session, _ answer: PermAnswer) -> KeyOutcome {
        permDbg("sendPermissionKey answer=\(answer) tmux=\(s.tmux) tty=\(s.tty) term=\(s.termProgram) entry=\(s.entrypoint)")
        guard s.entrypoint != "claude-desktop" else { permDbg("  -> desktop (.unsupported)"); return .unsupported }
        if s.tmux, !s.tty.isEmpty { return sendTmuxKey(tty: s.tty, answer: answer) }
        if s.termProgram == "iTerm.app", !s.tty.isEmpty, exactTerminalFocus {
            return sendITermKey(tty: s.tty, answer: answer)
        }
        if s.termProgram == "vscode" || s.entrypoint == "claude-vscode", exactTerminalFocus {
            return sendVSCodeKey(answer: answer)
        }
        return .unsupported
    }

    // Is this app trusted for Accessibility (required to post System Events keystrokes)? `prompt:true`
    // shows the system "grant Accessibility" dialog + adds the app to the list once.
    func hasAccessibility(prompt: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: prompt] as CFDictionary)
    }

    // VS Code integrated terminal: no way to address a specific tab by tty (VS Code exposes no such
    // AppleScript), so we bring VS Code to the front and BLIND-send the key to whatever terminal is
    // focused. Correct only when the session's terminal is the frontmost one — hence gated behind the
    // toggle and clearly labeled experimental. System Events keystrokes need the Accessibility grant.
    // Allow = "y", Deny = Escape.
    func sendVSCodeKey(answer: PermAnswer) -> KeyOutcome {
        guard hasAccessibility(prompt: true) else {
            permDbg("  sendVSCodeKey: no Accessibility grant → prompted, aborting this click")
            return .denied   // caller flips the toggle off; user grants then re-enables
        }
        let keystroke = answer == .allow ? "keystroke \"y\"" : "key code 53"  // 53 = Escape
        let script = """
        tell application "Visual Studio Code" to activate
        delay 0.15
        tell application "System Events" to \(keystroke)
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if let err = err {
            let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
            permDbg("  sendVSCodeKey error \(code): \(err)")
            return code == -1743 ? .denied : .unsupported
        }
        permDbg("  sendVSCodeKey: sent \(answer) (blind, to focused VS Code terminal)")
        return .sent
    }

    // Resolve a tty to its tmux pane id (%N) by matching #{pane_tty}. "" if not found / no server.
    func tmuxPaneID(forTTY tty: String) -> String? {
        let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        guard let bin = tmuxBin else { permDbg("  tmuxPaneID: no tmux binary found"); return nil }
        let out = runCapture(bin, ["list-panes", "-a", "-F", "#{pane_id} #{pane_tty}"])
        permDbg("  tmuxPaneID: bin=\(bin) dev=\(dev) list-panes out=\(out ?? "<nil>")")
        guard let out = out else { return nil }
        for line in out.split(separator: "\n") {
            let cols = line.split(separator: " ", maxSplits: 1)
            if cols.count == 2, cols[1] == Substring(dev) { permDbg("  tmuxPaneID: matched \(cols[0])"); return String(cols[0]) }
        }
        permDbg("  tmuxPaneID: no pane matched dev=\(dev)")
        return nil
    }

    // Path to the tmux binary (Homebrew arm64 / Intel / system), or nil if tmux isn't installed.
    var tmuxBin: String? {
        for p in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    // Select the pane owning this tty (so a click lands on the exact prompt). Returns false if unfound.
    @discardableResult
    func focusTmuxPane(tty: String) -> Bool {
        guard let bin = tmuxBin, let pane = tmuxPaneID(forTTY: tty) else { return false }
        // select-window then select-pane so the right window is shown AND the right pane is active.
        _ = runCapture(bin, ["select-window", "-t", pane])
        _ = runCapture(bin, ["select-pane", "-t", pane])
        return true
    }

    // Deliver the answer keystroke into the tmux pane. Allow = Enter (accepts the highlighted
    // "Yes" default of the permission prompt); Deny = Escape. send-keys addresses the pane by id,
    // so it lands regardless of which tmux window is currently shown.
    func sendTmuxKey(tty: String, answer: PermAnswer) -> KeyOutcome {
        guard let bin = tmuxBin, let pane = tmuxPaneID(forTTY: tty) else { permDbg("  sendTmuxKey: no bin/pane -> .unsupported"); return .unsupported }
        _ = runCapture(bin, ["select-window", "-t", pane])
        _ = runCapture(bin, ["select-pane", "-t", pane])
        let key = answer == .allow ? "Enter" : "Escape"
        let r = runCapture(bin, ["send-keys", "-t", pane, key])
        permDbg("  sendTmuxKey: sent \(key) to \(pane), send-keys out=\(r ?? "<nil>")")
        return .sent
    }

    // iTerm: address the session by tty and write the answer straight into it with iTerm's native
    // `write text` — NO System Events, so this needs only the Automation grant (apple-events), not
    // the heavier Accessibility grant. The prompt's TUI reads the injected bytes as keystrokes.
    // Allow = "y", Deny = the Escape byte (). `newline no` so we send just the char, no Enter.
    func sendITermKey(tty: String, answer: PermAnswer) -> KeyOutcome {
        let dev = tty.hasPrefix("/dev/") ? tty : "/dev/\(tty)"
        // AppleScript string literal for the char: "y", or the ESC control char via `character id 27`.
        let textExpr = answer == .allow ? "\"y\"" : "(character id 27)"
        let script = """
        tell application "iTerm"
          activate
          repeat with w in windows
            repeat with t in tabs of w
              repeat with s in sessions of t
                if tty of s is "\(dev)" then
                  select s
                  select t
                  tell w to select
                  tell s to write text \(textExpr) newline no
                  return
                end if
              end repeat
            end repeat
          end repeat
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        guard let err = err else { permDbg("  sendITermKey: wrote \(answer) to \(dev)"); return .sent }
        let code = (err["NSAppleScriptErrorNumber"] as? Int) ?? 0
        permDbg("  sendITermKey error \(code): \(err)")
        return code == -1743 ? .denied : .unsupported   // -1743 = errAEEventNotPermitted (grant declined)
    }

    // Run a command, capture stdout (trimmed). nil on launch failure. Used for tmux queries/sends.
    @discardableResult
    func runCapture(_ path: String, _ args: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { permDbg("  runCapture: not executable \(path)"); return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe(), errPipe = Pipe()
        p.standardOutput = pipe
        p.standardError = errPipe
        do { try p.run() } catch { permDbg("  runCapture: launch failed \(path) \(args): \(error)"); return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if !errData.isEmpty, let e = String(data: errData, encoding: .utf8) {
            permDbg("  runCapture stderr[\(args.first ?? "")]: \(e.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // Persist the experimental toggle. Explain the macOS Automation grant on the first enable, or again
    // after a denial (the deny handler clears exactFocusToastShown). Deferred so the menu's toggle
    // interaction finishes before the modal alert. Only gates the iTerm AppleScript path — tmux
    // send-keys works without any grant, so tmux Allow/Deny buttons show regardless of this toggle.
    func setExactTerminalFocus(_ on: Bool) {
        exactTerminalFocus = on
        UserDefaults.standard.set(on, forKey: "exactTerminalFocus")
        guard on, !UserDefaults.standard.bool(forKey: "exactFocusToastShown") else { return }
        UserDefaults.standard.set(true, forKey: "exactFocusToastShown")
        DispatchQueue.main.async { [weak self] in self?.showExactFocusToast() }
    }

    // Clear this app's Apple Events automation decisions so the next AppleScript attempt re-triggers the
    // macOS prompt (lets a re-enable recover from an earlier denial). tccutil edits the user TCC db, no sudo.
    func resetAutomationGrant() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        p.arguments = ["reset", "AppleEvents", Bundle.main.bundleIdentifier ?? "com.local.claudestatusbar"]
        try? p.run()
    }

    func showExactFocusToast() {
        let a = NSAlert()
        a.messageText = "Exact terminal focus (experimental)"
        a.informativeText = "When enabled, clicking a CLI session focuses its exact terminal tab, and the Allow/Deny buttons on a permission prompt answer it in the session.\n\nHeads up: for iTerm this needs a one-time prompt from Apple to control it. You can revoke it any time under System Settings > Privacy & Security > Automation. (tmux sessions work without any prompt.)"
        a.addButton(withTitle: "Got it")
        a.addButton(withTitle: "Learn more")
        NSApp.activate(ignoringOtherApps: true)
        if a.runModal() == .alertSecondButtonReturn,
           let url = URL(string: "https://github.com/m1ckc3s/claude-status-bar/issues/19") {
            NSWorkspace.shared.open(url)
        }
    }

    // iTerm grant declined → flip the toggle back off and reset the grant so a re-enable re-prompts.
    func handleGrantDenied() {
        setExactTerminalFocus(false)
        UserDefaults.standard.set(false, forKey: "exactFocusToastShown")
        resetAutomationGrant()
    }


    @objc func chooseColor(_ sender: NSMenuItem) {
        guard let sys = sender.representedObject as? Bool else { return }
        iconSystem = sys
        UserDefaults.standard.set(iconSystem, forKey: "iconSystem")
        evaluate() // re-render the current state in the new color
    }

    @objc func chooseStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let st = AnimStyle(rawValue: raw) else { return }
        animStyle = st
        UserDefaults.standard.set(raw, forKey: "animStyle")
        animTimer?.invalidate(); animTimer = nil // recreate at the new style's fps
        frameIdx = 0
        evaluate()
    }

    // MARK: state polling

    func tick() {
        checkLifecycle()
        updateActiveNotchScreen()   // follow the cursor across displays
        reloadSessions()
        reloadAgents()
        evaluate()
        if menuIsOpen { refreshOpenMenuRows() }
    }

    // The .json session files currently in state.d/ (ignores the .tmp files mid-write).
    func stateFileNames() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: stateDir)) ?? []).filter { $0.hasSuffix(".json") }
    }

    // Refresh `sessions` from state.d/, re-parsing only files whose mtime changed (writes are
    // atomic renames, so a content update bumps mtime and is never read torn).
    func reloadSessions() {
        let fm = FileManager.default
        let files = stateFileNames()
        let present = Set(files)
        for key in Array(fileMTimes.keys) where !present.contains(key) {
            fileMTimes[key] = nil
            sessions[(key as NSString).deletingPathExtension] = nil
        }
        for f in files {
            let full = (stateDir as NSString).appendingPathComponent(f)
            guard let attrs = try? fm.attributesOfItem(atPath: full),
                  let m = attrs[.modificationDate] as? Date else { continue }
            if fileMTimes[f] == m { continue }
            fileMTimes[f] = m
            guard let data = fm.contents(atPath: full),
                  let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            let id = (f as NSString).deletingPathExtension
            var s = Session(json: o, id: id)
            // A hook event means activity in that cwd, which may have JUST become a repo (git init /
            // first branch mid-session) — a cached "" (non-git) would otherwise stick until app restart.
            if gitHeadCache[s.cwd] == "" { gitHeadCache[s.cwd] = nil }
            s.branch = branchForCwd(s.cwd)   // only on file change (a hook event), never on a bare tick
            sessions[id] = s
        }
    }

    func agentsDirPath(_ id: String) -> String {
        (stateDir as NSString).appendingPathComponent(id + ".agents.d")
    }

    // Refresh `sessionAgents` from each live session's <sid>.agents.d/. Agent files are
    // write-once/delete-once, so the DIRECTORY mtime (bumped by every add, delete, and the
    // atomic rename) is a complete change signal: one stat per session per tick, a readdir+parse
    // only when something actually changed — same philosophy as fileMTimes above.
    func reloadAgents() {
        let fm = FileManager.default
        for id in Array(sessionAgents.keys) where sessions[id] == nil {
            sessionAgents[id] = nil; agentDirMTimes[id] = nil
        }
        // Sweep orphaned agent dirs (session gone, dir shell left — e.g. a SubagentStop that
        // raced a turn-boundary reap). Never rendered (no live session), just disk hygiene.
        for f in ((try? fm.contentsOfDirectory(atPath: stateDir)) ?? []) where f.hasSuffix(".agents.d") {
            let sid = String(f.dropLast(".agents.d".count))
            if sessions[sid] == nil {
                try? fm.removeItem(atPath: (stateDir as NSString).appendingPathComponent(f))
            }
        }
        for id in sessions.keys {
            let dir = agentsDirPath(id)
            guard let attrs = try? fm.attributesOfItem(atPath: dir),
                  let m = attrs[.modificationDate] as? Date else {
                sessionAgents[id] = nil; agentDirMTimes[id] = nil   // no dir = no running agents
                continue
            }
            if agentDirMTimes[id] == m { continue }
            agentDirMTimes[id] = m
            var list: [AgentInfo] = []
            for f in ((try? fm.contentsOfDirectory(atPath: dir)) ?? []) where f.hasSuffix(".json") {
                guard let d = fm.contents(atPath: (dir as NSString).appendingPathComponent(f)),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { continue }
                list.append(AgentInfo(json: o, id: (f as NSString).deletingPathExtension))
            }
            // Spawn order, id as a stable tiebreak within the same second.
            sessionAgents[id] = list.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
        }
    }

    // MARK: git branch (no `git` spawn — .git/HEAD is a tiny text file)

    // Resolve <cwd>'s HEAD path by walking toward /. A worktree/submodule has .git as a FILE
    // containing "gitdir: <path>". Resolution walks directories, so cache it per cwd; a cached
    // "" means confirmed non-git. Dropped by branchForCwd if the HEAD read later fails.
    func gitHeadPath(_ cwd: String) -> String? {
        if let hit = gitHeadCache[cwd] { return hit.isEmpty ? nil : hit }
        let fm = FileManager.default
        var dir = cwd, isDir: ObjCBool = false
        for _ in 0..<40 {
            let g = (dir as NSString).appendingPathComponent(".git")
            if fm.fileExists(atPath: g, isDirectory: &isDir) {
                var head: String? = nil
                if isDir.boolValue {
                    head = (g as NSString).appendingPathComponent("HEAD")
                } else if let d = fm.contents(atPath: g), d.count <= 4096,
                          let s = String(data: d, encoding: .utf8),
                          let line = s.split(separator: "\n").first, line.hasPrefix("gitdir: ") {
                    var gd = String(line.dropFirst(8)).trimmingCharacters(in: .whitespaces)
                    if !gd.hasPrefix("/") { gd = ((dir as NSString).appendingPathComponent(gd) as NSString).standardizingPath }
                    head = (gd as NSString).appendingPathComponent("HEAD")
                }
                gitHeadCache[cwd] = head ?? ""
                return head
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { break }
            dir = parent
        }
        gitHeadCache[cwd] = ""
        return nil
    }

    // HEAD is "ref: refs/heads/<branch>" on a branch, a bare commit hash when detached.
    // nil (no branch text, no error) for non-git dirs and anything unrecognized.
    func branchForCwd(_ cwd: String) -> String {
        guard !cwd.isEmpty, let headPath = gitHeadPath(cwd) else { return "" }
        guard let d = FileManager.default.contents(atPath: headPath), d.count <= 1024,
              let s = String(data: d, encoding: .utf8) else {
            gitHeadCache[cwd] = nil   // stale resolution (repo moved/deleted) — retry next time
            return ""
        }
        let head = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("ref: refs/heads/") { return String(head.dropFirst(16)) }
        if head.hasPrefix("ref: ") { return ((head as NSString).lastPathComponent) }
        if (40...64).contains(head.count), head.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) {
            return String(head.prefix(7))   // detached HEAD -> short SHA
        }
        return ""
    }

    func evaluate() {
        let now = Date().timeIntervalSince1970
        var chime = false

        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            s.eff = effectiveState(s, now: now)   // compute once per tick; the menu + tooltip reuse it
            // Reap on PROCESS death, not idle time: a session leaves only when its `claude` process is
            // gone (closed/crashed terminal, quit app), so an idle-but-open session stays and the icon
            // holds. Pre-upgrade files have no pid (0) — fall back to the old idle+age prune so they
            // can't linger forever. This is also what keeps state.d self-cleaning (no growing cache).
            let dead = s.pid > 0 ? !pidAlive(s.pid)
                                 : (s.eff == "idle" && stalePruneAge > 0 && now - s.ts > stalePruneAge)
            if dead {
                try? FileManager.default.removeItem(atPath: (stateDir as NSString).appendingPathComponent(id + ".json"))
                try? FileManager.default.removeItem(atPath: agentsDirPath(id))
                sessions[id] = nil; fileMTimes[id + ".json"] = nil; prevState[id] = nil; sessionWord[id] = nil
                sessionAgents[id] = nil; agentDirMTimes[id] = nil
                soundPrev[id] = nil; turnStart[id] = nil; doneInfo[id] = nil
                continue
            }
            sessions[id] = s
            updateThinkingWord(s)
            prevState[s.id] = s.state
            if soundEdgeDone(s, now: now) { chime = true }   // also records the island's done flash
        }
        for id in Array(prevState.keys) where sessions[id] == nil { prevState[id] = nil; sessionWord[id] = nil }

        // Same-named projects (two clones/worktrees of one repo) get a parent-folder qualifier
        // ("work/myrepo" vs "tmp/myrepo") so their rows stay tellable apart. Runs after the reap so
        // dead sessions can't force a qualifier onto a now-unique name.
        // Only non-empty cwds count as colliding locations: a pre-upgrade/warmup file without cwd is
        // location-unknown, and counting its "" as a distinct place forced a bogus qualifier onto a
        // genuinely unique row.
        var cwdsByProject: [String: Set<String>] = [:]
        for s in sessions.values where !s.project.isEmpty && !s.cwd.isEmpty { cwdsByProject[s.project, default: []].insert(s.cwd) }
        for id in Array(sessions.keys) {
            guard var s = sessions[id] else { continue }
            if !s.cwd.isEmpty, (cwdsByProject[s.project]?.count ?? 0) > 1 {
                let parent = (((s.cwd as NSString).deletingLastPathComponent) as NSString).lastPathComponent
                s.displayName = parent.isEmpty ? s.project : parent + "/" + s.project
            } else {
                s.displayName = s.project
            }
            sessions[id] = s
        }
        for id in Array(soundPrev.keys) where sessions[id] == nil { soundPrev[id] = nil; turnStart[id] = nil; doneInfo[id] = nil }
        if chime, playCompletionSound { completionSound?.play() }

        // Surface the single highest-priority session (permission > working > …); ties broken by
        // recency, so within a tier the most recently active session wins.
        let lead = sessions.values.max { a, b in
            let pa = priority(of: a.eff), pb = priority(of: b.eff)
            return pa == pb ? a.ts < b.ts : pa < pb
        }
        leadSession = lead   // the dashboard hero card reflects this session
        statusItem.button?.toolTip = lead.map(sessionMenuLine)  // names repo + surface + state on hover

        guard let lead = lead else { renderResting(); return }
        switch lead.eff {
        case "permission":
            // startedAt = when the permission started waiting (hooks zero the turn clock here),
            // so the pill counts how long the request has sat unanswered — like the design.
            render(label: statusText(lead, eff: lead.eff), color: amber, animate: false,
                   startedAt: lead.ts, dot: true, accent: amber)
        case "thinking", "tool":
            render(label: statusText(lead, eff: lead.eff), color: iconColor, animate: true,
                   startedAt: lead.startedAt, accent: brand)
        default:
            // Done flash: hold a green check + the turn's duration for a few seconds, then rest.
            if lead.state == "done", let info = doneInfo[lead.id], now - info.at < doneFlashSecs {
                render(label: "Done", color: islandGreen, animate: false, startedAt: 0,
                       accent: islandGreen, done: true, doneDur: info.dur)
            } else {
                renderResting()
            }
        }
    }

    func renderResting() { render(label: "", color: iconColor, animate: false, startedAt: 0) }

    // Order the notch window in/out. Real notch: always shown (fuses with the physical cutout, even
    // idle). Synthetic pill (external monitor, no notch): shown only when there's something to surface
    // or while the panel is expanded — so an idle pill doesn't float over an external screen.
    func applyNotchVisibility() {
        guard let win = notchWindow, let geo = notchGeo, let view = notchView else { return }
        let show = !geo.synthetic || !notchResting || view.expanded
        if show {
            if !win.isVisible { win.orderFrontRegardless(); notchDbg("pill shown (synthetic=\(geo.synthetic) resting=\(notchResting))") }
        } else if win.isVisible {
            win.orderOut(nil); notchDbg("pill hidden (idle on synthetic external)")
        }
    }

    // Per-session effective state with two recovery nets: an absolute age cap, plus the transcript
    // "interrupted by user" marker (Esc / denied permission fire no hook, freezing the file). "done"
    // collapses to rest.
    func effectiveState(_ s: Session, now: Double) -> String {
        if s.state == "thinking" || s.state == "tool" || s.state == "permission" {
            let cap: Double = s.state == "permission" ? 7200 : 900
            if now - s.ts > cap { return "idle" }
            if !s.transcript.isEmpty, let last = lastTurnLine(ofFileAt: s.transcript),
               last.contains("interrupted by user") { return "idle" }
            return s.state
        }
        return s.state == "done" ? "idle" : s.state
    }

    // Detect a session's working->done edge for the chime (turns >= 5 min only). Updates the
    // per-session bookkeeping every call and returns true exactly once per qualifying edge.
    func soundEdgeDone(_ s: Session, now: Double) -> Bool {
        let prev = soundPrev[s.id] ?? ""
        if s.state == "thinking" || s.state == "tool", s.startedAt > 0 { turnStart[s.id] = s.startedAt }
        var edge = false
        if s.state == "done", prev != "done" {
            // Record the edge for the island's done flash (duration 0 when the turn start is unknown).
            let st = turnStart[s.id] ?? 0
            doneInfo[s.id] = (at: now, dur: st > 0 ? Int(now - st) : 0)
            if st > 0, now - st >= 300 { edge = true }
        }
        if s.state == "done" { turnStart[s.id] = 0 }
        soundPrev[s.id] = s.state
        return edge
    }

    // MARK: self-quit lifecycle

    func claudeDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == claudeDesktopBundleID }
    }

    func sessionCount() -> Int { stateFileNames().count }

    // Liveness probe: is this session's `claude` process still alive? kill(pid,0) returns 0 if the
    // process exists; EPERM = exists but not ours (won't happen, same user); ESRCH = gone.
    func pidAlive(_ pid: Int32) -> Bool {
        if pid <= 0 { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    // Stay while Claude desktop is open OR a session is active; otherwise quit after a
    // short debounced grace (warmup-session churn must not kill us).
    func checkLifecycle() {
        let now = Date()
        if now.timeIntervalSince(launchedAt) < launchGrace { return }
        if claudeDesktopRunning() || sessionCount() > 0 {
            notNeededSince = nil
            return
        }
        if let since = notNeededSince {
            if now.timeIntervalSince(since) >= idleQuitDelay { NSApp.terminate(nil) }
        } else {
            notNeededSince = now
        }
    }

    // Read the last non-empty line of a (possibly large) file by tailing ~8KB.
    func lastLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last { !$0.isEmpty }.map(String.init)
    }

    // Last actual turn line (a user/assistant message), ignoring the bookkeeping lines Claude Code
    // appends after an interrupt (system/away_summary, last-prompt, ai-title, mode, permission-mode).
    // Those would otherwise hide the "interrupted by user" marker and freeze the amber dot.
    func lastTurnLine(ofFileAt path: String) -> String? {
        guard let fh = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fh.close() }
        let size = (try? fh.seekToEnd()) ?? 0
        let chunk: UInt64 = 8192
        try? fh.seek(toOffset: size > chunk ? size - chunk : 0)
        guard let data = try? fh.readToEnd(), let s = String(data: data, encoding: .utf8) else { return nil }
        return s.split(separator: "\n").last {
            $0.contains("\"type\":\"user\"") || $0.contains("\"type\":\"assistant\"")
        }.map(String.init)
    }

    // MARK: render

    func render(label: String, color: NSColor?, animate: Bool, startedAt: Double, dot: Bool = false,
                accent: NSColor? = nil, done: Bool = false, doneDur: Int = 0) {
        // The menu bar button may be hidden (notch mode); the notch view is the sink then. Bail only
        // when NEITHER surface exists.
        guard statusItem.button != nil || notchView != nil else { return }
        statusItem.button?.contentTintColor = nil // we paint the icon color ourselves; template-tint is unreliable
        activeBase = label
        activeColor = color
        activeDot = dot
        stateAccent = accent
        flashDone = done
        flashDoneDur = doneDur
        self.startedAt = startedAt
        // Resting = nothing to show (no active turn, no waiting permission, no done flash). A synthetic
        // pill on an external monitor hides while resting; the real notch always stays (it fuses).
        notchResting = !animate && !dot && !done && label.isEmpty
        applyNotchVisibility()

        // Static icon per state (also the seed frame below). On the notch: permission shows the logo
        // glyph tinted amber (design), done shows the green check circle, rest is a dim gray glyph.
        func staticIcon() -> NSImage {
            if done { return doneIcon() }
            if dot { return notchView != nil ? restingIcon(color: accent ?? color) : dotIcon(color: color) }
            return restingIcon(color: notchView != nil ? islandGray : color)
        }

        // On the notch, idle = a bare cutout: clear the glyph so nothing flanks the camera.
        let idleOnNotch = notchView != nil && notchResting
        if animate {
            if animTimer == nil {
                let t = Timer(timeInterval: 1.0 / fps, repeats: true) { [weak self] _ in self?.animStep() }
                RunLoop.main.add(t, forMode: .common)
                animTimer = t
            }
        } else {
            animTimer?.invalidate(); animTimer = nil
            frameIdx = 0
            if idleOnNotch { notchView?.iconView.image = nil } else { setSinkImage(staticIcon()) }
        }
        applyTitle()
        // Seed a frame immediately so entering an animated state never flashes empty before the
        // first animStep tick (the notch view and the menu bar button both start out imageless).
        let hasImage = notchView != nil ? (notchView?.iconView.image != nil) : (statusItem.button?.image != nil)
        if !hasImage && !idleOnNotch {
            setSinkImage(animate ? iconImage(color: notchView != nil ? nil : color, frame: frameIdx) : staticIcon())
        }
    }

    func animStep() {
        frameIdx = (frameIdx + 1) % frameCount
        // On the notch, pass color:nil so the frame is a template and paints white on black.
        setSinkImage(iconImage(color: notchView != nil ? nil : activeColor, frame: frameIdx))
        if let hero = notchHeroIcon {   // the expanded dashboard's big icon animates in lockstep
            hero.image = iconImage(color: nil, frame: frameIdx)
            hero.contentTintColor = .white
        }
        applyTitle() // refresh the elapsed clock (also drives the hero clock)
    }

    // Keep the expanded hero card's big clock live for every state: turn clock while working, wait
    // clock while a permission sits, static duration on the done flash. Runs from applyTitle so the
    // permission clock ticks even though no animation timer is active.
    func updateNotchHeroClock() {
        guard let t = notchHeroTimer, let lead = leadSession else { return }
        let now = Date().timeIntervalSince1970
        let eff = lead.eff.isEmpty ? effectiveState(lead, now: now) : lead.eff
        if eff == "thinking" || eff == "tool", lead.startedAt > 0 {
            t.stringValue = elapsed(max(0, Int(now - lead.startedAt)))
        } else if eff == "permission" {
            t.stringValue = elapsed(max(0, Int(now - lead.ts)))
        } else if flashDone, flashDoneDur > 0 {
            t.stringValue = elapsed(flashDoneDur)
        }
    }

    func applyTitle() {
        let elapsedText: String
        if flashDone {
            elapsedText = (showTimer && flashDoneDur > 0) ? elapsed(flashDoneDur) : ""
        } else {
            elapsedText = (showTimer && startedAt > 0)
                ? elapsed(max(0, Int(Date().timeIntervalSince1970 - startedAt))) : ""
        }
        // Notch sink: label + timer live in their own fields, flanking the camera. At rest they go
        // empty so the collapsed island shrinks to the bare notch (design).
        if let v = notchView {
            let resting = activeBase.isEmpty
            v.labelField.stringValue = resting ? "" : activeBase
            v.labelField.textColor = .white
            v.timerField.stringValue = elapsedText
            v.timerField.textColor = stateAccent ?? brand   // amber waiting / green done / brand working
            updateNotchHeroClock()
            resizeNotchToFit()
            return
        }
        guard let button = statusItem.button else { return }
        var text = activeBase
        if !elapsedText.isEmpty { text += "  " + elapsedText }
        if text.isEmpty {
            button.imagePosition = .imageOnly
            button.attributedTitle = NSAttributedString(string: "")
            return
        }
        button.imagePosition = .imageLeading
        // labelColor adapts: white on a dark menu bar, black on a light one. Monospaced
        // digits keep the elapsed clock from nudging neighboring menu bar icons.
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular),
        ]
        button.attributedTitle = NSAttributedString(string: " \(text)", attributes: attrs)
    }

    // MARK: icon

    static func loadFrames() -> [NSImage] { decodePNGs(claudeSparkFramePNGs) }
    static func decodePNGs(_ list: [String]) -> [NSImage] {
        list.compactMap { Data(base64Encoded: $0).flatMap(NSImage.init(data:)) }
    }

    func iconImage(color: NSColor?, frame: Int) -> NSImage {
        if animStyle == .web { return sparkleIcon(color: color, frame: frame) }
        if animStyle == .crab { return crabIcon(color: color, frame: frame) }
        let i = (frame / codeSub) % codeGlyphs.count
        let local = (CGFloat(frame % codeSub) + 0.5) / CGFloat(codeSub) // 0…1 within this glyph
        // Scale envelope per glyph: rise, hold at peak, fall, so each lands before the swap.
        let env: CGFloat
        if local < 0.30 { let u = local / 0.30; env = u * u * (3 - 2 * u) }
        else if local > 0.70 { let u = (1 - local) / 0.30; env = u * u * (3 - 2 * u) }
        else { env = 1 }
        let scale = codeDip + (codePeaks[i] - codeDip) * env
        return codeIcon(color: color, glyph: i, scale: scale)
    }

    // nil color => adaptive template image (system draws it black/white per the menu bar).
    func codeIcon(color: NSColor?, glyph: Int, scale: CGFloat) -> NSImage {
        let s: CGFloat = 18
        guard glyph < codeGlyphMasks.count else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = codeGlyphMasks[glyph]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let dw = s * scale
            let r = NSRect(x: (s - dw) / 2, y: (s - dw) / 2, width: dw, height: dw)
            if let c = color {
                c.setFill(); r.fill()
                mask.draw(in: r, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Rasterize a single glyph into a centered 60x60 alpha mask filling ~92%.
    static func glyphMask(_ g: String) -> NSImage {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 180), .foregroundColor: NSColor.black,
        ]
        let str = NSAttributedString(string: g, attributes: attrs)
        let sz = str.size()
        let big = NSImage(size: sz, flipped: false) { _ in str.draw(at: .zero); return true }
        guard let rep = big.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) else {
            return NSImage(size: NSSize(width: 60, height: 60))
        }
        let w = rep.pixelsWide, h = rep.pixelsHigh, data = rep.bitmapData!
        var minx = w, miny = h, maxx = -1, maxy = -1
        for y in 0..<h { for x in 0..<w where data[(y*w+x)*4+3] > 20 {
            minx = min(minx, x); maxx = max(maxx, x); miny = min(miny, y); maxy = max(maxy, y)
        }}
        guard maxx >= 0 else { return NSImage(size: NSSize(width: 60, height: 60)) }
        let bw = CGFloat(maxx - minx + 1), bh = CGFloat(maxy - miny + 1)
        let out: CGFloat = 60, fill = out * 0.92
        let scale = fill / max(bw, bh)
        let dw = bw * scale, dh = bh * scale
        // NSBitmapImageRep origin is top-left; convert the bbox to bottom-left for drawing.
        let srcRect = NSRect(x: CGFloat(minx), y: CGFloat(h - maxy - 1), width: bw, height: bh)
        return NSImage(size: NSSize(width: out, height: out), flipped: false) { _ in
            big.draw(in: NSRect(x: (out - dw)/2, y: (out - dh)/2, width: dw, height: dh),
                     from: srcRect, operation: .sourceOver, fraction: 1.0)
            return true
        }
    }

    let logoSet: [NSImage] = Data(base64Encoded: claudeLogoPNG).flatMap(NSImage.init(data:)).map { [$0] } ?? []
    func restingIcon(color: NSColor?) -> NSImage {
        if animStyle == .crab { return crabIcon(color: color, frame: 0) }
        if animStyle == .web { return sparkleIcon(color: color, frame: 0) }   // static, un-rotated sparkle
        return tint(logoSet.isEmpty ? frames : logoSet, color: color, frame: 0)
    }

    // A crisp SF Symbol "sparkle" pre-rendered into a padded square so rotation pivots on its center.
    lazy var sparkleBase: NSImage? = {
        let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .semibold)
        guard let sym = NSImage(systemSymbolName: "sparkle", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return nil }
        let side = ceil(max(sym.size.width, sym.size.height)) + 3
        let img = NSImage(size: NSSize(width: side, height: side), flipped: false) { _ in
            sym.draw(in: NSRect(x: (side - sym.size.width) / 2, y: (side - sym.size.height) / 2,
                                width: sym.size.width, height: sym.size.height))
            return true
        }
        img.isTemplate = true
        return img
    }()

    // The "Spark" style: a clean SF Symbol sparkle that slowly spins and gently breathes while a turn
    // runs. Template when color==nil (the notch paints it white / the menu bar adapts it black/white);
    // tinted to `color` in brand-Orange mode. Replaces the old pixel sprite for a crisp vector look.
    func sparkleIcon(color: NSColor?, frame: Int) -> NSImage {
        guard let base = sparkleBase else { return NSImage(size: NSSize(width: 16, height: 16)) }
        let size = base.size
        let t = CGFloat(frame) / CGFloat(max(1, sparkleFrameCount))     // 0…1 around the loop
        let angle = t * 360
        let pulse = 0.9 + 0.1 * (0.5 - 0.5 * cos(t * 2 * .pi))          // subtle breathe
        let img = NSImage(size: size, flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            ctx.translateBy(x: c.x, y: c.y)
            ctx.rotate(by: -angle * .pi / 180)
            ctx.scaleBy(x: pulse, y: pulse)
            ctx.translateBy(x: -c.x, y: -c.y)
            base.draw(in: rect)
            if let col = color { col.set(); rect.fill(using: .sourceAtop) }   // tint the glyph in brand mode
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // nil color (System) => adaptive shaded template (see adaptiveCrabFrame in CrabRender.swift);
    // non-nil (Orange) => the original full-color sprite, drawn as-is.
    func crabIcon(color: NSColor?, frame: Int) -> NSImage {
        guard !crabFrames.isEmpty else { return NSImage(size: NSSize(width: 18, height: 18)) }
        let pool = color == nil ? crabTemplateFrames : crabFrames
        let src = pool[frame % pool.count]
        let rep = src.representations.first
        let pw = CGFloat(rep?.pixelsWide ?? Int(src.size.width))
        let ph = CGFloat(rep?.pixelsHigh ?? Int(src.size.height))
        let h: CGFloat = 18, w = (ph > 0 ? h * (pw / ph) : h)
        let img = NSImage(size: NSSize(width: w, height: h), flipped: false) { rect in
            src.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // The design's "done" badge: a solid green circle with a white checkmark, drawn by hand so it
    // renders full-color on both sinks (SF Symbol tinting is unreliable in the borderless panel).
    func doneIcon() -> NSImage {
        let s: CGFloat = 18
        let green = islandGreen
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            green.setFill()
            NSBezierPath(ovalIn: NSRect(x: 0.5, y: 0.5, width: s - 1, height: s - 1)).fill()
            NSColor.white.setStroke()
            let p = NSBezierPath()
            p.lineWidth = 2
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.move(to: NSPoint(x: 5.0, y: 9.2))
            p.line(to: NSPoint(x: 7.8, y: 6.4))
            p.line(to: NSPoint(x: 13.0, y: 11.6))
            p.stroke()
            return true
        }
        img.isTemplate = false
        return img
    }

    func dotIcon(color: NSColor?) -> NSImage {
        let s: CGFloat = 18, d: CGFloat = 9
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            (color ?? .systemYellow).setFill()
            NSBezierPath(ovalIn: NSRect(x: (s - d) / 2, y: (s - d) / 2, width: d, height: d)).fill()
            return true
        }
        img.isTemplate = (color == nil)
        return img
    }

    // Paint `color` through a frame mask's alpha (destinationIn) so frames recolor.
    func tint(_ set: [NSImage], color: NSColor?, frame: Int) -> NSImage {
        let s: CGFloat = 18
        guard !set.isEmpty else { return NSImage(size: NSSize(width: s, height: s)) }
        let mask = set[frame % set.count]
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { rect in
            if let c = color {
                c.setFill()
                rect.fill()
                mask.draw(in: rect, from: .zero, operation: .destinationIn, fraction: 1.0)
            } else {
                mask.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1.0)
            }
            return true
        }
        img.isTemplate = (color == nil) // nil => adaptive black/white in the menu bar
        return img
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = StatusController()
app.run()
