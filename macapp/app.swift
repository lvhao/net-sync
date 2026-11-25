import AppKit
import CoreImage
import Foundation

// ---------------------------------------------------------------- 配置

struct Folder: Codable, Identifiable {
    var id: String
    var name: String
    var path: String
    var enabled: Bool?
}

struct Peer: Codable {
    var name: String
    var lastSeen: String
}

struct SyncState: Codable {
    var token: String
    var port: Int
    var folders: [Folder]
    var peers: [String: Peer]
    /// 被 Mac 端暂停同步的设备（按 device id）
    var paused: [String: Bool]?
}

/// 设备在线与保留策略。
/// 手机在前台每 60 秒握手一次，90 秒没消息即视为离线；
/// 离线超过 2.5 分钟就从拓扑里彻底移除，避免留下同名幽灵节点。
enum PeerPresence {
    static let onlineWindow: TimeInterval = 90
    static let retention: TimeInterval = 150

    static func date(_ iso: String) -> Date? {
        var raw = iso
        if !raw.hasSuffix("Z"), !raw.contains("+") { raw += "Z" }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: raw) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: raw)
    }

    static func age(_ iso: String, now: Date = Date()) -> TimeInterval? {
        guard let seen = date(iso) else { return nil }
        return max(0, now.timeIntervalSince(seen))
    }

    static func isOnline(_ iso: String, now: Date = Date()) -> Bool {
        guard let age = age(iso, now: now) else { return false }
        return age < onlineWindow
    }

    /// 移除超时设备；暂停状态单独保留，手机以同一 ID 回来时仍然生效。
    @discardableResult
    static func prune(_ s: inout SyncState, now: Date = Date()) -> [String] {
        let stale = s.peers.compactMap { id, peer -> String? in
            guard let age = age(peer.lastSeen, now: now) else { return id }
            return age > retention ? id : nil
        }
        for id in stale { s.peers.removeValue(forKey: id) }
        return stale
    }

    /// 同一台手机重新配对后可能换了一个 device id。
    /// 新 ID 一出现，就清掉同名且已经离线的旧 ID，避免两个一样的手机。
    @discardableResult
    static func pruneDuplicates(of id: String, name: String,
                                in s: inout SyncState, now: Date = Date()) -> [String] {
        let copies = s.peers.compactMap { other, peer -> String? in
            guard other != id, peer.name == name else { return nil }
            guard let age = age(peer.lastSeen, now: now) else { return other }
            return age > onlineWindow ? other : nil
        }
        for other in copies { s.peers.removeValue(forKey: other) }
        return copies
    }
}

/// Mac 端脚本留在仓库里（方便改）， App 内只放一份副本。
func bundleDir() -> URL {
    URL(fileURLWithPath: Bundle.main.executablePath ?? "")
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

func baseDir() -> URL {
    let bundled = bundleDir().appendingPathComponent("Resources")
    if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("mac_server.py").path) {
        return bundled
    }
    // 开发时直接跑仓库里的脚本
    return URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}

let dataDir = URL(fileURLWithPath: NSHomeDirectory())
    .appendingPathComponent("Library/Application Support/NetSync")
let stateDir = dataDir
let configURL = stateDir.appendingPathComponent("config.json")

func loadState() -> SyncState? {
    guard let data = try? Data(contentsOf: configURL) else { return nil }
    return try? JSONDecoder().decode(SyncState.self, from: data)
}

func saveState(_ s: SyncState) {
    try? FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
    if let data = try? enc.encode(s) { try? data.write(to: configURL) }
}

func lanIP() -> String {
    var address = "127.0.0.1"
    var ifaddr: UnsafeMutablePointer<ifaddrs>?
    guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return address }
    defer { freeifaddrs(ifaddr) }
    for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
        let iface = ptr.pointee
        guard iface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
        guard String(cString: iface.ifa_name).hasPrefix("en") else { continue }
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(iface.ifa_addr.pointee.sa_len)
        if getnameinfo(iface.ifa_addr, len, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
            let ip = String(cString: host)
            if !ip.hasPrefix("169.254.") && !ip.hasPrefix("127.") {
                address = ip
                break
            }
        }
    }
    return address
}

func qrImage(_ text: String) -> NSImage? {
    guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
    filter.setValue(text.data(using: .utf8), forKey: "inputMessage")
    filter.setValue("M", forKey: "inputCorrectionLevel")
    guard let output = filter.outputImage else { return nil }
    let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
    let rep = NSCIImageRep(ciImage: scaled)
    let image = NSImage(size: rep.size)
    image.addRepresentation(rep)
    return image
}

// ---------------------------------------------------------------- 设计系统

enum Theme {
    static let paper = NSColor(hex: 0xF5F5F7)
    static let card = NSColor(hex: 0xFFFFFF)
    static let cardSoft = NSColor(hex: 0xFAFAFC)
    static let ink = NSColor(hex: 0x1D1D1F)
    static let inkSoft = NSColor(hex: 0x424245)
    static let muted = NSColor(hex: 0x6E6E73)
    static let faint = NSColor(hex: 0x86868B)
    static let line = NSColor(hex: 0xE5E5EA)
    static let accent = NSColor(hex: 0x0071E3)
    static let accentDeep = NSColor(hex: 0x0059B3)
    static let accentWash = NSColor(hex: 0xF0F6FC)
    static let ok = NSColor(hex: 0x34C759)
    static let amber = NSColor(hex: 0xC77700)
    static let amberWash = NSColor(hex: 0xFFF8EC)
    static let danger = NSColor(hex: 0xD70015)
    static let dangerWash = NSColor(hex: 0xFFF2F3)

    static let sidebarTop = NSColor(hex: 0xFFFFFF)
    static let sidebarBottom = NSColor(hex: 0xFFFFFF)
    static let onDark = NSColor(hex: 0x1D1D1F)
    static let onDarkMuted = NSColor(hex: 0x86868B)

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size, weight: weight)
    }

    static func sans(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size, weight: weight)
    }
}

extension NSColor {
    convenience init(hex: Int) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255,
                  alpha: 1)
    }
}

func symbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular) -> NSImage? {
    let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(config)
}

/// 生成带指定颜色的模板图标（用于自绘控件）。
func tintedSymbol(_ name: String, size: CGFloat, weight: NSFont.Weight = .regular,
                  color: NSColor) -> NSImage? {
    guard let base = symbol(name, size: size, weight: weight) else { return nil }
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        base.draw(in: rect)
        color.set()
        rect.fill(using: .sourceIn)
        return true
    }
    return image
}

func attributedLabel(_ text: String, font: NSFont, color: NSColor,
                     kern: CGFloat = 0, lineHeight: CGFloat? = nil) -> NSAttributedString {
    var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color, .kern: kern]
    if let lineHeight {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = lineHeight
        style.maximumLineHeight = lineHeight
        attrs[.paragraphStyle] = style
    }
    return NSAttributedString(string: text, attributes: attrs)
}

// ---------------------------------------------------------------- 基础控件

