import ImageIO
import SwiftUI
import UIKit

struct IPlexArchiveAppearance {
    let title: String
    let text: Color
    let accent: Color
    let tint: Color?
    let density: Double

    var muted: Color { text.opacity(0.73) }
}

private struct IPlexArchiveAppearanceKey: EnvironmentKey {
    static let defaultValue = IPlexArchiveAppearance(title: "Tool Drive", text: .white,
                                                     accent: .cyan, tint: nil, density: 0.6)
}

extension EnvironmentValues {
    var iplexArchiveAppearance: IPlexArchiveAppearance {
        get { self[IPlexArchiveAppearanceKey.self] }
        set { self[IPlexArchiveAppearanceKey.self] = newValue }
    }
}

enum MobileTheme: String, CaseIterable, Identifiable {
    case frontRow = "front-row", nightShift = "night-shift", graphite
    case laserGrid = "laser-grid", liquidGlass = "liquid-glass", oledDark = "oled-dark"

    #if os(tvOS)
    static let selectableThemes: [Self] = [.liquidGlass, .oledDark]
    #else
    static let selectableThemes = allCases
    #endif

    var id: String { rawValue }
    var usesGlass: Bool {
        self == .liquidGlass || self == .oledDark
    }

    var title: String {
        switch self {
        case .frontRow: return "Front Row"
        case .nightShift: return "Night Shift"
        case .graphite: return "Graphite"
        case .laserGrid: return "Laser Grid"
        case .liquidGlass: return "Liquid Glass"
        case .oledDark: return "OLED Dark"
        }
    }

    // The desktop themes use these same sRGB surface, type and accent colors.
    private var palette: ThemePalette {
        switch self {
        case .frontRow: return .frontRow
        case .nightShift: return .nightShift
        case .graphite: return .graphite
        case .laserGrid: return .laserGrid
        case .liquidGlass: return .liquidGlass
        case .oledDark: return .oledDark
        }
    }
    var page: Color { palette.page }
    var panel: Color { palette.panel }
    var raised: Color { palette.raised }
    var text: Color { palette.text }
    var muted: Color { palette.muted }
    var line: Color { palette.line }
    var accent: Color { palette.accent }
    var ink: Color { palette.ink }
    var cornerRadius: CGFloat {
        switch self {
        case .frontRow, .nightShift: return 5
        case .laserGrid: return 3
        case .graphite: return 9
        case .liquidGlass, .oledDark: return 20
        }
    }
}

