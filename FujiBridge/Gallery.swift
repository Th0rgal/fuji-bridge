import ImageIO
import SwiftUI
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// Downsampled thumbnails of files on disk. Decoding a 40 MP JPEG takes a moment, so tiles decode in
/// parallel off the main thread, and each result is kept in memory and in Caches/Thumbs for next launch.
final class Thumbnails: @unchecked Sendable {
    static let shared = Thumbnails()
    private let memory = NSCache<NSString, UIImage>()
    private let folder: URL = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Thumbs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    /// `persist: false` keeps big viewer decodes in memory only; Caches/Thumbs is for grid sizes.
    func image(for url: URL, pixels: Int = 640, persist: Bool = true) async -> UIImage? {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        let key = "\(url.lastPathComponent)-\(size)-\(pixels)" as NSString
        if let hit = memory.object(forKey: key) { return hit }
        let cached = folder.appendingPathComponent(key as String).appendingPathExtension("jpg")
        let folder = folder
        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            if persist, let data = try? Data(contentsOf: cached), let image = UIImage(data: data) { return image }
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: pixels,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
            let image = UIImage(cgImage: cg)
            if persist && FileManager.default.fileExists(atPath: folder.path) {
                try? image.jpegData(compressionQuality: 0.8)?.write(to: cached, options: .atomic)
            }
            return image
        }.value
        if let image { memory.setObject(image, forKey: key) }
        return image
    }
}

/// Width over height of each file as it is displayed (EXIF orientation applied), read from the header
/// only. The grid needs every ratio before it lays out a row, long before the thumbnails are decoded.
enum ImageRatio {
    /// An X100VI frame in its default 3:2, for anything not read yet.
    static let standard: CGFloat = 3 / 2

    static func load(_ urls: [URL]) async -> [URL: CGFloat] {
        await Task.detached(priority: .userInitiated) {
            var out: [URL: CGFloat] = [:]
            for url in urls {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? CGFloat,
                      let h = props[kCGImagePropertyPixelHeight] as? CGFloat, w > 0, h > 0 else { continue }
                let turned = ((props[kCGImagePropertyOrientation] as? Int) ?? 1) >= 5
                out[url] = turned ? h / w : w / h
            }
            return out
        }.value
    }
}

/// The body's thumbnail is 160x120 whatever the frame, with black bars around anything that is not 4:3,
/// and never rotated. This turns it the way the file says and cuts the bars, so the grid shows the
/// picture at its real shape instead of a letterbox.
enum CameraThumb {
    private static let cache = NSCache<NSString, UIImage>()

    static func image(_ photo: CardPhoto) -> UIImage? {
        let key = "\(photo.handle)-\(photo.name)-\(photo.thumb.count)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let decoded = UIImage(data: photo.thumb)?.cgImage else { return nil }
        let cg = trimmed(decoded) ?? decoded
        let turn: UIImage.Orientation
        switch photo.orientation {
        case 2: turn = .upMirrored
        case 3: turn = .down
        case 4: turn = .downMirrored
        case 5: turn = .leftMirrored
        case 6: turn = .right
        case 7: turn = .rightMirrored
        case 8: turn = .left
        default: turn = .up
        }
        let image = UIImage(cgImage: cg, scale: 1, orientation: turn)
        cache.setObject(image, forKey: key)
        return image
    }

    static func ratio(_ photo: CardPhoto) -> CGFloat {
        guard let image = image(photo), image.size.height > 0 else {
            return photo.orientation >= 5 ? 1 / ImageRatio.standard : ImageRatio.standard
        }
        return image.size.width / image.size.height
    }

    /// Crops matching black bars off opposite edges. Only symmetric bars count, so a dark sky is not a bar.
    private static func trimmed(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 8, h > 8, w * h <= 1_000_000 else { return nil }
        var pixels = [UInt8](repeating: 0, count: w * h * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drew else { return nil }
        func dark(_ x: Int, _ y: Int) -> Bool {
            let i = (y * w + x) * 4
            return max(pixels[i], pixels[i + 1], pixels[i + 2]) < 20
        }
        func darkRow(_ y: Int) -> Bool { (0..<w).allSatisfy { dark($0, y) } }
        func darkColumn(_ x: Int) -> Bool { (0..<h).allSatisfy { dark(x, $0) } }
        var top = 0, bottom = 0, left = 0, right = 0
        while top < h / 3, darkRow(top) { top += 1 }
        while bottom < h / 3, darkRow(h - 1 - bottom) { bottom += 1 }
        while left < w / 3, darkColumn(left) { left += 1 }
        while right < w / 3, darkColumn(w - 1 - right) { right += 1 }
        let rows = top >= 2 && abs(top - bottom) <= 2
        let columns = left >= 2 && abs(left - right) <= 2
        guard rows || columns else { return nil }
        let rect = CGRect(
            x: columns ? left : 0, y: rows ? top : 0,
            width: w - (columns ? left + right : 0), height: h - (rows ? top + bottom : 0)
        )
        return image.cropping(to: rect)
    }
}

/// Rows of photos at their own shape, each row stretched to the full width (the Photos "aspect ratio"
/// grid). Landscape and portrait frames sit side by side with no bars. Rows are lazy, so a card of a
/// thousand frames only decodes what is on screen.
struct JustifiedGrid<Item: Identifiable, Tile: View>: View {
    let items: [Item]
    let ratio: (Item) -> CGFloat
    var rowHeight: CGFloat = 180
    var spacing: CGFloat = 4
    @ViewBuilder let tile: (Item, CGSize) -> Tile
    @State private var width: CGFloat = 0