/// 柔和圆角面板：白底、细边、浅阴影。
final class Panel: NSView {
    init(_ content: NSView, padding: CGFloat = 18, radius: CGFloat = 16) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = Theme.card.cgColor
        layer?.cornerRadius = radius
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line.cgColor
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.035
        layer?.shadowRadius = 10
        layer?.shadowOffset = CGSize(width: 0, height: -2)
        translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding),
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class SidebarBackground: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.card.cgColor
        layer?.borderWidth = 1
        layer?.borderColor = Theme.line.cgColor
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class CardBackground: NSView {
    init(radius: CGFloat = 16, fill: NSColor = Theme.card,
         border: NSColor? = Theme.line) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = fill.cgColor
        layer?.cornerRadius = radius
        if let border {
            layer?.borderWidth = 1
            layer?.borderColor = border.cgColor
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class StatusDot: NSView {
    private let halo = NSView()
    private let core = NSView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        halo.wantsLayer = true
        halo.layer?.cornerRadius = 5
        halo.translatesAutoresizingMaskIntoConstraints = false
        addSubview(halo)

        core.wantsLayer = true
        core.layer?.cornerRadius = 3
        core.translatesAutoresizingMaskIntoConstraints = false
        addSubview(core)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 10),
            heightAnchor.constraint(equalToConstant: 10),
            halo.leadingAnchor.constraint(equalTo: leadingAnchor),
            halo.trailingAnchor.constraint(equalTo: trailingAnchor),
            halo.topAnchor.constraint(equalTo: topAnchor),
            halo.bottomAnchor.constraint(equalTo: bottomAnchor),
            core.centerXAnchor.constraint(equalTo: centerXAnchor),
            core.centerYAnchor.constraint(equalTo: centerYAnchor),
            core.widthAnchor.constraint(equalToConstant: 6),
            core.heightAnchor.constraint(equalToConstant: 6),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func tint(_ color: NSColor) {
        core.layer?.backgroundColor = color.cgColor
        halo.layer?.backgroundColor = color.withAlphaComponent(0.18).cgColor
    }
}

final class Pill: NSView {
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    init(text: String, color: NSColor, fill: NSColor, dot shown: Bool = true) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.backgroundColor = fill.cgColor
        translatesAutoresizingMaskIntoConstraints = false

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 2.5
        dot.layer?.backgroundColor = color.cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false

        label.attributedStringValue = attributedLabel(text, font: Theme.sans(10.5, .medium), color: color)
        label.translatesAutoresizingMaskIntoConstraints = false

        addSubview(dot)
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 20),
            dot.widthAnchor.constraint(equalToConstant: 5),
            dot.heightAnchor.constraint(equalToConstant: 5),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: shown ? 6 : -3),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        dot.isHidden = !shown
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func update(text: String, color: NSColor, fill: NSColor) {
        label.attributedStringValue = attributedLabel(text, font: Theme.sans(10.5, .medium), color: color)
        layer?.backgroundColor = fill.cgColor
        dot.layer?.backgroundColor = color.cgColor
    }
}

enum ButtonTone {
    case primary, dark, secondary, quiet, onDark, danger
}

/// 自绘按钮：不依赖 NSButton 的系统 chrome，尺寸完全按内容计算。
final class ActionButton: NSControl {
    private let tone: ButtonTone
    private var titleText: String
    private let iconName: String?
    private let fontSize: CGFloat
    private var hovered = false
    private var pressed = false
    private var tracking: NSTrackingArea?

    init(_ title: String, tone: ButtonTone, target: AnyObject?, action: Selector?,
         icon: String? = nil, size: CGFloat = 12) {
        self.tone = tone
        self.titleText = title
        self.iconName = icon
        self.fontSize = size
        super.init(frame: .zero)
        self.target = target
        self.action = action
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.borderWidth = 0
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 30).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 运行期改文案（例如“复制”→“已复制”），宽度随之重算。
    func setTitle(_ text: String) {
        guard text != titleText else { return }
        titleText = text
        invalidateIntrinsicContentSize()
        needsDisplay = true
    }

    override var intrinsicContentSize: NSSize {
        let text = (titleText as NSString).size(withAttributes: [.font: Theme.sans(fontSize, .medium)])
        var w = text.width + 26          // 左右内边距
        if iconName != nil { w += fontSize + 6 }
        return NSSize(width: ceil(w), height: 30)
    }

    override var isFlipped: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovered = true; needsDisplay = true; NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        hovered = false; pressed = false; needsDisplay = true; NSCursor.arrow.set()
    }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = true; needsDisplay = true
        let p = convert(event.locationInWindow, from: nil)
        // 跟随拖拽，松开在按钮内才触发
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let q = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp {
                pressed = false; needsDisplay = true
                if bounds.contains(q) { sendAction(action, to: target) }
                break
            }
            if bounds.contains(q) != bounds.contains(p) { needsDisplay = true }
        }
    }

    private var foreground: NSColor {
        switch tone {
        case .primary, .dark: return .white
        case .secondary: return Theme.ink
        case .quiet, .danger: return hovered && tone == .danger ? Theme.danger : Theme.muted
        case .onDark: return Theme.onDark
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                xRadius: 9, yRadius: 9)
        var fill: NSColor = .clear
        var border: NSColor = .clear

        switch tone {
        case .primary:
            fill = pressed ? NSColor(hex: 0x000000) : (hovered ? NSColor(hex: 0x2C2C2E) : Theme.ink)
        case .dark:
            fill = hovered ? NSColor(hex: 0x2C2C2E) : Theme.ink
        case .secondary:
            fill = hovered ? Theme.cardSoft : Theme.card
            border = hovered ? NSColor(hex: 0xD2D2D7) : Theme.line
        case .quiet:
            fill = hovered ? NSColor(hex: 0xF2F2F4) : .clear
        case .danger:
            fill = hovered ? Theme.dangerWash : .clear
        case .onDark:
            fill = NSColor.white.withAlphaComponent(hovered ? 0.14 : 0.07)
            border = NSColor.white.withAlphaComponent(0.14)
        }

        fill.setFill(); path.fill()
        if border != .clear {
            border.setStroke(); path.lineWidth = 1; path.stroke()
        }

        let font = Theme.sans(fontSize, .medium)
        let attr = NSAttributedString(string: titleText, attributes: [
            .font: font, .foregroundColor: foreground,
        ])
        let textSize = attr.size()
        let iconGap: CGFloat = iconName == nil ? 0 : fontSize + 6
        let contentW = textSize.width + (iconName == nil ? 0 : (fontSize + 6))
        let startX = (bounds.width - contentW) / 2

        if let iconName,
           let image = tintedSymbol(iconName, size: fontSize, weight: .medium,
                                    color: foreground) {
            let iconSide = fontSize + 2
            let iconRect = NSRect(x: startX, y: (bounds.height - iconSide) / 2,
                                  width: iconSide, height: iconSide)
            image.draw(in: iconRect, from: .zero, operation: .sourceOver, fraction: 1)
        }
        attr.draw(at: NSPoint(x: startX + iconGap,
                              y: (bounds.height - textSize.height) / 2))
    }
}