extension Color {
    init(archiveRGB rgb: Int) {
        self.init(.sRGB, red: Double((rgb >> 16) & 255) / 255,
                  green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
}

private struct ThemePalette {
    let page, panel, raised, text, muted, line, accent, ink: Color
    init(page: Int, panel: Int, raised: Int, text: Int, muted: Int, line: Int, accent: Int, ink: Int) {
        self.page = Color(archiveRGB: page)
        self.panel = Color(archiveRGB: panel)
        self.raised = Color(archiveRGB: raised)
        self.text = Color(archiveRGB: text)
        self.muted = Color(archiveRGB: muted)
        self.line = Color(archiveRGB: line)
        self.accent = Color(archiveRGB: accent)
        self.ink = Color(archiveRGB: ink)
    }
    static let frontRow = Self(page: 0x101210, panel: 0x191c18, raised: 0x242820, text: 0xf4f4e9, muted: 0xced1c2, line: 0x383e33, accent: 0xd5f642, ink: 0x171a12)
    static let nightShift = Self(page: 0x1a191b, panel: 0x262528, raised: 0x373538, text: 0xf7eee3, muted: 0xd2c3b5, line: 0x4b4545, accent: 0xffac64, ink: 0x21140c)
    static let graphite = Self(page: 0x121515, panel: 0x191d1d, raised: 0x222727, text: 0xe9eae5, muted: 0xa5afaa, line: 0x343c3b, accent: 0xe8b25d, ink: 0x191b17)
    static let laserGrid = Self(page: 0x071312, panel: 0x101f1c, raised: 0x193029, text: 0xeef8f0, muted: 0xc0d2ca, line: 0x315048, accent: 0x9bffbd, ink: 0x092016)
    static let liquidGlass = Self(page: 0x0a1025, panel: 0x182440, raised: 0x263658, text: 0xf3f7ff, muted: 0xd5ddea, line: 0x435477, accent: 0xa3eddc, ink: 0x0a292e)
    static let oledDark = Self(page: 0x000000, panel: 0x111316, raised: 0x191c20, text: 0xf4f6fa, muted: 0xb8c0cb, line: 0x3a424d, accent: 0xe0e8f5, ink: 0x101318)
}

enum MobileLogo: String, CaseIterable, Identifiable {
    case classic, era2006 = "2006", opiate, opiate2, fearInoculum = "fear-inoculum"
    case multicolor, marbled, spectrum, block, sawblade, reflection, framed
    case orbit, `static`, erosion, afterimage, lightTrail = "light-trail", flare
    case blueMist = "blue-mist", era1992 = "1992", aenima, bone

    var id: String { rawValue }
    var title: String {
        switch self {
        case .era2006: return "2006"
        case .opiate2: return "Opiate²"
        case .fearInoculum: return "Fear Inoculum"
        case .lightTrail: return "Light Trail"
        case .blueMist: return "Blue Mist"
        case .era1992: return "1992"
        case .aenima: return "Ænima"
        default: return rawValue.capitalized
        }
    }
    var usesThemeTint: Bool { self == .classic || self == .era2006 }
    var resourceName: String { (usesThemeTint ? "tool-logo-" : "logo-") + rawValue }
}

enum FrontRowPicture: String, CaseIterable, Identifiable {
    case blueSilhouette = "blue-silhouette", governorsBall = "governors-ball"
    var id: String { rawValue }
    var title: String { self == .blueSilhouette ? "Blue Silhouette" : "Governors Ball" }
}

#if !LEGACY_IOS
private struct MobileThemeKey: EnvironmentKey {
    static let defaultValue = MobileTheme.frontRow
}
private struct MobileGlassControlsKey: EnvironmentKey {
    static let defaultValue = false
}
private struct WallpaperWindowKey: EnvironmentKey {
    static let defaultValue: CGRect? = nil
}
private struct HomeWallpaperKey: EnvironmentKey {
    static let defaultValue = HomeScreenPreferences()
}
private struct CustomBackgroundKey: EnvironmentKey {
    static let defaultValue: UUID? = nil
}
extension EnvironmentValues {
    var homeWallpaper: HomeScreenPreferences {
        get { self[HomeWallpaperKey.self] }
        set { self[HomeWallpaperKey.self] = newValue }
    }
    var customBackground: UUID? {
        get { self[CustomBackgroundKey.self] }
        set { self[CustomBackgroundKey.self] = newValue }
    }
    var mobileTheme: MobileTheme {
        get { self[MobileThemeKey.self] }
        set { self[MobileThemeKey.self] = newValue }
    }
    var mobileGlassControls: Bool {
        get { self[MobileGlassControlsKey.self] }
        set { self[MobileGlassControlsKey.self] = newValue }
    }
    fileprivate var wallpaperWindow: CGRect? {
        get { self[WallpaperWindowKey.self] }
        set { self[WallpaperWindowKey.self] = newValue }
    }
}

extension View {
    func archiveWindowCanvas() -> some View { modifier(ArchiveWindowCanvas()) }
    func archivePage(wallpaperID: String, sharesWindow: Bool = false) -> some View {
        modifier(ArchivePage(wallpaperID: wallpaperID, sharesWindow: sharesWindow))
    }
    func archivePanel() -> some View { modifier(ArchiveSurface(control: false)) }
    func archiveControl(cornerRadius: CGFloat? = nil) -> some View { modifier(ArchiveSurface(control: true, cornerRadius: cornerRadius)) }
}

private struct ArchiveWindowCanvas: ViewModifier {
    @Environment(\.layoutDirection) private var direction

    func body(content: Content) -> some View {
        GeometryReader { proxy in
            let frame = proxy.frame(in: .global), insets = proxy.safeAreaInsets
            let left = direction == .leftToRight ? insets.leading : insets.trailing
            let bounds = CGRect(x: frame.minX - left, y: frame.minY - insets.top,
                                width: frame.width + insets.leading + insets.trailing,
                                height: frame.height + insets.top + insets.bottom)
            content.environment(\.wallpaperWindow, bounds)
        }
    }
}

private struct ArchivePage: ViewModifier {
    @Environment(\.archiveAccent) private var accent
    @Environment(\.iplexArchiveAppearance) private var appearance
    @Environment(\.accessibilityReduceTransparency) private var solid
    var wallpaperID: String
    var sharesWindow: Bool

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .scrollContentBackground(.hidden)
            #endif
            .background {
                if !sharesWindow {
                    ZStack {
                        Color(archiveRGB: 0x152037).opacity(solid ? 1 : 0.6)
                        if !solid, let tint = appearance.tint {
                            tint.opacity(0.07 + 0.12 * appearance.density)
                        }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                }
            }
            .foregroundStyle(appearance.text, appearance.muted)
            .tint(accent)
    }
}

private struct ArchiveSurface: ViewModifier {
    @Environment(\.glassOpacity) private var opacity
    @Environment(\.mobileTheme) private var theme
    @Environment(\.mobileGlassControls) private var glassControls
    @Environment(\.accessibilityReduceTransparency) private var solid
    @Environment(\.colorSchemeContrast) private var contrast
    let control: Bool
    var cornerRadius: CGFloat? = nil

    @ViewBuilder func body(content: Content) -> some View {
        let glass = theme.usesGlass || (control && glassControls)
        let shape = RoundedRectangle(cornerRadius: cornerRadius ?? (glass && control ? 22 : theme.cornerRadius), style: .continuous)
        if glass && !solid {
            if control, #available(iOS 26, tvOS 26, *) {
                content.background {
                    Color.clear
                        .glassEffect(.regular, in: shape)
                        .opacity(opacity.amount(1, min: 0.54, max: 1))
                        .overlay { shape.fill(theme.page.opacity(opacity.amount(0, min: 0, max: 0.85))) }
                        .allowsHitTesting(false)
                }
            } else {
                content
                    .background(theme.page.opacity(control ? opacity.amount(0.23, min: 0.10, max: 0.91)
                                                         : opacity.amount(0.45, min: 0.14, max: 0.96)), in: shape)
                    .background {
                        shape.fill(.regularMaterial)
                            .opacity(opacity.amount(1, min: 0.52, max: 1))
                    }
                    .overlay {
                        shape.strokeBorder(.white.opacity(contrast == .increased ? 0.55 : 0.24))
                            .allowsHitTesting(false)
                    }
            }
        } else {
            content.background(control ? theme.raised : theme.panel, in: shape)
                .overlay {
                    shape.strokeBorder(contrast == .increased ? theme.muted : theme.line)
                        .allowsHitTesting(false)
                }
        }
    }
}

struct ArchiveRowBackground: View {
    @Environment(\.iplexArchiveAppearance) private var appearance
    @Environment(\.glassOpacity) private var opacity
    @Environment(\.archiveAccent) private var accent
    @Environment(\.mobileTheme) private var theme
    @Environment(\.accessibilityReduceTransparency) private var solid
    var selected = false

