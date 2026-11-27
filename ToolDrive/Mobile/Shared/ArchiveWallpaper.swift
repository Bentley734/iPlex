import ImageIO
import SwiftUI
import UIKit

private actor WallpaperPhotos {
    static let shared = WallpaperPhotos()
    private let cache = NSCache<NSString, CGImage>()

    init() {
        cache.countLimit = 3
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    func image(for id: String, file: URL?) -> CGImage? {
        let key = id as NSString
        if let photo = cache.object(forKey: key) { return photo }
        guard !Task.isCancelled,
              let url = file ?? Bundle.main.url(forResource: id, withExtension: "jpg", subdirectory: "ToolDrive/Wallpapers"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        #if os(tvOS)
        let maximum = 2400
        #else
        let maximum = 1600
        #endif
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                       kCGImageSourceCreateThumbnailWithTransform: true,
                                       kCGImageSourceThumbnailMaxPixelSize: maximum,
                                       kCGImageSourceShouldCacheImmediately: true]
        guard let photo = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        cache.setObject(photo, forKey: key, cost: photo.bytesPerRow * photo.height)
        return photo
    }
}

struct ArchiveWallpaper: View {
    let id: String
    var file: URL? = nil
    @State private var photograph: CGImage?
    @Environment(\.homeWallpaper) private var home

    // Preserve the Mac theme's focal point when a tall or shallow pane crops the concert.
    private var focus: UnitPoint {
        switch home.framing {
        case .center: return .center
        case .top: return .top
        case .bottom: return .bottom
        case .automatic: break
        }
        switch id {
        case "crimson-current": return UnitPoint(x: 0.55, y: 0.53)
        case "emerald-lasers": return UnitPoint(x: 0.48, y: 0.66)
        case "blue-heptagram": return UnitPoint(x: 0.54, y: 0.68)
        case "magenta-silhouette": return UnitPoint(x: 0.62, y: 0.48)
        case "faces-in-fire": return UnitPoint(x: 0.53, y: 0.70)
        case "gilded-wings": return UnitPoint(x: 0.64, y: 0.87)
        case "violet-anatomy": return UnitPoint(x: 0.51, y: 0.63)
        case "prism-beams": return UnitPoint(x: 0.44, y: 0.53)
        case "scarlet-star": return UnitPoint(x: 0.52, y: 0.65)
        default: return .center
        }
    }

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack {
                Color(red: 0.08, green: 0.10, blue: 0.16)
                if let photograph {
                    let w = CGFloat(photograph.width), h = CGFloat(photograph.height)
                    let scale = max(size.width / w, size.height / h)
                    let drawn = CGSize(width: w * scale, height: h * scale)
                    Image(decorative: photograph, scale: 1).resizable()
                        .frame(width: drawn.width, height: drawn.height)
                        .position(x: drawn.width / 2 + (size.width - drawn.width) * focus.x,
                                  y: drawn.height / 2 + (size.height - drawn.height) * focus.y)
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
        .task(id: id) {
            let decoded = await WallpaperPhotos.shared.image(for: id, file: file)
            guard !Task.isCancelled else { return }
            photograph = decoded
        }
    }
}