final class Tile: NSView {
    init(_ symbolName: String, tint: NSColor, wash: NSColor, size: CGFloat = 40) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = size * 0.3
        layer?.backgroundColor = wash.cgColor
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: size).isActive = true
        heightAnchor.constraint(equalToConstant: size).isActive = true
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        setContentHuggingPriority(.required, for: .vertical)
        setContentCompressionResistancePriority(.required, for: .vertical)

        let view = NSImageView()
        view.image = symbol(symbolName, size: size * 0.42, weight: .medium)
        view.contentTintColor = tint
        view.translatesAutoresizingMaskIntoConstraints = false
        addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: centerXAnchor),
            view.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class HoverRow: NSView {
    private var hovered = false
    private var tracking: NSTrackingArea?
    var onHover: ((Bool) -> Void)?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHover?(false)
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 主画布：左侧是电脑名 + 文件夹清单，右侧是手机。
/// 连线代表同步关系：点击连线即可暂停 / 恢复对应手机。
final class SyncMapView: NSView {

    struct Phone {
        var id: String
        var name: String
        var online: Bool
        var paused: Bool
        var synced: Int
        var total: Int
    }

    struct FolderItem {
        var id: String
        var name: String
        var path: String
        var exists: Bool
        var syncedDevices: Int
    }

    var folders: [FolderItem] = []
    var phones: [Phone] = []
    var running = false
    var macName = "此 Mac"

    var onAddFolder: (() -> Void)?
    var onRemoveFolder: ((String, String) -> Void)?
    var onTogglePause: ((String) -> Void)?

    private var phase: CGFloat = 0
    private var timer: Timer?

    private var cardRect = NSRect.zero
    private var folderRows: [(id: String, rect: NSRect, removeRect: NSRect)] = []
    private var addRect = NSRect.zero
    private var phoneCards: [(id: String, rect: NSRect)] = []
    private var links: [(id: String, samples: [CGPoint])] = []
    private var moreCount = 0

    private var hoveredFolder: String?
    private var hoveredPhone: String?
    private var hoveredLink: String?
    private var hoveredAdd = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = Theme.card.cgColor
        layer?.cornerRadius = 18
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var isFlipped: Bool { false }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        timer?.invalidate()
        guard window != nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            guard self.phones.contains(where: { $0.online && !$0.paused }) else { return }
            self.phase += 0.012
            if self.phase > 1 { self.phase -= 1 }
            self.needsDisplay = true
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    deinit { timer?.invalidate() }

    // ------------------------------------------------------------ 鼠标
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds,
                                       options: [.mouseMoved, .mouseEnteredAndExited,
                                                 .activeInKeyWindow],
                                       owner: self, userInfo: nil))
    }

    private func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    private func link(at p: CGPoint) -> String? {
        for link in links {
            for s in link.samples where distance(s, p) < 9 { return link.id }
        }
        return nil
    }

    private func hoveredFolderID(_ p: CGPoint) -> String? {
        folderRows.first { $0.rect.contains(p) }?.id
    }

    private func removeID(_ p: CGPoint) -> String? {
        folderRows.first { $0.removeRect.contains(p) }?.id
    }

    private func refreshHover(_ event: NSEvent?) {
        guard let event else { return }
        let p = convert(event.locationInWindow, from: nil)
        let folder = hoveredFolderID(p)
        let phone = phoneCards.first { $0.rect.contains(p) }?.id
        let linkID = link(at: p)
        let add = addRect.contains(p)

        let changed = folder != hoveredFolder || phone != hoveredPhone
            || linkID != hoveredLink || add != hoveredAdd
        hoveredFolder = folder
        hoveredPhone = phone
        hoveredLink = linkID
        hoveredAdd = add

        if add || linkID != nil || removeID(p) != nil {
            NSCursor.pointingHand.set()
        } else {
            NSCursor.arrow.set()
        }
        if changed { needsDisplay = true }
    }

    override func mouseMoved(with event: NSEvent) { refreshHover(event) }

    override func mouseExited(with event: NSEvent) {
        hoveredFolder = nil; hoveredPhone = nil; hoveredLink = nil; hoveredAdd = false
        NSCursor.arrow.set(); needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        // 连线：暂停/恢复
        if let id = link(at: p) {
            onTogglePause?(id)
            hoveredLink = nil
            needsDisplay = true
            return
        }
        if let id = removeID(p) {
            let name = folders.first { $0.id == id }?.name ?? ""
            onRemoveFolder?(id, name)
            return
        }
        if addRect.contains(p) { onAddFolder?() }
    }

    // ------------------------------------------------------------ 绘制
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        drawBackdrop()
        layoutNodes()

        // 连线画在卡片下面
        links = []
        for (i, phone) in phones.enumerated() where i < phoneCards.count {
            let from = CGPoint(x: cardRect.maxX, y: cardRect.midY)
            let to = CGPoint(x: phoneCards[i].rect.minX, y: phoneCards[i].rect.midY)
            let path = curve(from: from, to: to)
            drawLink(path, phone: phone, hovered: hoveredLink == phone.id)
            links.append((phone.id, samples(path)))
        }

        drawCard()
        for (i, phone) in phones.enumerated() where i < phoneCards.count {
            drawPhone(phoneCards[i].rect, phone: phone, index: i)
        }
        if phones.isEmpty { drawEmptyPhone() }
        drawFooter()
    }

    private func layoutNodes() {
        let H = bounds.height
        let W = bounds.width
        let cardW = min(max(W * 0.42, 330), 400)
        let rowH: CGFloat = 48
        let headerH: CGFloat = 66
        let maxH = H - 116
        let listTopLimit = maxH - headerH
        let capacity = max(1, Int((listTopLimit - 84) / rowH))
        let visibleCount = min(folders.count, capacity)
        moreCount = max(0, folders.count - visibleCount)
        let contentH = headerH + CGFloat(visibleCount) * rowH
            + (moreCount > 0 ? 18 : 0) + 78
        let cardH = min(max(220, contentH), maxH)
        cardRect = NSRect(x: 26, y: (H - cardH) / 2, width: cardW, height: cardH)

        // 添加行固定在卡片底部
        addRect = NSRect(x: cardRect.minX + 10, y: cardRect.minY + 12,
                         width: cardRect.width - 20, height: 34)

        let listTop = cardRect.maxY - headerH

        var rows: [(String, NSRect, NSRect)] = []
        var y = listTop
        for item in folders.prefix(visibleCount) {
            let rect = NSRect(x: cardRect.minX + 10, y: y - rowH + 4,
                              width: cardRect.width - 20, height: rowH - 4)
            let remove = NSRect(x: rect.maxX - 26, y: rect.midY - 10, width: 20, height: 20)
            rows.append((item.id, rect, remove))
            y -= rowH
        }
        folderRows = rows

        let phoneW: CGFloat = 176
        let cardHt: CGFloat = 62
        let gap: CGFloat = 14
        let n = min(phones.count, 3)
        let block = CGFloat(max(n, 1)) * cardHt + CGFloat(max(n - 1, 0)) * gap
        // 手机卡片与左侧卡片垂直居中对齐，避免大片空白
        let startY = cardRect.midY - block / 2
        phoneCards = phones.prefix(n).enumerated().map { i, phone in
            (phone.id, NSRect(x: W - phoneW - 24,
                              y: startY + CGFloat(n - 1 - i) * (cardHt + gap),
                              width: phoneW, height: cardHt))
        }
    }

    private func drawBackdrop() {
        Theme.card.setFill()
        bounds.fill()
        let dot = NSColor(hex: 0xEFEFF2)
        dot.setFill()
        var y: CGFloat = 16
        while y < bounds.height {
            var x: CGFloat = 16
            while x < bounds.width {
                NSBezierPath(ovalIn: NSRect(x: x, y: y, width: 1.4, height: 1.4)).fill()
                x += 24
            }
            y += 24
        }
    }

    private func curve(from a: CGPoint, to b: CGPoint) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: a)
        let dx = max((b.x - a.x) * 0.45, 20)
        path.curve(to: b,
                   controlPoint1: CGPoint(x: a.x + dx, y: a.y),
                   controlPoint2: CGPoint(x: b.x - dx, y: b.y))
        return path
    }

    private func samples(_ path: NSBezierPath) -> [CGPoint] {
        var pts = [NSPoint](repeating: .zero, count: 3)
        var prev = CGPoint.zero
        var flat: [CGPoint] = []
        let steps = 26
        for i in 0..<path.elementCount {
            let kind = path.element(at: i, associatedPoints: &pts)
            switch kind {
            case .moveTo:
                prev = pts[0]; flat.append(prev)
            case .lineTo:
                flat.append(pts[0]); prev = pts[0]
            case .curveTo:
                for s in 1...steps {
                    let t = CGFloat(s) / CGFloat(steps), mt = 1 - t
                    let x = mt*mt*mt*prev.x + 3*mt*mt*t*pts[0].x
                        + 3*mt*t*t*pts[1].x + t*t*t*pts[2].x
                    let y = mt*mt*mt*prev.y + 3*mt*mt*t*pts[0].y
                        + 3*mt*t*t*pts[1].y + t*t*t*pts[2].y
                    flat.append(CGPoint(x: x, y: y))
                }
                prev = pts[2]
            default: break
            }
        }
        return flat
    }

    private func drawLink(_ path: NSBezierPath, phone: Phone, hovered: Bool) {
        let connected = phone.online && !phone.paused

        if connected {
            // 已连接：实线
            (hovered ? Theme.muted : NSColor(hex: 0xC2C2C8)).setStroke()
            path.lineWidth = hovered ? 2 : 1.6
            path.stroke()
        } else {
            // 断开：虚线 + 红色端点标记
            let dashed = path.copy() as! NSBezierPath
            dashed.setLineDash([5, 5], count: 2, phase: 0)
            (hovered ? Theme.danger : NSColor(hex: 0xD3D3D8)).setStroke()
            dashed.lineWidth = hovered ? 1.8 : 1.4
            dashed.stroke()
            drawBrokenMark(at: path.point(at: 0.5, fallback: .zero), emphasized: hovered)
        }

        if hovered {
            let mid = path.point(at: 0.5, fallback: .zero)
            let label = connected ? "点击断开" : "点击连接"
            let font = Theme.sans(9.5, .medium)
            let size = (label as NSString).size(withAttributes: [.font: font])
            let box = NSRect(x: mid.x - size.width / 2 - 8, y: mid.y + 12,
                             width: size.width + 16, height: 19)
            Theme.ink.setFill()
            NSBezierPath(roundedRect: box, xRadius: 9.5, yRadius: 9.5).fill()
            NSAttributedString(string: label, attributes: [
                .font: font, .foregroundColor: NSColor.white,
            ]).draw(at: NSPoint(x: box.minX + 8, y: box.minY + 4.5))
            return
        }

        guard connected else { return }
        guard phones.contains(where: { $0.online && !$0.paused && $0.synced > 0 }) else { return }
        for k in 0..<3 {
            var t = phase + CGFloat(k) * 0.34
            if t > 1 { t -= 1 }
            let p = path.point(at: t, fallback: .zero)
            Theme.ok.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        }
    }

    /// 断点标识：红色圆底 + 白色 ×
    private func drawBrokenMark(at point: CGPoint, emphasized: Bool) {
        let r: CGFloat = emphasized ? 9 : 7.5
        let circle = NSRect(x: point.x - r, y: point.y - r, width: r * 2, height: r * 2)
        Theme.card.setFill()
        NSBezierPath(ovalIn: circle.insetBy(dx: -2, dy: -2)).fill()
        Theme.danger.setFill()
        NSBezierPath(ovalIn: circle).fill()

        let x = NSBezierPath()
        let d = r * 0.4
        x.move(to: CGPoint(x: point.x - d, y: point.y - d))
        x.line(to: CGPoint(x: point.x + d, y: point.y + d))
        x.move(to: CGPoint(x: point.x - d, y: point.y + d))
        x.line(to: CGPoint(x: point.x + d, y: point.y - d))
        NSColor.white.setStroke()
        x.lineWidth = 1.5
        x.lineCapStyle = .round
        x.stroke()
    }

    // ------------------------------------------------------------ 左侧卡片
    private func drawCard() {
        let path = NSBezierPath(roundedRect: cardRect, xRadius: 16, yRadius: 16)
        NSColor.white.setFill()
        path.fill()
        Theme.line.setStroke()
        path.lineWidth = 1
        path.stroke()

        // 头部：电脑名（不再单独做成节点）
        let nameY = cardRect.maxY - 30
        let shown = macName.count > 18 ? String(macName.prefix(17)) + "…" : macName
        text(shown, at: CGPoint(x: cardRect.minX + 16, y: nameY),
             font: Theme.sans(13, .semibold), color: Theme.ink)
        let sub = running
            ? (phones.contains { $0.online && !$0.paused } ? "正在同步" : "等待手机连接")
            : "服务未运行"
        text(sub, at: CGPoint(x: cardRect.minX + 16, y: nameY - 16),
             font: Theme.sans(9.5), color: running ? Theme.faint : Theme.danger)
        dot(at: CGPoint(x: cardRect.maxX - 16, y: nameY + 5),
            color: running ? Theme.ok : NSColor(hex: 0xC7C7CC))

        let rule = NSBezierPath()
        rule.move(to: CGPoint(x: cardRect.minX + 14, y: cardRect.maxY - 50))
        rule.line(to: CGPoint(x: cardRect.maxX - 14, y: cardRect.maxY - 50))
        Theme.line.setStroke(); rule.lineWidth = 1; rule.stroke()

        // 文件夹行
        for item in folders where folderRows.contains(where: { $0.id == item.id }) {
            guard let row = folderRows.first(where: { $0.id == item.id })?.rect else { continue }
            let hover = hoveredFolder == item.id
            if hover {
                NSColor(hex: 0xF6F6F8).setFill()
                NSBezierPath(roundedRect: row, xRadius: 9, yRadius: 9).fill()
            }
            drawSymbol(item.exists ? "folder.fill" : "exclamationmark.triangle.fill",
                       in: NSRect(x: row.minX + 10, y: row.midY - 7, width: 14, height: 14),
                       color: item.exists ? Theme.inkSoft : Theme.amber)
            text(item.name, at: CGPoint(x: row.minX + 32, y: row.midY + 1),
                 font: Theme.sans(11.5, .medium), color: Theme.ink)

            // 第二行：完整路径（过长按中间省略，保留层级信息）
            let path = item.path.replacingOccurrences(
                of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")
            let pathWidth = row.width - 32 - (hover ? 34 : 8)
            let shown = ellipsizedMiddle(path, font: Theme.sans(8.5), width: pathWidth)
            text(shown, at: CGPoint(x: row.minX + 32, y: row.midY - 16),
                 font: Theme.sans(8.5), color: !item.exists ? Theme.amber : Theme.faint)

            // 右侧：同步状态
            let caption = !item.exists ? "不可用"
                : (item.syncedDevices > 0 ? "\(item.syncedDevices) 台" : "待同步")
            if !hover {
                let font = Theme.sans(8.5)
                let w = (caption as NSString).size(withAttributes: [.font: font]).width
                text(caption, at: CGPoint(x: row.maxX - 12 - w, y: row.midY - 3),
                     font: font, color: !item.exists ? Theme.amber : Theme.faint)
            }

            if hover {
                let rm = folderRows.first { $0.id == item.id }?.removeRect ?? .zero
                NSColor(hex: 0xEDEDF0).setFill()
                NSBezierPath(ovalIn: rm).fill()
                drawSymbol("xmark", in: rm.insetBy(dx: 5, dy: 5), color: Theme.muted)
            }
        }

        if moreCount > 0 {
            text("还有 \(moreCount) 个目录", at: CGPoint(x: cardRect.minX + 18,
                                                      y: addRect.maxY + 8),
                 font: Theme.sans(9), color: Theme.faint)
        }

        // 添加文件夹（唯一入口）
        let add = NSBezierPath(roundedRect: addRect, xRadius: 9, yRadius: 9)
        (hoveredAdd ? NSColor(hex: 0xF2F2F4) : NSColor(hex: 0xFAFAFB)).setFill()
        add.fill()
        let border = add.copy() as! NSBezierPath
        border.setLineDash([4, 3], count: 2, phase: 0)
        Theme.line.setStroke(); border.lineWidth = 1; border.stroke()
        drawSymbol("plus", in: NSRect(x: addRect.minX + 13, y: addRect.midY - 6,
                                      width: 12, height: 12), color: Theme.muted)
        text("添加文件夹", at: CGPoint(x: addRect.minX + 33, y: addRect.midY - 7),
             font: Theme.sans(11), color: Theme.muted)

        if folders.isEmpty {
            text("还没有同步文件夹", at: CGPoint(x: cardRect.midX, y: cardRect.midY + 6),
                 font: Theme.sans(10.5), color: Theme.faint, centered: true)
            text("点下方虚线框添加目录", at: CGPoint(x: cardRect.midX, y: cardRect.midY - 14),
                 font: Theme.sans(9), color: Theme.faint, centered: true)
        }
    }

    // ------------------------------------------------------------ 手机
    private func drawPhone(_ rect: NSRect, phone: Phone, index: Int) {
        let path = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        let hover = hoveredPhone == phone.id || hoveredLink == phone.id
        (hover ? NSColor(hex: 0xFFFFFF) : NSColor.white).setFill()
        path.fill()
        if phone.online && !phone.paused {
            Theme.line.setStroke(); path.lineWidth = 1; path.stroke()
        } else {
            let border = path.copy() as! NSBezierPath
            border.setLineDash([4, 4], count: 2, phase: 0)
            NSColor(hex: 0xD6D6DB).setStroke(); border.lineWidth = 1; border.stroke()
        }

        let tile = NSRect(x: rect.minX + 12, y: rect.midY - 15, width: 30, height: 30)
        NSColor(hex: 0xF2F2F4).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 9, yRadius: 9).fill()
        drawSymbol("iphone.gen3", in: tile.insetBy(dx: 9, dy: 6),
                   color: phone.online && !phone.paused ? Theme.inkSoft : Theme.faint)

        let shown = phone.name.count > 11 ? String(phone.name.prefix(10)) + "…" : phone.name
        text(shown, at: CGPoint(x: tile.maxX + 9, y: rect.midY - 2),
             font: Theme.sans(11.5, .medium),
             color: phone.online ? Theme.ink : Theme.muted)

        let detail = phone.paused ? "已暂停 · 点连线恢复"
            : (phone.online ? "\(phone.synced)/\(phone.total) 已同步" : "离线")
        text(detail, at: CGPoint(x: tile.maxX + 9, y: rect.midY - 18),
             font: Theme.sans(9),
             color: phone.paused ? Theme.amber : Theme.faint)

        dot(at: CGPoint(x: rect.maxX - 14, y: rect.midY),
            color: phone.paused ? NSColor(hex: 0xC7C7CC)
                 : (phone.online ? Theme.ok : NSColor(hex: 0xC7C7CC)))
    }

    private func drawEmptyPhone() {
        let rect = NSRect(x: bounds.width - 200, y: bounds.height / 2 - 34,
                          width: 176, height: 68)
        let p = NSBezierPath(roundedRect: rect, xRadius: 13, yRadius: 13)
        NSColor(hex: 0xFCFCFD).setFill(); p.fill()
        let border = p.copy() as! NSBezierPath
        border.setLineDash([4, 4], count: 2, phase: 0)
        NSColor(hex: 0xD6D6DB).setStroke(); border.lineWidth = 1; border.stroke()
        text("还没有手机连上来", at: CGPoint(x: rect.midX, y: rect.midY + 2),
             font: Theme.sans(10.5, .medium), color: Theme.muted, centered: true)
        text("扫描左侧二维码配对", at: CGPoint(x: rect.midX, y: rect.midY - 14),
             font: Theme.sans(9), color: Theme.faint, centered: true)
    }

    // ------------------------------------------------------------ 页脚
    private func drawFooter() {
        let y: CGFloat = 24
        dot(at: CGPoint(x: 26, y: y), color: Theme.ok)
        text("同步中", at: CGPoint(x: 38, y: y - 6), font: Theme.sans(9), color: Theme.faint)

        let line = NSBezierPath()
        line.move(to: CGPoint(x: 78, y: y)); line.line(to: CGPoint(x: 92, y: y))
        line.setLineDash([3, 3], count: 2, phase: 0)
        NSColor(hex: 0xC7C7CC).setStroke(); line.lineWidth = 1.2; line.stroke()
        text("离线 / 已暂停", at: CGPoint(x: 100, y: y - 6),
             font: Theme.sans(9), color: Theme.faint)

        text("点击连线可暂停同步", at: CGPoint(x: bounds.width - 24 - 118, y: y - 6),
             font: Theme.sans(9), color: Theme.faint)
    }

    // ------------------------------------------------------------ 工具
    private func dot(at point: CGPoint, color: NSColor) {
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 3, y: point.y - 3,
                                    width: 6, height: 6)).fill()
    }

    private func text(_ string: String, at point: CGPoint, font: NSFont,
                      color: NSColor, centered: Bool = false) {
        let attr = NSAttributedString(string: string,
                                      attributes: [.font: font, .foregroundColor: color])
        let size = attr.size()
        attr.draw(at: CGPoint(x: centered ? point.x - size.width / 2 : point.x, y: point.y))
    }

    private func drawSymbol(_ name: String, in rect: NSRect, color: NSColor) {
        guard let image = tintedSymbol(name, size: rect.height, weight: .medium, color: color)
        else { return }
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
    }

    /// 中间省略：保留首尾，方便看出是哪一层目录。
    private func ellipsizedMiddle(_ text: String, font: NSFont, width: CGFloat) -> String {
        func w(_ s: String) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }
        guard w(text) > width else { return text }
        let chars = Array(text)
        let headN = max(6, Int(CGFloat(chars.count) * 0.42))
        let tailN = max(6, Int(CGFloat(chars.count) * 0.34))
        var head = String(chars.prefix(headN))
        var tail = String(chars.suffix(tailN))
        while w(head + "…" + tail) > width && head.count > 2 && tail.count > 2 {
            head.removeLast()
            tail.removeFirst()
            if w(head + "…" + tail) <= width { break }
        }
        return head + "…" + tail
    }
}

