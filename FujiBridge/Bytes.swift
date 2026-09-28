import Foundation

enum Fuji {
    static let cameraHost = "192.168.0.1"
    static let port: UInt16 = 55740
    static let version: UInt32 = 0x8f53e4f2
    static let partialMax = 0x0010_0000
    /// Largest window the speed test tries.
    static let windowMax = 0x0080_0000
    static let stallBytes = 64 * 1024
    static let liedSize = 102_400

    static let getDeviceInfo: UInt16 = 0x1001
    static let openSession: UInt16 = 0x1002
    static let getObjectHandles: UInt16 = 0x1007
    static let getThumb: UInt16 = 0x100a
    /// Standard PTP DeleteObject(handle, format 0). Fuji bodies implement 0x1001 to 0x100B (libfuji docs/dev.md),
    /// and XApp's native layer carries an ExecDeleteImage built on it.
    static let deleteObject: UInt16 = 0x100b
    static let getObjectInfo: UInt16 = 0x1008
    static let getProp: UInt16 = 0x1015
    static let setProp: UInt16 = 0x1016
    static let getPartial: UInt16 = 0x101b
    /// MTP GetObjectPropValue. XApp reads a file's size as ObjectSize (0xDC04) with it, instead of turning on D227.
    static let getObjectPropValue: UInt16 = 0x9803
    static let objectSize: UInt32 = 0xdc04
    /// What XApp asks instead of ObjectSize when the body compresses (resizes) the object.
    static let compressedObjectSize: UInt32 = 0xd802
    static let ok: UInt16 = 0x2001
    static let invalidObject: UInt16 = 0x2009
    static let sessionAlreadyOpen: UInt16 = 0x201e

    static func okay(_ rc: UInt16) -> Bool {
        rc == ok || rc == sessionAlreadyOpen
    }

    static let getExtensionInfo: UInt16 = 0x9054
    static let getExtensionThumb: UInt16 = 0x9055
    static let getFolders: UInt16 = 0x9050
    static let getDates: UInt16 = 0x9053

    /// Standard PTP BatteryLevel.
    static let batteryLevel: UInt32 = 0x5001
    static let cameraState: UInt32 = 0xdf00
    static let clientState: UInt32 = 0xdf01
    static let events: UInt32 = 0xd212
    static let objectCount: UInt32 = 0xd222
    static let imageGetVersion: UInt32 = 0xdf21
    static let objectVersion: UInt32 = 0xdf22
    static let remoteVersion: UInt32 = 0xdf24
    static let remoteObjectVersion: UInt32 = 0xdf25
    static let remotePhotoView: UInt32 = 0xdf28
    /// XApp's ImageForceCompression: 2 for original files, 1 when it resizes, 0 outside an import.
    static let compressSmall: UInt32 = 0xd226
    /// XApp's ImageCompressionRealInfo. XApp leaves it at 0; libfuji sets 1 so ObjectInfo reports the real size.
    static let correctSize: UInt32 = 0xd227
    static let unknownD22B: UInt32 = 0xd22b
    /// XApp's ObjectCompressionSetting: the size a resized import comes out at (1 S, 0 XS).
    static let resizeRate: UInt32 = 0xd22e
    static let importCount: UInt32 = 0xd620
    static let importHandles: UInt32 = 0xd621
}

/// Little-endian helpers. Offsets are relative to `startIndex`: a `Data` that went through
/// `removeFirst` or slicing keeps its old indices, and reading `data[0]` from it traps.
enum LE {
    static func u16(_ data: Data, _ offset: Int) -> UInt16 {
        let base = data.startIndex + offset
        return UInt16(data[base]) | (UInt16(data[base + 1]) << 8)
    }

    static func u32(_ data: Data, _ offset: Int) -> UInt32 {
        let base = data.startIndex + offset
        return UInt32(data[base])
            | (UInt32(data[base + 1]) << 8)
            | (UInt32(data[base + 2]) << 16)
            | (UInt32(data[base + 3]) << 24)
    }

    static func put16(_ data: inout Data, _ offset: Int, _ value: UInt16) {
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xff)
        data[base + 1] = UInt8((value >> 8) & 0xff)
    }

    static func put32(_ data: inout Data, _ offset: Int, _ value: UInt32) {
        let base = data.startIndex + offset
        data[base] = UInt8(value & 0xff)
        data[base + 1] = UInt8((value >> 8) & 0xff)
        data[base + 2] = UInt8((value >> 16) & 0xff)
        data[base + 3] = UInt8((value >> 24) & 0xff)
    }

    static func data16(_ value: UInt16) -> Data {
        Data([UInt8(value & 0xff), UInt8((value >> 8) & 0xff)])
    }

    static func data32(_ value: UInt32) -> Data {
        var data = Data(count: 4)
        put32(&data, 0, value)
        return data
    }
}

