import Foundation
import ImageIO

/// A photo's film simulation recipe, read from the JPEG itself: Fujifilm writes every setting that shaped the
/// picture into its MakerNote (EXIF tag 0x927C). Value tables follow ExifTool's FujiFilm.pm.
struct Recipe: Codable, Hashable, Sendable, Identifiable {
    var film: String
    var grain: String?
    var colorChrome: String?
    var colorChromeBlue: String?
    var whiteBalance: String?
    var whiteBalanceShift: String?
    var dynamicRange: String?
    var dRangePriority: String?
    var highlight: String?
    var shadow: String?
    var color: String?
    var sharpness: String?
    var noiseReduction: String?
    var clarity: String?
    var monochromeTone: String?

    var id: String { signature }

    /// The settings as label / value pairs, in the order a recipe card lists them.
    var rows: [(String, String)] {
        [
            ("Film simulation", film),
            ("Grain", grain), ("Color chrome", colorChrome), ("Color chrome FX blue", colorChromeBlue),
            ("White balance", whiteBalance), ("WB shift", whiteBalanceShift),
            ("Dynamic range", dynamicRange), ("D range priority", dRangePriority),
            ("Highlight", highlight), ("Shadow", shadow), ("Color", color), ("Monochrome tone", monochromeTone),
            ("Sharpness", sharpness), ("High ISO NR", noiseReduction), ("Clarity", clarity),
        ].compactMap { label, value in value.map { (label, $0) } }
    }

    /// One line, the way recipes are shared: "Classic Chrome · DR400 · Highlight −1 · …".
    var text: String {
        rows.map { $0.0 == "Film simulation" ? $0.1 : "\($0.0) \($0.1)" }.joined(separator: " · ")
    }

    /// Same settings, same recipe: what groups photos in the library.
    var signature: String { text }
}

/// The shot itself, from the standard EXIF: exposure, lens, date.
struct ShotInfo: Sendable {
    var camera: String?
    var lens: String?
    var aperture: String?
    var shutter: String?
    var iso: String?
    var focalLength: String?
    var exposureBias: String?
    var date: String?
    var pixels: String?
    /// Fujifilm's image counter (MakerNote 0x1438): how many frames the body had taken.
    var frameCount: String?

    var rows: [(String, String)] {
        [("Camera", camera), ("Lens", lens), ("Aperture", aperture), ("Shutter", shutter), ("ISO", iso),
         ("Focal length", focalLength), ("Exposure", exposureBias), ("Taken", date), ("Size", pixels), ("Frame", frameCount)]
            .compactMap { label, value in value.map { (label, $0) } }
    }
}

enum RecipeReader {
    /// Reads the recipe and the shot info of a JPEG on disk. Nil when the file carries no Fujifilm MakerNote.
    static func read(_ url: URL) -> (recipe: Recipe?, shot: ShotInfo) {
        let shot = shotInfo(url)
        guard let head = try? FileHandle(forReadingFrom: url), let bytes = try? head.read(upToCount: 256 * 1024) else {
            return (nil, shot)
        }
        try? head.close()
        guard let note = makerNote(in: bytes) else { return (nil, shot) }
        var info = shot
        if let count = note.values[0x1438], count > 0 { info.frameCount = "#\(count & 0x7fff)" }
        return (recipe(from: note), info)
    }

    // MARK: Standard EXIF (ImageIO)