private extension NSBezierPath {
    /// 在路径上取一点（按比例）。用折线近似采样，避免解贝塞尔。
    func point(at progress: CGFloat, fallback: CGPoint) -> CGPoint {
        var pts = [NSPoint](repeating: .zero, count: 3)
        var prev = CGPoint.zero
        var flat: [CGPoint] = []
        let steps = 40
        for i in 0..<elementCount {
            let kind = element(at: i, associatedPoints: &pts)
            switch kind {
            case .moveTo:
                prev = pts[0]; flat.append(prev)
            case .lineTo:
                flat.append(pts[0]); prev = pts[0]
            case .curveTo:
                for s in 1...steps {
                    let t = CGFloat(s) / CGFloat(steps), mt = 1 - t
                    let x = mt*mt*mt*prev.x + 3*mt*mt*t*pts[0].x
                        + 3*mt*t*t*pts[1].x + t*t*t*pts[2].x
                    let y = mt*mt*mt*prev.y + 3*mt*mt*t*pts[0].y
                        + 3*mt*t*t*pts[1].y + t*t*t*pts[2].y
                    flat.append(CGPoint(x: x, y: y))
                }
                prev = pts[2]
            default: break
            }
        }
        guard flat.count > 1 else { return fallback }
        let clamped = min(max(progress, 0), 1)
        let idx = min(flat.count - 1, Int(clamped * CGFloat(flat.count - 1)))
        return flat[idx]
    }
}