enum Packets {
    static func initCommand(name: String) -> Data {
        var data = Data(count: 82)
        LE.put32(&data, 0, 0x52)
        LE.put32(&data, 4, 1)
        LE.put32(&data, 8, Fuji.version)
        LE.put32(&data, 12, 0x5d48a5ad)
        LE.put32(&data, 16, 0x0b7fb287)
        LE.put32(&data, 20, 0xd0ded5d3)
        LE.put32(&data, 24, 0)
        var offset = 28
        for unit in name.utf16 {
            if offset + 4 > data.count { break }
            LE.put16(&data, offset, unit)
            offset += 2
        }
        return data
    }

    static func command(code: UInt16, tid: UInt32, params: [UInt32] = []) -> Data {
        var data = Data(count: 12 + params.count * 4)
        LE.put32(&data, 0, UInt32(data.count))
        LE.put16(&data, 4, 1)
        LE.put16(&data, 6, code)
        LE.put32(&data, 8, tid)
        for (index, param) in params.enumerated() {
            LE.put32(&data, 12 + index * 4, param)
        }
        return data
    }

    static func dataPhase(code: UInt16, tid: UInt32, payload: Data) -> Data {
        var data = Data(count: 12 + payload.count)
        LE.put32(&data, 0, UInt32(data.count))
        LE.put16(&data, 4, 2)
        LE.put16(&data, 6, code)
        LE.put32(&data, 8, tid)
        data.replaceSubrange((data.startIndex + 12)..<data.endIndex, with: payload)
        return data
    }

    static func response(code: UInt16, tid: UInt32, rc: UInt16 = Fuji.ok) -> Data {
        var data = Data(count: 12)
        LE.put32(&data, 0, 12)
        LE.put16(&data, 4, 3)
        LE.put16(&data, 6, rc)
        LE.put32(&data, 8, tid)
        _ = code
        return data
    }

    static func hex(_ data: Data, limit: Int = 24) -> String {
        data.prefix(limit).map { String(format: "%02x", $0) }.joined(separator: " ")
    }

    static func ptpType(_ data: Data) -> UInt16 {
        data.count >= 6 ? LE.u16(data, 4) : 0
    }

    static func ptpCode(_ data: Data) -> UInt16 {
        data.count >= 8 ? LE.u16(data, 6) : 0
    }

    static func payload(_ data: Data) -> Data {
        data.count > 12 ? data.subdata(in: (data.startIndex + 12)..<data.endIndex) : Data()
    }
}

struct CardFrame: Identifiable, Equatable, Sendable {
    let handle: Int
    let name: String
    let bytes: Int
    let recipe: String
    var id: Int { handle }
}

enum Catalog {
    static let roll: [CardFrame] = [
        CardFrame(handle: 1, name: "DSCF4418.JPG", bytes: 2_400_000, recipe: "Nostalgic Neg"),
        CardFrame(handle: 2, name: "DSCF4422.JPG", bytes: 1_150_000, recipe: "Classic Chrome"),
        CardFrame(handle: 3, name: "DSCF4430.JPG", bytes: 3_200_000, recipe: "Acros+Ye"),
        CardFrame(handle: 4, name: "DSCF4436.JPG", bytes: 1_800_000, recipe: "Velvia"),
        CardFrame(handle: 5, name: "DSCF4441.JPG", bytes: 980_000, recipe: "Classic Neg"),
        CardFrame(handle: 6, name: "DSCF4448.JPG", bytes: 2_050_000, recipe: "Reala Ace"),
    ]
}

enum LinkError: Error, CustomStringConvertible {
    case stalled
    case shortRead
    case closed
    case timeout(String)
    case rejected
    case badLength(Int)
    case response(UInt16)

    var description: String {
        switch self {
        case .stalled: return "Socket stalled"
        case .shortRead: return "Short read"
        case .closed: return "Socket closed by the body"
        case .timeout(let what): return "Timed out \(what)"
        case .rejected: return "Rejected"
        case .badLength(let length): return "Bad packet length \(length)"
        case .response(let rc): return String(format: "Response 0x%04x", rc)
        }
    }
}