    private struct Row: Identifiable {
        let id: Item.ID
        let items: [(Item, CGFloat)]
        let height: CGFloat
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: spacing) {
            ForEach(rows) { row in
                HStack(spacing: spacing) {
                    ForEach(row.items, id: \.0.id) { item, ratio in
                        let size = CGSize(width: (row.height * ratio).rounded(.down), height: row.height)
                        tile(item, size).frame(width: size.width, height: size.height)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { width = geo.size.width }
                    .onChange(of: geo.size.width) { _, new in width = new }
            }
        )
    }

    private var rows: [Row] {
        guard width > 0 else { return [] }
        var out: [Row] = []
        var current: [(Item, CGFloat)] = []
        var sum: CGFloat = 0
        for item in items {
            let r = min(max(ratio(item), 0.4), 3)
            current.append((item, r))
            sum += r
            let height = (width - spacing * CGFloat(current.count - 1)) / sum
            if height <= rowHeight, let first = current.first {
                out.append(Row(id: first.0.id, items: current, height: height.rounded(.down)))
                current = []
                sum = 0
            }
        }
        // The last row keeps the target height instead of blowing up a lone frame to the full width.
        if let first = current.first {
            let height = (width - spacing * CGFloat(current.count - 1)) / sum
            out.append(Row(id: first.0.id, items: current, height: min(height, rowHeight).rounded(.down)))
        }
        return out
    }
}

/// One picture in the grid. No caption under it: the name shows on hover and in the menu.
struct PhotoTile<Badge: View>: View {
    let image: UIImage?
    let title: String
    let caption: String
    var selected = false
    /// Decoding gave up: show a mark instead of a spinner that never ends.
    var failed = false
    @ViewBuilder var badge: Badge
    @State private var hovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Ink.photoCorner, style: .continuous)
        ZStack {
            Ink.surface2
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            } else if failed {
                Image(systemName: "photo")
                    .font(.system(size: 20, weight: .light))
                    .foregroundStyle(Ink.muted)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(shape)
        .overlay(alignment: .bottomLeading) {
            if hovering {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Ink.mono(11, .medium))
                    Text(caption).font(Ink.mono(10))
                }
                .lineLimit(1)
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom))
                .clipShape(shape)
                .allowsHitTesting(false)
            }
        }
        .overlay {
            if selected {
                ZStack {
                    shape.fill(Color.black.opacity(0.12))
                    shape.strokeBorder(Ink.ink, lineWidth: 3)
                    shape.inset(by: 3).strokeBorder(Ink.paper, lineWidth: 1.5)
                }
                .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if selected {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 20))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Ink.paper, Ink.ink)
                    .padding(6)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottomTrailing) { badge.padding(6).allowsHitTesting(false) }
        .animation(.easeOut(duration: 0.15), value: image != nil)
        .animation(.easeOut(duration: 0.1), value: selected)
        .contentShape(shape)
        .onHover { hovering = $0 }
        .help("\(title) · \(caption)")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(caption)
        .accessibilityAddTraits(selected ? [.isImage, .isSelected] : .isImage)
    }
}

/// A file in the photos folder, decoded lazily as it scrolls in.
struct LocalTile: View {
    let url: URL
    var selected = false
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        PhotoTile(image: image, title: url.lastPathComponent, caption: size, selected: selected, failed: failed) { EmptyView() }
            .task(id: url) {
                image = await Thumbnails.shared.image(for: url)
                failed = image == nil
            }
    }

    private var size: String {
        let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        return ByteFormat.string(bytes)
    }
}

/// A frame on the camera, from the browse: the body's own thumbnail, bars cut.
struct CameraTile: View {
    let photo: CardPhoto
    let selected: Bool
    let imported: Bool

    var body: some View {
        let image = CameraThumb.image(photo)
        PhotoTile(image: image, title: photo.name, caption: caption, selected: selected, failed: image == nil) {
            if imported && !selected {
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 18, height: 18)
                    .background(Ink.good, in: Circle())
                    .overlay(Circle().strokeBorder(.white.opacity(0.9), lineWidth: 1))
            }
        }
        .opacity(imported && !selected ? 0.72 : 1)
    }

    private var caption: String {
        var parts = [ByteFormat.string(photo.bytes)]
        if let date = CaptureDate.short(photo.captured) { parts.insert(date, at: 0) }
        if imported { parts.append("imported") }
        return parts.joined(separator: " · ")
    }
}