    static func shotInfo(_ url: URL) -> ShotInfo {
        var info = ShotInfo()
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return info }
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        info.camera = (tiff[kCGImagePropertyTIFFModel] as? String)?.trimmingCharacters(in: .whitespaces)
        info.lens = exif[kCGImagePropertyExifLensModel] as? String
        if let f = exif[kCGImagePropertyExifFNumber] as? Double { info.aperture = String(format: "f/%g", f) }
        if let t = exif[kCGImagePropertyExifExposureTime] as? Double {
            info.shutter = t >= 1 ? String(format: "%g s", t) : "1/\(Int((1 / t).rounded())) s"
        }
        if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Int])?.first { info.iso = "\(iso)" }
        if let mm = exif[kCGImagePropertyExifFocalLength] as? Double { info.focalLength = String(format: "%g mm", mm) }
        if let ev = exif[kCGImagePropertyExifExposureBiasValue] as? Double {
            info.exposureBias = ev == 0 ? "±0 EV" : String(format: "%+.1f EV", ev)
        }
        info.date = exif[kCGImagePropertyExifDateTimeOriginal] as? String
        if let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
            info.pixels = "\(w) × \(h)"
        }
        return info
    }

    // MARK: MakerNote

    /// Fujifilm MakerNote tags, number to raw value (first value; int32s pairs keep both in `pairs`).
    struct Note {
        var values: [UInt16: Int] = [:]
        var pairs: [UInt16: (Int, Int)] = [:]
    }

    /// Finds the Exif APP1 segment, walks IFD0 → ExifIFD → MakerNote and reads the Fujifilm IFD.
    static func makerNote(in data: Data) -> Note? {
        let bytes = [UInt8](data)
        var i = 2
        guard bytes.count > 4, bytes[0] == 0xff, bytes[1] == 0xd8 else { return nil }
        while i + 4 < bytes.count, bytes[i] == 0xff {
            let marker = bytes[i + 1]
            let length = Int(bytes[i + 2]) << 8 | Int(bytes[i + 3])
            if marker == 0xe1, i + 10 < bytes.count, Array(bytes[(i + 4)..<(i + 10)]) == Array("Exif\0\0".utf8) {
                return tiff(Array(bytes[(i + 10)..<min(bytes.count, i + 2 + length)]))
            }
            if marker == 0xda { break }
            i += 2 + length
        }
        return nil
    }

    private static func tiff(_ t: [UInt8]) -> Note? {
        guard t.count > 8 else { return nil }
        let little = t[0] == 0x49
        func u16(_ o: Int) -> Int { o + 1 < t.count ? (little ? Int(t[o]) | Int(t[o + 1]) << 8 : Int(t[o]) << 8 | Int(t[o + 1])) : 0 }
        func u32(_ o: Int) -> Int { o + 3 < t.count ? (little ? u16(o) | u16(o + 2) << 16 : u16(o) << 16 | u16(o + 2)) : 0 }
        func find(_ ifd: Int, _ tag: Int) -> (count: Int, value: Int)? {
            let n = u16(ifd)
            for k in 0..<n {
                let e = ifd + 2 + k * 12
                if u16(e) == tag { return (u32(e + 4), u32(e + 8)) }
            }
            return nil
        }
        guard let exif = find(u32(4), 0x8769), let note = find(exif.value, 0x927c), note.value + 12 < t.count else { return nil }
        let start = note.value
        guard Array(t[start..<(start + 8)]) == Array("FUJIFILM".utf8) else { return nil }
        // The Fujifilm IFD is always little-endian, with offsets from the start of the MakerNote.
        let m = Array(t[start..<min(t.count, start + note.count)])
        func l16(_ o: Int) -> Int { o + 1 < m.count ? Int(m[o]) | Int(m[o + 1]) << 8 : 0 }
        func l32(_ o: Int) -> Int { o + 3 < m.count ? l16(o) | l16(o + 2) << 16 : 0 }
        func s32(_ v: Int) -> Int { v >= 0x8000_0000 ? v - 0x1_0000_0000 : v }
        let ifd = l32(8)
        let count = l16(ifd)
        guard count > 0, count < 512 else { return nil }
        var result = Note()
        for k in 0..<count {
            let e = ifd + 2 + k * 12
            let tag = UInt16(l16(e)), type = l16(e + 2), n = l32(e + 4)
            let size = [1: 1, 3: 2, 4: 4, 7: 1, 8: 2, 9: 4][type] ?? 0
            guard size > 0 else { continue }
            let at = size * n <= 4 ? e + 8 : l32(e + 8)
            switch type {
            case 1, 7: result.values[tag] = at < m.count ? Int(m[at]) : 0
            case 3: result.values[tag] = l16(at)
            case 8: let v = l16(at); result.values[tag] = v >= 0x8000 ? v - 0x10000 : v
            case 4: result.values[tag] = l32(at)
            case 9:
                result.values[tag] = s32(l32(at))
                if n >= 2 { result.pairs[tag] = (s32(l32(at)), s32(l32(at + 4))) }
            default: break
            }
        }
        return result
    }

    // MARK: Values

    static func recipe(from note: Note) -> Recipe? {
        let v = note.values
        let saturation = v[0x1003]
        let mono: [Int: String] = [0x300: "Monochrome", 0x301: "Monochrome + R", 0x302: "Monochrome + Ye", 0x303: "Monochrome + G",
                                   0x310: "Sepia", 0x500: "Acros", 0x501: "Acros + R", 0x502: "Acros + Ye", 0x503: "Acros + G"]
        let films: [Int: String] = [0x0: "Provia / Standard", 0x100: "Studio Portrait", 0x110: "Studio Portrait Ex", 0x120: "Astia / Soft",
                                    0x130: "Studio Portrait Sharp", 0x200: "Velvia / Vivid", 0x300: "Studio Portrait Ex", 0x400: "Velvia",
                                    0x500: "Pro Neg. Std", 0x501: "Pro Neg. Hi", 0x600: "Classic Chrome", 0x700: "Eterna / Cinema",
                                    0x800: "Classic Neg.", 0x900: "Eterna Bleach Bypass", 0xa00: "Nostalgic Neg.", 0xb00: "Reala Ace"]
        let film: String
        if let s = saturation, let name = mono[s] {
            film = name
        } else if let f = v[0x1401] {
            film = films[f] ?? String(format: "Film 0x%X", f)
        } else {
            return nil
        }
        var r = Recipe(film: film)
        let strength: [Int: String] = [0: "Off", 32: "Weak", 64: "Strong"]
        if let rough = v[0x1047] {
            let size = [0: "", 16: " Small", 32: " Large"][v[0x104c] ?? 0] ?? ""
            r.grain = rough == 0 ? "Off" : (strength[rough] ?? "\(rough)") + size
        }
        r.colorChrome = v[0x1048].flatMap { strength[$0] }
        r.colorChromeBlue = v[0x104e].flatMap { strength[$0] }
        if let wb = v[0x1002] {
            let names: [Int: String] = [0x0: "Auto", 0x1: "Auto White Priority", 0x2: "Auto Ambience Priority", 0x100: "Daylight",
                                        0x200: "Shade", 0x300: "Fluorescent 1", 0x301: "Fluorescent 2", 0x302: "Fluorescent 3",
                                        0x303: "Fluorescent 4", 0x304: "Fluorescent 5", 0x400: "Incandescent", 0x500: "Flash",
                                        0x600: "Underwater", 0xf00: "Custom 1", 0xf01: "Custom 2", 0xf02: "Custom 3", 0xff0: "Kelvin"]
            var text = names[wb] ?? String(format: "0x%X", wb)
            if wb == 0xff0, let k = v[0x1005] { text = "\(k) K" }
            r.whiteBalance = text
        }
        if let (red, blue) = note.pairs[0x100a] {
            r.whiteBalanceShift = "R \(signed(red / 20)), B \(signed(blue / 20))"
        }
        // 0x1402 DynamicRangeSetting (0 auto, 1 manual), 0x1403 DevelopmentDynamicRange (100/200/400).
        // Checked on X100VI files: 0x1402 = 1, 0x1403 = 400 for a DR400 recipe.
        if let dev = v[0x1403], [100, 200, 400].contains(dev) {
            r.dynamicRange = (v[0x1402] == 0 ? "Auto · " : "") + "DR\(dev)"
        } else if v[0x1402] == 0 {
            r.dynamicRange = "Auto"
        }
        if v[0x1443] == 1 {
            r.dRangePriority = [1: "Weak", 2: "Strong"][v[0x1445] ?? 0] ?? "On"
        } else if v[0x1443] == 0, v[0x1444] != nil {
            r.dRangePriority = "Auto"
        }
        r.highlight = v[0x1041].map { tone($0) }
        r.shadow = v[0x1040].map { tone($0) }
        if let s = saturation, mono[s] == nil {
            r.color = [0x0: "0", 0x80: "+1", 0x100: "+2", 0xc0: "+3", 0xe0: "+4", 0x180: "−1", 0x400: "−2", 0x4c0: "−3", 0x4e0: "−4"][s]
        }
        if mono[saturation ?? -1] != nil, let warm = v[0x1049] {
            let mg = v[0x104b] ?? 0
            r.monochromeTone = "WC \(signed(warm)), MG \(signed(mg))"
        }
        r.sharpness = v[0x1001].flatMap { [0x0: "−4", 0x1: "−3", 0x2: "−2", 0x82: "−1", 0x3: "0", 0x84: "+1", 0x4: "+2", 0x5: "+3", 0x6: "+4"][$0] }
        r.noiseReduction = v[0x100e].flatMap {
            [0x0: "0", 0x180: "+1", 0x100: "+2", 0x1c0: "+3", 0x1e0: "+4", 0x280: "−1", 0x200: "−2", 0x2c0: "−3", 0x2e0: "−4"][$0]
        }
        r.clarity = v[0x100f].map { signed($0 / 1000) }
        return r
    }

    /// Highlight and shadow tones are stored ×16 with the sign flipped: −16 is +1, 8 is −0.5.
    private static func tone(_ raw: Int) -> String {
        let value = Double(-raw) / 16
        return value == value.rounded() ? signed(Int(value)) : String(format: "%+.1f", value).replacingOccurrences(of: "-", with: "−")
    }

    private static func signed(_ v: Int) -> String {
        v > 0 ? "+\(v)" : (v < 0 ? "−\(-v)" : "0")
    }
}