protocol ByteLink: AnyObject, Sendable {
    func open() async throws
    func write(_ data: Data) async throws
    func read(count: Int) async throws -> Data
    func close() async
    /// Socket-level events (state changes, path, timeouts) for the trace.
    func observe(_ sink: @escaping @Sendable (String, String) -> Void)
    /// How long a read may wait for the next byte before the link gives up.
    func setReadTimeout(_ seconds: TimeInterval)
    /// Starts counting receives for one window (a GetPartialObject), after its command went out.
    func markWindow()
    /// What the socket saw since `markWindow`: nil on links that hand a window over in one piece (USB, virtual).
    func windowStats() -> WindowStats?
}

extension ByteLink {
    func observe(_ sink: @escaping @Sendable (String, String) -> Void) {}
    func setReadTimeout(_ seconds: TimeInterval) {}
    func markWindow() {}
    func windowStats() -> WindowStats? { nil }
}

/// How the bytes of one window trickled in. A long silence after the first byte is the radio, not the camera.
struct WindowStats: Sendable, Equatable {
    var receives: Int
    /// Longest wait between two receives after the first byte, in ms.
    var longestGapMs: Double
}

/// Packed `PtpFujiEvents`: u16 count, then {u16 code, u32 value}. DF00 is not always first.
enum FujiEvents {
    struct Item: Equatable {
        var code: UInt16
        var value: UInt32
    }

    static func parse(_ data: Data) -> [Item] {
        guard data.count >= 2 else { return [] }
        let count = Int(LE.u16(data, 0))
        var items: [Item] = []
        var offset = 2
        for _ in 0..<count {
            guard offset + 6 <= data.count else { break }
            items.append(Item(code: LE.u16(data, offset), value: LE.u32(data, offset + 2)))
            offset += 6
        }
        return items
    }

    static func value(_ data: Data, prop: UInt32) -> UInt32? {
        let code = UInt16(prop & 0xffff)
        return parse(data).first { $0.code == code }?.value
    }
}

/// Device-prop array as libpict reads it: u32 count, then that many u32s.
enum FujiArray {
    static func handles(_ data: Data) -> [Int] {
        guard data.count >= 4 else { return [] }
        let count = Int(LE.u32(data, 0))
        guard count > 0, count <= 20_000, data.count >= 4 + count * 4 else { return [] }
        return (0..<count).map { Int(LE.u32(data, 4 + $0 * 4)) }
    }

    static func encode(_ values: [Int]) -> Data {
        var data = Data(count: 4 + values.count * 4)
        LE.put32(&data, 0, UInt32(values.count))
        for (index, value) in values.enumerated() {
            LE.put32(&data, 4 + index * 4, UInt32(value))
        }
        return data
    }
}

/// Packed `PtpFujiObjectInfo`. `compressed_size` is the unaligned u32 at offset 13.
/// The filename is a PTP string (u8 length, then UTF-16) starting at offset 52, not raw ASCII.
enum ObjectInfo {
    static let sizeOffset = 13
    static let nameOffset = 52

    static func payload(name: String, bytes: Int, maxPartial: Int) -> Data {
        var data = Data(count: 208)
        LE.put32(&data, 8, UInt32(maxPartial))
        LE.put32(&data, sizeOffset, UInt32(bytes))
        writeString(&data, nameOffset, name)
        return data
    }

    /// USB PTP ObjectInfo: ObjectFormat u16 at 4, 0x3001 is an association (a folder such as DCIM/100_FUJI).
    static func isFolder(_ data: Data) -> Bool {
        data.count >= 6 && LE.u16(data, 4) == 0x3001
    }

    /// USB PTP ObjectInfo: ObjectCompressedSize is the aligned u32 at offset 8. Measured on an X100VI.
    static func standardSize(_ data: Data) -> Int? {
        guard data.count >= 12 else { return nil }
        return Int(LE.u32(data, 8))
    }

    /// The PTP string after the filename: capture date, "20260924T195324" on an X100VI over USB.
    static func captureDate(_ data: Data) -> String? {
        let data = data.startIndex == 0 ? data : data.subdata(in: data.startIndex..<data.endIndex)
        guard data.count > nameOffset else { return nil }
        let skip = 1 + Int(data[nameOffset]) * 2
        let offset = nameOffset + skip
        guard offset < data.count else { return nil }
        let count = Int(data[offset])
        var units: [UInt16] = []
        var cursor = offset + 1
        for _ in 0..<count where cursor + 1 < data.count {
            units.append(LE.u16(data, cursor))
            cursor += 2
        }
        let text = String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
        return text.count >= 15 && text.first?.isNumber == true ? text : nil
    }