    var body: some View {
        ZStack {
            if theme == .liquidGlass && !solid {
                Rectangle().fill(.thinMaterial)
                    .opacity(opacity.amount(0.55, min: 0.28, max: 0.86))
                if let tint = appearance.tint {
                    tint.opacity(0.06 + 0.13 * appearance.density)
                }
                LinearGradient(colors: [.white.opacity(0.10), .clear], startPoint: .top, endPoint: .bottom)
            } else {
                theme.panel
            }
            if selected { accent.opacity(0.17) }
        }
        .allowsHitTesting(false)
    }
}

struct ArchiveBrandLogo: View {
    let logo: MobileLogo
    private static let images = Dictionary(uniqueKeysWithValues: MobileLogo.allCases.compactMap { logo -> (MobileLogo, UIImage)? in
        guard let url = Bundle.main.url(forResource: logo.resourceName, withExtension: "png", subdirectory: "ToolDrive/ThemeArt"),
              let image = UIImage(contentsOfFile: url.path) else { return nil }
        return (logo, image)
    })

    var body: some View {
        Group {
            if let image = Self.images[logo] {
                Image(uiImage: image).resizable()
                    .renderingMode(logo.usesThemeTint ? .template : .original)
                    .scaledToFit()
            } else {
                Text("TOOL").font(.headline)
            }
        }
    }
}

private struct StagePhoto: View {
    var name: String
    var anchor: UnitPoint
    @State private var image: UIImage?
    private static let cache = NSCache<NSString, UIImage>()

