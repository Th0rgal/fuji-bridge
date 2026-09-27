import ImageIO
import SwiftUI
import UIKit

/// One photo in the viewer: a file already imported, or a frame still on the card.
enum ViewerItem: Identifiable, Equatable {
    case local(URL)
    case camera(CardPhoto)

    var id: String {
        switch self {
        case .local(let url): return url.path
        case .camera(let photo): return "camera-\(photo.handle)"
        }
    }

    var name: String {
        switch self {
        case .local(let url): return url.lastPathComponent
        case .camera(let photo): return photo.name
        }
    }
}

/// Full-window viewer over the grid. Arrow keys, swipes and the side buttons move through the same
/// photos the grid shows; Space or Escape close it (the keys live with the other shortcuts in HomeView).
/// Imported files decode at screen size; frames on the card show the camera's thumbnail until their
/// full-size copy is fetched (by itself over USB, on F or the button over Wi-Fi).
struct PhotoViewer: View {
    let items: [ViewerItem]
    let index: Int
    let model: BenchModel
    let selected: Bool
    let move: (Int) -> Void
    let toggle: () -> Void
    let close: () -> Void

    @State private var image: UIImage?
    @State private var sharp = false
    @State private var dimensions: CGSize?

    private var item: ViewerItem { items[index] }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
                .onTapGesture { close() }
            ZoomableImage(image: image, onSwipe: move)
                .id(item.id)
                .padding(.vertical, 56)
            sideButtons
            VStack(spacing: 0) {
                topBar
                Spacer()
                bottomBar
            }
        }
        .foregroundStyle(.white)
        .task(id: item.id) { await load() }
        .task(id: fullSizeKey) { await loadFullSize() }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 12) {
            Text(item.name)
                .font(Ink.mono(13, .medium))
            Text("\(index + 1) / \(items.count)")
                .font(Ink.mono(12))
                .foregroundStyle(.white.opacity(0.6))
                .monospacedDigit()
            Spacer()
            circleButton("xmark", help: "Close (Esc)") { close() }
        }
        .padding(.horizontal, 18)
        .padding(.top, 12)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Text(caption)
                .font(Ink.mono(12))
                .foregroundStyle(.white.opacity(0.7))
                .lineLimit(1)
            Spacer(minLength: 8)
            if case .camera(let photo) = item {
                fullSizeControl(photo)
            }
            if case .local(let url) = item {
                ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                    .buttonStyle(.plain)
                    .help("Share")
            }
            Button(action: toggle) {
                Label(selected ? "Selected" : "Select", systemImage: selected ? "checkmark.circle.fill" : "circle")
                    .font(Ink.prose(13, .medium))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(.white.opacity(selected ? 0.22 : 0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .help("Select (Return)")
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 14)
    }

    @ViewBuilder
    private func fullSizeControl(_ photo: CardPhoto) -> some View {
        if model.fetchingFullSize == photo.handle {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(.white)
                Text("Fetching full size").font(Ink.prose(12))
            }
        } else if sharp {
            Label("Full size", systemImage: "checkmark").font(Ink.prose(12)).foregroundStyle(.white.opacity(0.7))
        } else {
            Button { model.fetchFullSize(photo) } label: {
                Label("Full size · \(ByteFormat.string(photo.bytes))", systemImage: "arrow.down.circle")
                    .font(Ink.prose(12, .medium))
            }
            .buttonStyle(.plain)
            .disabled(model.busy)
            .help("Fetch the whole file from the camera (F)")
        }
    }

    private var sideButtons: some View {
        HStack {
            circleButton("chevron.left", help: "Previous (←)") { move(-1) }
                .opacity(index > 0 ? 1 : 0)
            Spacer()
            circleButton("chevron.right", help: "Next (→)") { move(1) }
                .opacity(index < items.count - 1 ? 1 : 0)
        }
        .padding(.horizontal, 12)
    }

    private func circleButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 34, height: 34)
                .background(.white.opacity(0.12), in: Circle())
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private var caption: String {
        var parts: [String] = []
        switch item {
        case .local(let url):
            let bytes = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
            parts.append(ByteFormat.string(bytes))
        case .camera(let photo):
            if let date = CaptureDate.short(photo.captured) { parts.append(date) }
            parts.append(ByteFormat.string(photo.bytes))
            parts.append(model.importedNames.contains(photo.name) ? "already imported" : "on the camera")
        }
        if let dimensions { parts.append("\(Int(dimensions.width)) × \(Int(dimensions.height))") }
        return parts.joined(separator: " · ")
    }

    // MARK: Loading

    /// Screen-size decode of a 40 MP JPEG: enough for a zoom without holding the whole image.
    private var viewerPixels: Int { 3200 }

    private var fullSizeKey: String {
        if case .camera(let photo) = item { return "\(photo.handle)-\(model.fullSize[photo.handle]?.path ?? "")" }
        return item.id
    }

    private func load() async {
        sharp = false
        dimensions = nil
        switch item {
        case .local(let url):
            // The grid's thumbnail is already cached: show it at once, then the sharp one.
            image = await Thumbnails.shared.image(for: url)
            dimensions = Self.pixelSize(url)
            if let big = await Thumbnails.shared.image(for: url, pixels: viewerPixels, persist: false), !Task.isCancelled {
                image = big
                sharp = true
            }
            preloadNeighbours()
        case .camera(let photo):
            image = CameraThumb.image(photo)
            if model.cachedFullSize(photo) == nil && model.transport == .usb && !model.busy {
                // Over USB a whole frame is about a second away: fetch it once the user settles here.
                try? await Task.sleep(nanoseconds: 400_000_000)
                if !Task.isCancelled { model.fetchFullSize(photo) }
            } else if model.cachedFullSize(photo) != nil {
                model.fetchFullSize(photo)
            }
        }
    }

    private func loadFullSize() async {
        guard case .camera(let photo) = item, let url = model.fullSize[photo.handle] else { return }
        dimensions = Self.pixelSize(url)
        if let big = await Thumbnails.shared.image(for: url, pixels: viewerPixels, persist: false), !Task.isCancelled {
            image = big
            sharp = true
        }
    }

    /// Decode the photos on either side now, so an arrow key lands on a sharp image.
    private func preloadNeighbours() {
        for offset in [1, -1] {
            let next = index + offset
            guard items.indices.contains(next), case .local(let url) = items[next] else { continue }
            let pixels = viewerPixels
            Task.detached(priority: .utility) { _ = await Thumbnails.shared.image(for: url, pixels: pixels, persist: false) }
        }
    }

    static func pixelSize(_ url: URL) -> CGSize? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let turned = (props[kCGImagePropertyOrientation] as? Int ?? 1) >= 5
        return turned ? CGSize(width: height, height: width) : CGSize(width: width, height: height)
    }
}