// ---------------------------------------------------------------- 同步服务

final class ServerProcess {
    private let server = SwiftServer()
    private(set) var running = false

    func start(with state: SyncState) {
        if running { return }
        running = server.start(state: state, port: UInt16(state.port))
    }

    func stop() {
        server.stop()
        running = false
    }
}

/// 服务独立于窗口存活，窗口关掉也不停。
enum NetSyncService {
    static let shared = ServerProcess()
}

// ---------------------------------------------------------------- 窗口

final class MainWindowController: NSWindowController {

    private var strongWindow: NSWindow?
    private var state: SyncState?
    private var ip = lanIP()
    private let server = NetSyncService.shared
    private var timer: Timer?

    // 侧栏
    private let addressLabel = NSTextField(labelWithString: "")
    private let qrView = NSImageView()
    private let copyButton = ActionButton("复制", tone: .quiet, target: nil, action: nil, size: 10)

    // 工作区
    private let headerStatus = Pill(text: "正在启动", color: Theme.muted, fill: Theme.cardSoft)

    private var map: SyncMapView?
    private var servedSignature = ""

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1020, height: 780),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "内网同步"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.backgroundColor = Theme.paper
        // 默认 true 会在失去引用时释放窗口，表现为“进程在但没窗口”
        window.isReleasedWhenClosed = false
        window.hidesOnDeactivate = false
        window.center()
        window.minSize = NSSize(width: 960, height: 700)
        self.init(window: window)
        strongWindow = window
        buildUI()
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        state = loadState()
        refreshQR()
        if let s = state { server.start(with: s) }
        reload(force: true)
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            self?.reload()
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // -- 排版助手
    private func label(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                       color: NSColor = Theme.ink) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = Theme.sans(size, weight)
        l.textColor = color
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func monoLabel(_ text: String, size: CGFloat,
                           color: NSColor = Theme.muted) -> NSTextField {
        let l = label(text, size: size, color: color)
        l.font = Theme.mono(size)
        return l
    }

    private func vstack(_ views: [NSView], spacing: CGFloat,
                        alignment: NSLayoutConstraint.Attribute = .leading) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .vertical
        s.alignment = alignment
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func hstack(_ views: [NSView], spacing: CGFloat,
                        alignment: NSLayoutConstraint.Attribute = .centerY,
                        distribution: NSStackView.Distribution = .fill) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.alignment = alignment
        s.distribution = distribution
        s.spacing = spacing
        s.translatesAutoresizingMaskIntoConstraints = false
        return s
    }

    private func separator() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = Theme.line.cgColor
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return v
    }

    private func eyebrow(_ text: String, color: NSColor = Theme.faint) -> NSTextField {
        let l = NSTextField(labelWithAttributedString:
            attributedLabel(text.uppercased(), font: Theme.sans(9.5, .semibold),
                            color: color, kern: 1.5))
        l.translatesAutoresizingMaskIntoConstraints = false
        return l
    }

    private func sectionHead(_ title: String, _ caption: NSTextField,
                             action: NSView? = nil) -> NSView {
        let titleLabel = label(title, size: 15, weight: .semibold)
        let left = vstack([titleLabel, caption], spacing: 2)
        var views: [NSView] = [left, NSView()]
        if let action { views.append(action) }
        let row = hstack(views, spacing: 10, alignment: .centerY)
        left.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return row
    }

    // -- 建界面
    private func buildUI() {
        guard let window, let content = window.contentView else { return }
        content.wantsLayer = true
        content.layer?.backgroundColor = Theme.paper.cgColor

        let sidebar = SidebarBackground()
        sidebar.translatesAutoresizingMaskIntoConstraints = false
        let workspace = NSView()
        workspace.wantsLayer = true
        workspace.layer?.backgroundColor = Theme.paper.cgColor
        workspace.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sidebar)
        content.addSubview(workspace)
        NSLayoutConstraint.activate([
            sidebar.topAnchor.constraint(equalTo: content.topAnchor),
            sidebar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            sidebar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sidebar.widthAnchor.constraint(equalToConstant: 336),
            workspace.topAnchor.constraint(equalTo: content.topAnchor),
            workspace.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            workspace.leadingAnchor.constraint(equalTo: sidebar.trailingAnchor),
            workspace.trailingAnchor.constraint(equalTo: content.trailingAnchor),
        ])

        buildSidebar(sidebar)
        buildWorkspace(workspace)

    }

    private func buildSidebar(_ sidebar: NSView) {
        let logoBox = NSView()
        logoBox.wantsLayer = true
        logoBox.layer?.backgroundColor = Theme.ink.cgColor
        logoBox.layer?.cornerRadius = 11
        logoBox.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            logoBox.widthAnchor.constraint(equalToConstant: 38),
            logoBox.heightAnchor.constraint(equalToConstant: 38),
        ])
        let logoIcon = NSImageView()
        logoIcon.image = symbol("arrow.left.arrow.right", size: 16, weight: .semibold)
        logoIcon.contentTintColor = .white
        logoIcon.translatesAutoresizingMaskIntoConstraints = false
        logoBox.addSubview(logoIcon)
        NSLayoutConstraint.activate([
            logoIcon.centerXAnchor.constraint(equalTo: logoBox.centerXAnchor),
            logoIcon.centerYAnchor.constraint(equalTo: logoBox.centerYAnchor),
        ])

        let name = label("内网同步", size: 17, weight: .semibold)
        let tag = NSTextField(labelWithAttributedString:
            attributedLabel("局域网直传 · 不经过云端", font: Theme.sans(9), color: Theme.faint))
        tag.translatesAutoresizingMaskIntoConstraints = false
        let brand = hstack([logoBox, vstack([name, tag], spacing: 1), NSView()], spacing: 11,
                           alignment: .centerY)

        // 唯一的二维码：扫码后进入配对/安装落地页
        qrView.imageScaling = .scaleProportionallyUpOrDown
        qrView.wantsLayer = true
        qrView.layer?.magnificationFilter = .nearest
        qrView.layer?.minificationFilter = .nearest
        qrView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            qrView.widthAnchor.constraint(equalToConstant: 178),
            qrView.heightAnchor.constraint(equalToConstant: 178),
        ])

        let scanTitle = label("手机扫码", size: 11.5, weight: .medium)
        scanTitle.alignment = .center
        let scanHint = label("已安装会直接打开并配对\n没装的话先下载安装包", size: 9.5, color: Theme.faint)
        scanHint.alignment = .center
        scanHint.maximumNumberOfLines = 2
        scanHint.lineBreakMode = .byWordWrapping

        let qrInner = vstack([qrView, scanTitle, scanHint], spacing: 8, alignment: .centerX)
        qrInner.setCustomSpacing(10, after: qrView)
        let pairPanel = Panel(qrInner, padding: 14, radius: 14)
        pairPanel.setContentHuggingPriority(.required, for: .vertical)
        pairPanel.setContentCompressionResistancePriority(.required, for: .vertical)
        pairPanel.heightAnchor.constraint(equalToConstant: 268).isActive = true

        let steps = vstack([
            stepLine("1", "手机与电脑连同一个 Wi-Fi"),
            stepLine("2", "扫码 → 打开 App 完成配对"),
            stepLine("3", "保持窗口打开，自动同步"),
        ], spacing: 9)

        addressLabel.font = Theme.mono(9.5)
        addressLabel.textColor = Theme.faint
        addressLabel.translatesAutoresizingMaskIntoConstraints = false
        copyButton.target = self
        copyButton.action = #selector(copyAddress)
        let addressRow = hstack([addressLabel, NSView(), copyButton], spacing: 6)

        let shield = NSImageView()
        shield.image = symbol("lock.shield", size: 10, weight: .regular)
        shield.contentTintColor = Theme.faint
        shield.translatesAutoresizingMaskIntoConstraints = false
        let privacy = hstack([shield, label("数据只在你两台设备之间流动", size: 9.5, color: Theme.faint)],
                             spacing: 5)
        privacy.alignment = .centerY

        let divider = NSView()
        divider.wantsLayer = true
        divider.layer?.backgroundColor = Theme.line.cgColor
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.heightAnchor.constraint(equalToConstant: 1).isActive = true

        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .vertical)
        spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 6).isActive = true

        // 内容自上而下自然排列，多余空白只落在间隔器上
        let stack = vstack([brand, pairPanel, steps, spacer, divider, addressRow, privacy],
                           spacing: 16)
        stack.setContentHuggingPriority(.required, for: .vertical)
        stack.setCustomSpacing(22, after: brand)
        stack.setCustomSpacing(14, after: pairPanel)
        stack.setCustomSpacing(18, after: steps)
        stack.setCustomSpacing(18, after: divider)
        stack.setCustomSpacing(12, after: addressRow)
        sidebar.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: sidebar.topAnchor, constant: 48),
            stack.leadingAnchor.constraint(equalTo: sidebar.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: sidebar.trailingAnchor, constant: -24),
            stack.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -20),
            brand.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pairPanel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            steps.widthAnchor.constraint(equalTo: stack.widthAnchor),
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor),
            addressRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            privacy.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
        NSLayoutConstraint.activate([
            privacy.bottomAnchor.constraint(equalTo: sidebar.bottomAnchor, constant: -22),
        ])
    }

    private func stepLine(_ index: String, _ text: String) -> NSView {
        let badge = NSTextField(labelWithString: index)
        badge.font = Theme.sans(9, .semibold)
        badge.textColor = Theme.muted
        badge.alignment = .center
        badge.wantsLayer = true
        badge.layer?.backgroundColor = NSColor(hex: 0xF2F2F4).cgColor
        badge.layer?.cornerRadius = 7.5
        badge.translatesAutoresizingMaskIntoConstraints = false
        badge.widthAnchor.constraint(equalToConstant: 15).isActive = true
        badge.heightAnchor.constraint(equalToConstant: 15).isActive = true

        let textLabel = NSTextField(labelWithString: text)
        textLabel.font = Theme.sans(10.5)
        textLabel.textColor = Theme.muted
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        textLabel.lineBreakMode = .byTruncatingTail
        return hstack([badge, textLabel], spacing: 8)
    }

    private func buildWorkspace(_ workspace: NSView) {
        // 页头固定在顶部，主画布占满其余空间
        let eyebrowLabel = eyebrow("同步空间", color: Theme.faint)
        let title = label("局域网直连", size: 24, weight: .semibold)
        let subtitle = label("手机与这台 Mac 直接传文件，不经过云端。", size: 12, color: Theme.muted)
        let heading = vstack([eyebrowLabel, title, subtitle], spacing: 4)
        heading.setCustomSpacing(7, after: eyebrowLabel)

        headerStatus.setContentHuggingPriority(.required, for: .horizontal)
        headerStatus.setContentCompressionResistancePriority(.required, for: .horizontal)
        let header = hstack([heading, NSView(), headerStatus], spacing: 12, alignment: .centerY)
        heading.setContentHuggingPriority(.defaultLow, for: .horizontal)
        heading.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let mapView = SyncMapView()
        mapView.onAddFolder = { [weak self] in self?.addFolder() }
        mapView.onRemoveFolder = { [weak self] id, name in
            self?.confirmRemoveFolder(id: id, name: name)
        }
        mapView.onTogglePause = { [weak self] id in self?.togglePause(peer: id) }
        map = mapView
        mapView.translatesAutoresizingMaskIntoConstraints = false

        let canvas = Panel(mapView, padding: 0, radius: 18)
        let inner = vstack([header, canvas], spacing: 16)
        inner.translatesAutoresizingMaskIntoConstraints = false
        workspace.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: workspace.topAnchor, constant: 28),
            inner.leadingAnchor.constraint(equalTo: workspace.leadingAnchor, constant: 28),
            inner.trailingAnchor.constraint(equalTo: workspace.trailingAnchor, constant: -28),
            inner.bottomAnchor.constraint(equalTo: workspace.bottomAnchor, constant: -22),
            header.widthAnchor.constraint(equalTo: inner.widthAnchor),
            canvas.widthAnchor.constraint(equalTo: inner.widthAnchor),
        ])
    }

    // -- 数据刷新
    private func reload(force: Bool = false) {
        ip = lanIP()
        if let latest = loadState() { state = latest }

        // peers 不会被手机主动注销。Mac 端每次刷新顺手清掉超时设备，
        // 否则掉线手机会一直以“离线”节点留在拓扑里。
        if var s = state {
            let stale = PeerPresence.prune(&s)
            if !stale.isEmpty {
                for id in stale { SwiftServer.syncState.removeValue(forKey: id) }
                saveState(s)
                state = s
            }
        }

        // 配置若被外部改动（或新增/移除目录），把新状态下发给已运行的服务，
        // 否则 /api/folders 仍返回旧列表，手机端感知不到变化。
        if let s = state {
            let sig = s.folders.map { "\($0.id)|\($0.name)|\($0.path)|\($0.enabled ?? true)" }
                .joined(separator: ";") + "|port:\(s.port)|token:\(s.token)"
            if sig != servedSignature {
                servedSignature = sig
                // 只下发新状态，不重启监听（避免端口抖动与连接中断）
                if server.running { SwiftServer.shared?.update(state: s) }
                refreshQR()
            }
        }

        let folders = (state?.folders ?? []).filter { $0.enabled ?? true }
        let peers = (state?.peers ?? [:]).sorted { $0.value.lastSeen > $1.value.lastSeen }
        let online = peers.filter { PeerPresence.isOnline($0.value.lastSeen) }
        let running = server.running

        let port = state?.port ?? 8765
        addressLabel.stringValue = "\(ip):\(port)"

        if running {
            let waiting = !peers.isEmpty && online.isEmpty
            headerStatus.update(text: online.isEmpty ? (waiting ? "等待设备唤醒" : "等待手机连接") : "自动同步中",
                                color: online.isEmpty ? Theme.faint : Theme.ok,
                                fill: NSColor(hex: 0xF2F2F4))
        } else {
            headerStatus.update(text: "服务未运行", color: Theme.danger, fill: Theme.dangerWash)
        }

        guard let map else { return }
        map.running = running
        map.macName = Host.current().localizedName ?? "此 Mac"
        map.folders = folders.map { f in
            SyncMapView.FolderItem(
                id: f.id, name: f.name, path: f.path,
                exists: FileManager.default.fileExists(atPath: f.path),
                syncedDevices: peers.filter { SwiftServer.syncState[$0.key]?[f.id] != nil }.count)
        }
        map.phones = peers.prefix(3).map { id, p in
            let synced = folders.filter { SwiftServer.syncState[id]?[$0.id] != nil }.count
            return SyncMapView.Phone(
                id: id, name: p.name,
                online: PeerPresence.isOnline(p.lastSeen),
                paused: state?.paused?[id] == true,
                synced: synced, total: folders.count)
        }
        map.needsDisplay = true
    }

    private func refreshQR() {
        guard let s = state else { return }
        // 一个码搞定：落地页里可打开 App 配对，也可下载安装
        qrView.image = qrImage("http://\(ip):\(s.port)/pair")
    }

    // -- 动作
    @objc private func copyAddress() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(addressLabel.stringValue, forType: .string)
        copyButton.setTitle("已复制")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in
            self?.copyButton.setTitle("复制")
        }
    }

    @objc private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "同步这个文件夹"
        guard panel.runModal() == .OK, let url = panel.url, var s = state else { return }
        let clean = url.standardizedFileURL.path
        if s.folders.contains(where: { $0.path == clean }) { return }
        var n = s.folders.count + 1
        while s.folders.contains(where: { $0.id == "f\(n)" }) { n += 1 }
        s.folders.append(Folder(id: "f\(n)", name: url.lastPathComponent,
                                path: clean, enabled: true))
        saveState(s)
        state = s
        restartServer()
        reload(force: true)
    }

    private func confirmRemoveFolder(id: String, name: String) {
        let alert = NSAlert()
        alert.messageText = "不再同步「\(name)」？"
        alert.informativeText = "本机文件不会被删除，只是手机上不再出现这个文件夹。"
        alert.addButton(withTitle: "移除")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard var s = state else { return }
        s.folders.removeAll { $0.id == id }
        saveState(s)
        state = s
        restartServer()
        reload(force: true)
    }

    private func togglePause(peer id: String) {
        guard var s = state else { return }
        var paused = s.paused ?? [:]
        let nowPaused = !(paused[id] ?? false)
        paused[id] = nowPaused
        s.paused = paused
        saveState(s)
        state = s
        SwiftServer.shared?.update(state: s)
        reload(force: true)
        if nowPaused { flash("已暂停这台设备的同步") }
    }

    private func flash(_ text: String) {
        headerStatus.update(text: text, color: Theme.amber, fill: Theme.amberWash)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) { [weak self] in
            self?.reload(force: true)
        }
    }

    private func restartServer() {
        server.stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            if let s = self.state { self.server.start(with: s) }
        }
    }

    @objc private func resetPairing() {
        let alert = NSAlert()
        alert.messageText = "重新配对所有手机？"
        alert.informativeText = "会生成新的二维码。已配对的手机需要重新扫码，电脑上的文件不受影响。"
        alert.addButton(withTitle: "重新配对")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard var s = state else { return }
        s.peers = [:]
        saveState(s)
        state = s
        SwiftServer.syncState = [:]
        restartServer()
        refreshQR()
        reload(force: true)
    }
}