    var body: some View {
        GeometryReader { geometry in
            if let image {
                let size = geometry.size
                let scale = max(size.width / image.size.width, size.height / image.size.height)
                let w = image.size.width * scale, h = image.size.height * scale
                Image(uiImage: image).resizable().frame(width: w, height: h)
                    .position(x: w / 2 + (size.width - w) * anchor.x, y: h / 2 + (size.height - h) * anchor.y)
            }
        }
        .clipped()
        .task(id: name) {
            if let cached = Self.cache.object(forKey: name as NSString) { image = cached; return }
            let filename = name
            let photo = await Task.detached(priority: .userInitiated) { () -> CGImage? in
                guard let url = Bundle.main.url(forResource: filename, withExtension: "jpg", subdirectory: "ToolDrive/ThemeArt"),
                      let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
                let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                               kCGImageSourceCreateThumbnailWithTransform: true,
                                               kCGImageSourceThumbnailMaxPixelSize: 1500,
                                               kCGImageSourceShouldCacheImmediately: true]
                return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
            }.value
            guard !Task.isCancelled, let photo else { return }
            let decoded = UIImage(cgImage: photo)
            Self.cache.setObject(decoded, forKey: filename as NSString)
            image = decoded
        }
    }
}

struct ArchiveThemeArtwork: View {
    let theme: MobileTheme
    let picture: FrontRowPicture
    let wallpaperID: String

    var body: some View {
        ZStack {
            theme.page
            switch theme {
            case .frontRow:
                StagePhoto(name: picture.rawValue, anchor: picture == .blueSilhouette ? UnitPoint(x: 0.5, y: 0.24) : UnitPoint(x: 0.5, y: 0.6))
            case .laserGrid:
                GeometryReader { geometry in
                    let w = geometry.size.width, h = geometry.size.height
                    Canvas { context, size in
                        var path = Path()
                        for x in stride(from: 0, through: size.width, by: 25) {
                            path.move(to: CGPoint(x: x, y: 0)); path.addLine(to: CGPoint(x: x, y: size.height))
                        }
                        for y in stride(from: 0, through: size.height, by: 25) {
                            path.move(to: CGPoint(x: 0, y: y)); path.addLine(to: CGPoint(x: size.width, y: y))
                        }
                        context.stroke(path, with: .color(theme.muted.opacity(0.17)), lineWidth: 0.7)
                    }
                    StagePhoto(name: "laser-grid", anchor: UnitPoint(x: 0.56, y: 0.82))
                        .frame(width: w * 0.63, height: h)
                        .clipShape(LaserPhotoEdge())
                        .position(x: w * 0.685, y: h / 2)
                }
            case .graphite:
                GeometryReader { geo in
                    let size = min(geo.size.width * 0.44, geo.size.height * 0.84)
                    ZStack {
                        ForEach(0..<5) { index in
                            let scale = 1 - CGFloat(index) * 0.19
                            Ellipse().stroke(theme.accent.opacity(0.43), lineWidth: 1)
                                .frame(width: size * 1.15 * scale, height: size * 0.86 * scale)
                                .rotationEffect(.degrees(-28))
                        }
                        Circle().fill(theme.accent).frame(width: 6, height: 6)
                    }
                    .position(x: geo.size.width * 0.78, y: geo.size.height * 0.5)
                }
            case .nightShift:
                LinearGradient(colors: [Color(archiveRGB: 0x484648), Color(archiveRGB: 0x312f30), Color(archiveRGB: 0x232324)], startPoint: .topLeading, endPoint: .bottomTrailing)
                Canvas { context, size in
                    for x in [CGFloat(9), size.width - 9] {
                        for y in [CGFloat(9), size.height - 9] {
                            let screw = CGRect(x: x - 2.7, y: y - 2.7, width: 5.4, height: 5.4)
                            context.fill(Path(ellipseIn: screw), with: .color(.black.opacity(0.64)))
                            var slot = Path()
                            slot.move(to: CGPoint(x: x - 1.5, y: y + 1.5)); slot.addLine(to: CGPoint(x: x + 1.5, y: y - 1.5))
                            context.stroke(slot, with: .color(.white.opacity(0.33)), lineWidth: 1)
                        }
                    }
                }
            case .liquidGlass:
                ArchiveWallpaper(id: wallpaperID)
            case .oledDark:
                LinearGradient(stops: [
                    .init(color: theme.raised, location: 0),
                    .init(color: theme.panel, location: 0.44),
                    .init(color: theme.page, location: 0.88)
                ], startPoint: .topLeading, endPoint: .bottomTrailing)
            }
        }
        .clipped().accessibilityHidden(true).allowsHitTesting(false)
    }
}

private struct LaserPhotoEdge: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.width * 0.1, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: 0))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.addLine(to: CGPoint(x: 0, y: rect.maxY))
            path.closeSubpath()
        }
    }
}

struct ArchiveThemeMasthead: View {
    @Environment(\.glassOpacity) private var opacity
    @Environment(\.archiveAccent) private var accent
    let theme: MobileTheme
    let logo: MobileLogo
    let picture: FrontRowPicture
    let wallpaperID: String
    let logoSize: HomeScreenPreferences.Logo
    @Environment(\.accessibilityReduceTransparency) private var solid