/// Finder's rules for a click in a grid: plain replaces, Command toggles, Shift adds the run from the
/// last clicked item. A phone has no modifier keys, so there a plain tap toggles.
enum SelectionClick {
    enum Kind { case plain, command, shift }

    static func apply<ID: Hashable>(_ kind: Kind, id: ID, order: [ID], selection: inout Set<ID>, anchor: inout ID?, plainToggles: Bool) {
        switch kind {
        case .command:
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            anchor = id
        case .shift:
            guard let from = anchor.flatMap({ order.firstIndex(of: $0) }), let to = order.firstIndex(of: id) else {
                selection.insert(id)
                anchor = id
                return
            }
            selection.formUnion(order[min(from, to)...max(from, to)])
        case .plain:
            if plainToggles {
                if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
            } else {
                selection = selection == [id] ? [] : [id]
            }
            anchor = id
        }
    }
}

extension View {
    /// Click, Command-click, Shift-click and (on the Mac) double-click, each to its own action.
    func selectable(open: (() -> Void)? = nil, click: @escaping (SelectionClick.Kind) -> Void) -> some View {
        modifier(SelectableTile(open: open, click: click))
    }
}

private struct SelectableTile: ViewModifier {
    let open: (() -> Void)?
    let click: (SelectionClick.Kind) -> Void

    func body(content: Content) -> some View {
        let single = TapGesture().onEnded { click(ModifierKeys.kind) }
        if Ink.isMac, let open {
            return AnyView(content.gesture(TapGesture(count: 2).onEnded { open() }.exclusively(before: single)))
        }
        return AnyView(content.gesture(single))
    }
}

/// SwiftUI taps carry no modifier keys on iOS or Catalyst. A recognizer on the window that never
/// recognizes anything notes which keys were down when each click or touch began, for the tap to read.
enum ModifierKeys {
    @MainActor fileprivate static var flags: UIKeyModifierFlags = []

    @MainActor static var kind: SelectionClick.Kind {
        if flags.contains(.command) { return .command }
        if flags.contains(.shift) { return .shift }
        return .plain
    }

    /// Put once anywhere in the window.
    struct Listener: UIViewRepresentable {
        func makeUIView(context: Context) -> UIView { Installer() }
        func updateUIView(_ uiView: UIView, context: Context) {}
    }

    private final class Installer: UIView {
        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard let window, !(window.gestureRecognizers ?? []).contains(where: { $0 is Sniffer }) else { return }
            window.addGestureRecognizer(Sniffer())
        }
    }

    private final class Sniffer: UIGestureRecognizer, UIGestureRecognizerDelegate {
        init() {
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
            delegate = self
        }

        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            ModifierKeys.flags = event.modifierFlags
            state = .failed
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
    }
}

enum CaptureDate {
    /// "20260924T195324" to "24 Sep 19:53".
    static func short(_ raw: String?) -> String? {
        guard let raw, raw.count >= 13 else { return nil }
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyyMMdd'T'HHmmss"
        guard let date = parser.date(from: String(raw.prefix(15))) else { return nil }
        return date.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }
}

#if DEBUG
/// `-BridgeDemoCard` fills "On the camera" from the photos folder, thumbnails made the way the body makes
/// them (160x120, bars and all), so the grid can be looked at without a camera.
enum DemoCard {
    static func photos(from urls: [URL]) -> [CardPhoto] {
        urls.prefix(40).enumerated().compactMap { index, url in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: 160,
                  ] as CFDictionary) else { return nil }
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: 160, height: 120), format: {
                let format = UIGraphicsImageRendererFormat()
                format.scale = 1
                return format
            }())
            let thumb = renderer.jpegData(withCompressionQuality: 0.8) { context in
                UIColor.black.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 160, height: 120))
                let w = CGFloat(cg.width), h = CGFloat(cg.height)
                let scale = min(160 / w, 120 / h)
                let rect = CGRect(x: (160 - w * scale) / 2, y: (120 - h * scale) / 2, width: w * scale, height: h * scale)
                UIImage(cgImage: cg).draw(in: rect)
            }
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
            let captured = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
                .map { $0.replacingOccurrences(of: ":", with: "").replacingOccurrences(of: " ", with: "T") }
            return CardPhoto(
                handle: 1000 + index,
                name: index % 3 == 0 ? url.lastPathComponent : "DSCF\(9000 + index).JPG",
                bytes: bytes,
                captured: captured,
                thumb: thumb,
                orientation: (props[kCGImagePropertyOrientation] as? Int) ?? 1
            )
        }
    }
}
#endif