/// Fit to the window; pinch or double-click to zoom, drag to pan when zoomed, swipe to move when not.
struct ZoomableImage: View {
    let image: UIImage?
    let onSwipe: (Int) -> Void

    @State private var scale: CGFloat = 1
    @State private var lastScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            Group {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .scaleEffect(scale)
                        .offset(offset)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                MagnifyGesture()
                    .onChanged { value in scale = min(max(lastScale * value.magnification, 1), 8) }
                    .onEnded { _ in
                        lastScale = scale
                        if scale <= 1.01 { reset() }
                    }
            )
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .onChanged { value in
                        guard scale > 1 else { return }
                        offset = CGSize(width: lastOffset.width + value.translation.width, height: lastOffset.height + value.translation.height)
                    }
                    .onEnded { value in
                        if scale > 1 {
                            lastOffset = offset
                        } else if abs(value.translation.width) > 60 && abs(value.translation.width) > abs(value.translation.height) {
                            onSwipe(value.translation.width < 0 ? 1 : -1)
                        }
                    }
            )
            .onTapGesture(count: 2) {
                withAnimation(.snappy) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2.5
                        lastScale = 2.5
                    }
                }
            }
        }
    }

    private func reset() {
        scale = 1
        lastScale = 1
        offset = .zero
        lastOffset = .zero
    }
}