// ---------------------------------------------------------------- 入口

final class AppDelegate: NSObject, NSApplicationDelegate {
    var windowController: MainWindowController?

    private var activity: NSObjectProtocol?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 阻止 App Nap 把后台同步降频
        activity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .idleSystemSleepDisabled, .latencyCritical],
            reason: "NetSync 局域网同步服务")
        setupMenuBar()
        windowController = MainWindowController()
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 菜单栏常驻：关掉窗口后服务继续运行，点图标可重新打开窗口。
    private func setupMenuBar() {
        if let old = statusItem { NSStatusBar.system.removeStatusItem(old) }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "arrow.triangle.2.circlepath",
                                   accessibilityDescription: "内网同步")
            button.image?.isTemplate = true
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "打开窗口", action: #selector(openWindow), keyEquivalent: "o")
        open.target = self
        menu.addItem(open)
        let login = NSMenuItem(title: "登录时自动启动", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = loginItemEnabled() ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())
        let address = NSMenuItem(title: "服务：\(lanIP()):\(loadState()?.port ?? 8765)",
                                 action: nil, keyEquivalent: "")
        address.isEnabled = false
        menu.addItem(address)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        item.menu = menu
        statusItem = item
    }

    private var loginPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/com.lvhao.netsync.agent.plist")
    }

    private func loginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: loginPlist.path)
    }

    @objc private func toggleLoginItem() {
        if loginItemEnabled() {
            _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                                 arguments: ["bootout", "gui/\(getuid())", loginPlist.path])
            try? FileManager.default.removeItem(at: loginPlist)
        } else {
            let exe = Bundle.main.bundlePath
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0"><dict>
              <key>Label</key><string>com.lvhao.netsync.agent</string>
              <key>ProgramArguments</key><array>
                <string>/usr/bin/open</string><string>-a</string><string>\(exe)</string>
              </array>
              <key>RunAtLoad</key><true/>
            </dict></plist>
            """
            try? FileManager.default.createDirectory(
                at: loginPlist.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? plist.write(to: loginPlist, atomically: true, encoding: .utf8)
            _ = try? Process.run(URL(fileURLWithPath: "/bin/launchctl"),
                                 arguments: ["bootstrap", "gui/\(getuid())", loginPlist.path])
        }
        setupMenuBar()
    }

    @objc private func openWindow() {
        windowController?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowController?.showWindow(nil) }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // 关窗口只隐藏界面，服务继续在后台跑
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let w = "terminate requested at \(Date())\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/netsync-life.log")) {
            h.seekToEndOfFile(); h.write(w.data(using: .utf8)!); try? h.close()
        }
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        let w = "will terminate at \(Date())\n"
        if let h = try? FileHandle(forWritingTo: URL(fileURLWithPath: "/tmp/netsync-life.log")) {
            h.seekToEndOfFile(); h.write(w.data(using: .utf8)!); try? h.close()
        }
    }
}