    static func compressedSize(_ data: Data) -> Int? {
        guard data.count >= sizeOffset + 4 else { return nil }
        return Int(LE.u32(data, sizeOffset))
    }

    /// libfuji copies 52 fixed bytes, then `ptp_read_string` for the name.
    static func filename(_ data: Data) -> String? {
        let data = data.startIndex == 0 ? data : data.subdata(in: data.startIndex..<data.endIndex)
        guard data.count > nameOffset else { return nil }
        let length = Int(data[nameOffset])
        if length == 0 { return nil }
        var raw: [UInt8] = []
        var cursor = nameOffset + 1
        var left = length
        while left > 0, cursor + 1 < data.count, raw.count < 63 {
            let unit = LE.u16(data, cursor)
            cursor += 2
            left -= 1
            if unit == 0 { break }
            if unit < 32 || unit > 126 { continue }
            raw.append(UInt8(unit & 0xff))
        }
        guard !raw.isEmpty else { return nil }
        return String(bytes: raw, encoding: .utf8)
    }

    private static func writeString(_ data: inout Data, _ offset: Int, _ name: String) {
        let units = Array(name.utf16.prefix(31))
        guard offset < data.count else { return }
        data[offset] = UInt8(units.count + 1)
        var cursor = offset + 1
        for unit in units {
            guard cursor + 2 <= data.count else { return }
            LE.put16(&data, cursor, unit)
            cursor += 2
        }
        if cursor + 2 <= data.count {
            LE.put16(&data, cursor, 0)
        }
    }
}

/// PTP DeviceInfo, only as far as the trace needs: maker, model, firmware.
enum DeviceDescription {
    static func parse(_ data: Data) -> String {
        let data = data.startIndex == 0 ? data : data.subdata(in: data.startIndex..<data.endIndex)
        var offset = 8
        func string() -> String {
            guard offset < data.count else { return "" }
            let count = Int(data[offset])
            offset += 1
            var units: [UInt16] = []
            for _ in 0..<count where offset + 1 < data.count {
                units.append(LE.u16(data, offset))
                offset += 2
            }
            return String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
        }
        func skipArray(_ width: Int) {
            guard offset + 4 <= data.count else { offset = data.count; return }
            offset += 4 + Int(LE.u32(data, offset)) * width
        }
        _ = string()
        offset += 2
        for _ in 0..<5 { skipArray(2) }
        let maker = string(), model = string(), version = string()
        return [maker, model, version.isEmpty ? "" : "firmware \(version)"].filter { !$0.isEmpty }.joined(separator: " ")
    }
}

/// Just enough EXIF to turn a thumbnail the right way up.
enum Exif {
    /// Orientation (tag 0x0112) from the start of a JPEG: SOI, APP1 "Exif", TIFF header, IFD0.
    static func orientation(_ jpeg: Data) -> Int? {
        let d = [UInt8](jpeg)
        guard d.count > 20, d[0] == 0xff, d[1] == 0xd8 else { return nil }
        var i = 2
        while i + 4 < d.count, d[i] == 0xff {
            let marker = d[i + 1]
            let length = Int(d[i + 2]) << 8 | Int(d[i + 3])
            if marker == 0xe1, i + 10 < d.count, d[(i + 4)..<(i + 10)].elementsEqual([0x45, 0x78, 0x69, 0x66, 0, 0]) {
                return tiff(d, base: i + 10)
            }
            if marker == 0xda { return nil }
            i += 2 + length
        }
        return nil
    }

    private static func tiff(_ d: [UInt8], base: Int) -> Int? {
        guard base + 8 <= d.count else { return nil }
        let little = d[base] == 0x49
        func u16(_ at: Int) -> Int? {
            guard at + 1 < d.count else { return nil }
            return little ? Int(d[at]) | Int(d[at + 1]) << 8 : Int(d[at]) << 8 | Int(d[at + 1])
        }
        func u32(_ at: Int) -> Int? {
            guard let a = u16(at), let b = u16(at + 2) else { return nil }
            return little ? a | b << 16 : a << 16 | b
        }
        guard let ifd = u32(base + 4), let count = u16(base + ifd) else { return nil }
        for entry in 0..<count {
            let at = base + ifd + 2 + entry * 12
            guard let tag = u16(at) else { return nil }
            if tag == 0x0112, let value = u16(at + 8), (1...8).contains(value) { return value }
        }
        return nil
    }
}