    var body: some View {
        let mask = RoundedRectangle(cornerRadius: theme.cornerRadius, style: .continuous)
        VStack(spacing: 9) {
            if logoSize != .hidden { mark }
            Text("Drive Project")
                .font(.system(.title3, weight: theme == .frontRow ? .black : .bold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(17)
        .foregroundStyle(theme.text)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                if theme == .liquidGlass && !solid {
                    // A continuous concert image already sits behind the complete page.
                    LinearGradient(colors: [theme.page.opacity(opacity.amount(0.68, min: 0.36, max: 0.97)),
                                            theme.page.opacity(opacity.amount(0.16, min: 0.06, max: 0.86))], startPoint: .leading, endPoint: .trailing)
                } else if theme == .liquidGlass {
                    theme.panel
                } else {
                    ArchiveThemeArtwork(theme: theme, picture: picture, wallpaperID: wallpaperID)
                    if [.frontRow, .laserGrid, .liquidGlass].contains(theme) {
                        LinearGradient(stops: [
                            .init(color: .black.opacity(0.92), location: 0),
                            .init(color: .black.opacity(0.72), location: 0.39),
                            .init(color: .black.opacity(0.17), location: 0.85)
                        ], startPoint: .leading, endPoint: .trailing)
                    }
                }
            }
        }
        .clipShape(mask)
        .overlay { mask.strokeBorder(theme.line, lineWidth: theme == .frontRow ? 0 : 1).allowsHitTesting(false) }
        .overlay(alignment: .top) {
            if theme == .laserGrid { Rectangle().fill(accent).frame(height: 2).allowsHitTesting(false) }
        }
    }

    private var mark: some View {
        ArchiveBrandLogo(logo: logo)
            .foregroundStyle(theme.text)
            .frame(height: (logo.usesThemeTint ? 31 : 41) * logoSize.scale)
            .frame(maxWidth: (logo.usesThemeTint ? (logo == .classic ? 112 : 139) : 164) * logoSize.scale)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("TOOL, " + logo.title + " logo")
            .accessibilityIdentifier("catalog.logo." + logo.rawValue)
    }


}

// Seven-segment values mirror the desktop Night Shift counter and sound meters.
struct ArchiveNumberDisplay: View {
    let value: String
    private static let masks = [63, 6, 91, 79, 102, 109, 125, 7, 127, 111]
    private static let segments: [[CGPoint]] = [
        [p(2,0),p(12,0),p(14,2),p(12,4),p(3,4),p(0,2)],
        [p(12,4),p(14,2),p(14,11),p(12,13),p(10,11),p(10,6)],
        [p(12,13),p(14,15),p(14,22),p(12,24),p(10,22),p(10,15)],
        [p(3,21),p(11,21),p(13,23),p(11,25),p(2,25),p(0,23)],
        [p(0,15),p(2,13),p(4,15),p(4,20),p(2,23),p(0,21)],
        [p(0,3),p(2,3),p(4,5),p(4,10),p(2,12),p(0,10)],
        [p(3,10.5),p(11,10.5),p(13,12.5),p(11,14.5),p(3,14.5),p(1,12.5)]
    ]
    private static func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x, y: y) }
    private var width: CGFloat { value.reduce(CGFloat(0)) { $0 + ($1 == "." ? 6 : 17) } }

    var body: some View {
        Canvas { context, size in
            let scale = min(size.width / max(width, 1), size.height / 25)
            context.scaleBy(x: scale, y: scale)
            let on = GraphicsContext.Shading.color(Color(archiveRGB: 0xff9f4b))
            let off = GraphicsContext.Shading.color(Color(archiveRGB: 0x45271b))
            for c in value {
                if c == "." {
                    context.fill(Path(ellipseIn: CGRect(x: 0, y: 21.5, width: 3.5, height: 3.5)), with: on)
                    context.translateBy(x: 6, y: 0)
                } else if let digit = c.wholeNumberValue, digit < 10 {
                    for (index, points) in Self.segments.enumerated() {
                        var path = Path()
                        path.addLines(points)
                        path.closeSubpath()
                        context.fill(path, with: Self.masks[digit] & (1 << index) == 0 ? off : on)
                    }
                    context.translateBy(x: 17, y: 0)
                }
            }
        }
        .aspectRatio(width / 25, contentMode: .fit)
        .accessibilityHidden(true)
    }
}
#endif