/// Recipes kept by the user, and the ones found in the imported photos.
@MainActor
@Observable
final class RecipeLibrary {
    static let shared = RecipeLibrary()

    struct Found: Identifiable, Hashable {
        var recipe: Recipe
        var count: Int
        var sample: URL
        var id: String { recipe.signature }
    }

    private(set) var saved: [Recipe] = []
    private(set) var found: [Found] = []
    private(set) var scanning = false
    private let key = "BridgeRecipes"

    init() {
        if let data = UserDefaults.standard.data(forKey: key), let list = try? JSONDecoder().decode([Recipe].self, from: data) {
            saved = list
        }
    }

    func isSaved(_ recipe: Recipe) -> Bool { saved.contains { $0.signature == recipe.signature } }

    func toggle(_ recipe: Recipe) {
        if isSaved(recipe) { saved.removeAll { $0.signature == recipe.signature } } else { saved.insert(recipe, at: 0) }
        if let data = try? JSONEncoder().encode(saved) { UserDefaults.standard.set(data, forKey: key) }
    }

    /// Groups the imported photos by recipe, most used first. Off the main thread; newest 800 photos.
    func scan(_ urls: [URL]) async {
        guard !scanning else { return }
        scanning = true
        let list = Array(urls.prefix(800))
        let groups = await Task.detached(priority: .utility) { () -> [Found] in
            var map: [String: Found] = [:]
            for url in list {
                guard let recipe = RecipeReader.read(url).recipe else { continue }
                map[recipe.signature, default: Found(recipe: recipe, count: 0, sample: url)].count += 1
            }
            return map.values.sorted { $0.count > $1.count }
        }.value
        found = groups
        scanning = false
    }
}
