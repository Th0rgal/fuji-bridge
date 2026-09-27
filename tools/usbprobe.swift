// Read-only PTP probe for a Fujifilm body on USB, through ImageCaptureCore.
//
//   swift tools/usbprobe.swift              device info, handles, Fuji props, partial-read timings
//   swift tools/usbprobe.swift --sizes 1,2,4,8   window sizes to time, in MB
//
// It never writes to the card and never sets a property. The Wi-Fi protocol is the same PTP
// containers over TCP, so what the body does here (operations it lists, how long a GetPartialObject
// window takes to start, whether it accepts windows over 1 MB) is what Fuji Bridge sees over Wi-Fi,
// minus the radio.
import Foundation
import ImageCaptureCore
import ImageIO

setvbuf(stdout, nil, _IOLBF, 0)

func u16(_ d: Data, _ o: Int) -> UInt16 { UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8 }
func u32(_ d: Data, _ o: Int) -> UInt32 { UInt32(u16(d, o)) | UInt32(u16(d, o + 2)) << 16 }
func hex(_ d: Data, _ n: Int = 32) -> String { d.prefix(n).map { String(format: "%02x", $0) }.joined(separator: " ") }
func now() -> Double { Double(DispatchTime.now().uptimeNanoseconds) / 1e6 }

/// PTP string: u8 count of UTF-16 units (with the NUL), then the units.
func ptpString(_ d: Data, _ o: inout Int) -> String {
    guard o < d.count else { return "" }
    let n = Int(d[d.startIndex + o]); o += 1
    var units: [UInt16] = []
    for _ in 0..<n { guard o + 1 < d.count else { break }; units.append(u16(d, o)); o += 2 }
    return String(decoding: units.filter { $0 != 0 }, as: UTF16.self)
}
func u16Array(_ d: Data, _ o: inout Int) -> [UInt16] {
    let n = Int(u32(d, o)); o += 4
    var out: [UInt16] = []
    for _ in 0..<n { guard o + 1 < d.count else { break }; out.append(u16(d, o)); o += 2 }
    return out
}

var sizesMB: [Double] = [0.25, 1, 2, 4, 8]
if let i = CommandLine.arguments.firstIndex(of: "--sizes"), i + 1 < CommandLine.arguments.count {
    sizesMB = CommandLine.arguments[i + 1].split(separator: ",").compactMap { Double($0) }
}

final class Probe: NSObject, ICDeviceBrowserDelegate, ICCameraDeviceDelegate {
    let browser = ICDeviceBrowser()
    var camera: ICCameraDevice?
    var tid: UInt32 = 1000
    var started = false

    func start() {
        browser.delegate = self
        browser.browsedDeviceTypeMask = ICDeviceTypeMask(rawValue: ICDeviceTypeMask.camera.rawValue | ICDeviceLocationTypeMask.local.rawValue)!
        browser.start()
        print("browsing for cameras...")
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
            if self.camera == nil { print("no camera after 15 s"); exit(2) }
        }
    }

    func deviceBrowser(_ browser: ICDeviceBrowser, didAdd device: ICDevice, moreComing: Bool) {
        guard let cam = device as? ICCameraDevice, camera == nil else { return }
        camera = cam
        cam.delegate = self
        print("found \(cam.name ?? "?") (\(cam.productKind ?? "?"), transport \(cam.transportType ?? "?"))")
        cam.requestOpenSession()
    }
    func deviceBrowser(_ browser: ICDeviceBrowser, didRemove device: ICDevice, moreGoing: Bool) {}

    func device(_ device: ICDevice, didOpenSessionWithError error: Error?) {
        if let error { print("open session failed: \(error)"); exit(3) }
        print("session open")
    }
    func deviceDidBecomeReady(withCompleteContentCatalog device: ICCameraDevice) {
        guard !started else { return }
        started = true
        let files = device.mediaFiles?.compactMap { $0 as? ICCameraFile } ?? []
        print("catalog: \(files.count) files")
        Task { await self.run(files) }
    }
    func device(_ device: ICDevice, didCloseSessionWithError error: Error?) {}
    func didRemove(_ device: ICDevice) { print("camera removed"); exit(4) }
    func cameraDevice(_ camera: ICCameraDevice, didAdd items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didRemove items: [ICCameraItem]) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveThumbnail thumbnail: CGImage?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceiveMetadata metadata: [AnyHashable: Any]?, for item: ICCameraItem, error: Error?) {}
    func cameraDevice(_ camera: ICCameraDevice, didRenameItems items: [ICCameraItem]) {}
    func cameraDeviceDidChangeCapability(_ camera: ICCameraDevice) {}
    func cameraDevice(_ camera: ICCameraDevice, didReceivePTPEvent eventData: Data) { print("  event \(hex(eventData))") }
    func cameraDeviceDidRemoveAccessRestriction(_ device: ICDevice) {}
    func cameraDeviceDidEnableAccessRestriction(_ device: ICDevice) {}

    /// One PTP transaction. Returns (data phase, response code, ms).
    func ptp(_ code: UInt16, _ params: [UInt32] = []) async -> (Data, UInt16, Double) {
        tid += 1
        var cmd = Data(count: 12 + params.count * 4)
        func put32(_ o: Int, _ v: UInt32) { for i in 0..<4 { cmd[o + i] = UInt8((v >> (8 * UInt32(i))) & 0xff) } }
        put32(0, UInt32(cmd.count))
        cmd[4] = 1; cmd[5] = 0
        cmd[6] = UInt8(code & 0xff); cmd[7] = UInt8(code >> 8)
        put32(8, tid)
        for (i, p) in params.enumerated() { put32(12 + i * 4, p) }
        let start = now()
        return await withCheckedContinuation { cont in
            camera!.requestSendPTPCommand(cmd, outData: nil) { data, response, error in
                let ms = now() - start
                if let error { print("  ptp 0x\(String(code, radix: 16)) error \(error)") }
                let rc = response.count >= 8 ? u16(response, 6) : 0
                cont.resume(returning: (data, rc, ms))
            }
        }
    }

    func run(_ files: [ICCameraFile]) async {
        // 1. DeviceInfo: what the body says it can do.
        let (info, rc, ms) = await ptp(0x1001)
        print("\nGetDeviceInfo rc=0x\(String(rc, radix: 16)) \(info.count) B in \(String(format: "%.0f", ms)) ms")
        if info.count > 12 {
            var o = 8
            _ = ptpString(info, &o) // vendor extension desc
            o += 2 // functional mode
            let ops = u16Array(info, &o)
            let events = u16Array(info, &o)
            let props = u16Array(info, &o)
            _ = u16Array(info, &o); _ = u16Array(info, &o)
            let maker = ptpString(info, &o), model = ptpString(info, &o), version = ptpString(info, &o), serial = ptpString(info, &o)
            print("  \(maker) \(model) firmware \(version) serial \(serial.isEmpty ? "-" : "set")")
            print("  operations (\(ops.count)): " + ops.map { String(format: "%04x", $0) }.joined(separator: " "))
            print("  events (\(events.count)): " + events.map { String(format: "%04x", $0) }.joined(separator: " "))
            print("  props (\(props.count)): " + props.map { String(format: "%04x", $0) }.joined(separator: " "))
            print("  GetPartialObject 101b supported: \(ops.contains(0x101b))")
        }

        // 2. Handles.
        let (hdata, hrc, hms) = await ptp(0x1007, [0xffff_ffff, 0, 0])
        var handles: [UInt32] = []
        if hdata.count >= 4 {
            let n = Int(u32(hdata, 0))
            for i in 0..<n where 4 + i * 4 + 3 < hdata.count { handles.append(u32(hdata, 4 + i * 4)) }
        }
        print("\nGetObjectHandles rc=0x\(String(hrc, radix: 16)) \(handles.count) handles in \(String(format: "%.0f", hms)) ms")

        // 3. ObjectInfo for every handle: names, sizes, formats, time per call.
        struct Obj { var handle: UInt32; var name: String; var size: Int; var format: UInt16 }
        var objects: [Obj] = []
        var infoMs: [Double] = []
        for h in handles {
            let (d, r, t) = await ptp(0x1008, [h])
            infoMs.append(t)
            guard r == 0x2001, d.count > 53 else { continue }
            var o = 52
            let name = ptpString(d, &o)
            objects.append(Obj(handle: h, name: name, size: Int(u32(d, 8)), format: u16(d, 4)))
        }
        let files = objects.filter { $0.format != 0x3001 }
        let total = files.map(\.size).reduce(0, +)
        print("GetObjectInfo ×\(infoMs.count): avg \(String(format: "%.1f", infoMs.reduce(0, +) / Double(max(1, infoMs.count)))) ms, max \(String(format: "%.1f", infoMs.max() ?? 0)) ms")
        print("  \(files.count) files, \(String(format: "%.1f", Double(total) / 1_048_576)) MB")
        var byExt: [String: (Int, Int)] = [:]
        for f in files {
            let ext = (f.name as NSString).pathExtension.uppercased()
            byExt[ext, default: (0, 0)].0 += 1
            byExt[ext, default: (0, 0)].1 += f.size
        }
        for (ext, v) in byExt.sorted(by: { $0.key < $1.key }) {
            print("  .\(ext): \(v.0) files, avg \(String(format: "%.1f", Double(v.1) / Double(v.0) / 1_048_576)) MB")
        }
        for f in files.suffix(5) { print("  last: #\(f.handle) \(f.name) \(f.size) B fmt 0x\(String(f.format, radix: 16))") }

        // 4. Fuji vendor props, read only. Many are Wi-Fi only; the rc says which.
        print("\nFuji props (GetDevicePropValue, read only):")
        for p: UInt32 in [0xd212, 0xd222, 0xd620, 0xd621, 0xdf00, 0xdf01, 0xdf21, 0xdf22, 0xdf24, 0xdf25, 0xdf28, 0xd226, 0xd227, 0xd22b] {
            let (d, r, t) = await ptp(0x1015, [p])
            print(String(format: "  %04x rc=0x%04x %4d B %5.1f ms  ", p, r, d.count, t) + hex(d, 24))
        }

        if CommandLine.arguments.contains("--thumb") {
            print("\nGetThumb (0x100a) on the newest 5:")
            for f in files.suffix(13) {
                let (d, r, t) = await ptp(0x100a, [f.handle])
                var dims = ""
                if let src = CGImageSourceCreateWithData(d as CFData, nil),
                   let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] {
                    dims = "\(props[kCGImagePropertyPixelWidth] ?? "?")x\(props[kCGImagePropertyPixelHeight] ?? "?") orient \(props[kCGImagePropertyOrientation] ?? "none")"
                }
                let info = await ptp(0x1008, [f.handle]).0
                var o = 52
                _ = ptpString(info, &o)
                let captured = ptpString(info, &o)
                print(String(format: "  #%d %@ rc=0x%04x %6d B %@ in %.1f ms, captured %@", f.handle, f.name as NSString, r, d.count, dims as NSString, t, captured as NSString))
            }
            exit(0)
        }
        if CommandLine.arguments.contains("--align") {
            // Same 1 MB read at differently aligned offsets, each on a file not read before (no camera cache),
            // then the same read again (warm).
            let pool = Array(files.filter { $0.size > 8 * 1_048_576 }.dropLast().suffix(40).reversed())
            let cases: [(String, Int)] = [("1 MB aligned", 4 * 1_048_576), ("64 KB aligned", 4 * 1_048_576 + 65_536 * 3),
                                          ("512 B aligned", 4 * 1_048_576 + 512 * 37), ("even, unaligned", 4 * 1_048_576 + 270),
                                          ("odd", 4 * 1_048_576 + 1_234_567 % 1_048_576)]
            print("\nAlignment, 1 MB GetPartialObject, cold then warm:")
            var i = 0
            for round in 0..<3 {
                for (label, offset) in cases {
                    guard i < pool.count else { break }
                    let f = pool[i]; i += 1
                    let cold = await ptp(0x101b, [f.handle, UInt32(offset), 1_048_576]).2
                    let warm = await ptp(0x101b, [f.handle, UInt32(offset), 1_048_576]).2
                    print(String(format: "  r%d %-16@ offset %8d  cold %7.1f ms  warm %7.1f ms  (#%d)", round, label as NSString, offset, cold, warm, f.handle))
                }
            }
            exit(0)
        }

        // 5. Partial reads: how long a window takes, and whether windows over 1 MB are honoured.
        guard let target = files.filter({ $0.size >= 8 * 1_048_576 }).last ?? files.max(by: { $0.size < $1.size }) else {
            print("no file to time"); exit(0)
        }
        print("\nGetPartialObject on #\(target.handle) \(target.name), \(String(format: "%.1f", Double(target.size) / 1_048_576)) MB")
        for mb in sizesMB {
            let ask = min(Int(mb * 1_048_576), target.size)
            var runs: [Double] = []
            var got = 0
            var rcs = Set<UInt16>()
            for rep in 0..<3 {
                let offset = UInt32((rep * 1_234_567) % max(1, target.size - ask + 1))
                let (d, r, t) = await ptp(0x101b, [target.handle, offset, UInt32(ask)])
                runs.append(t); got = d.count; rcs.insert(r)
            }
            let best = runs.min() ?? 0
            print(String(format: "  ask %6.2f MB -> got %8d B, rc %@, %6.1f / %6.1f / %6.1f ms, best %.1f MB/s",
                         Double(ask) / 1_048_576, got, rcs.map { String(format: "0x%04x", $0) }.joined(separator: ","),
                         runs[0], runs[1], runs[2], Double(got) / 1_048_576 / (best / 1000)))
        }
        // Tiny reads isolate the per-command cost (USB round trip + camera).
        var tiny: [Double] = []
        for _ in 0..<10 { tiny.append(await ptp(0x101b, [target.handle, 0, 512]).2) }
        print(String(format: "  512 B ×10: avg %.1f ms, min %.1f ms  (per-command overhead)", tiny.reduce(0, +) / 10, tiny.min() ?? 0))

        // Whole-file pull the way Fuji Bridge does it (1 MB windows) vs one GetObject.
        var start = now(); var off = 0
        while off < target.size {
            let ask = min(1_048_576, target.size - off)
            let (d, _, _) = await ptp(0x101b, [target.handle, UInt32(off), UInt32(ask)])
            if d.isEmpty { break }
            off += d.count
        }
        let windowed = now() - start
        start = now()
        let (whole, wrc, _) = await ptp(0x1009, [target.handle])
        let single = now() - start
        print(String(format: "  whole file in 1 MB windows: %.0f ms (%.1f MB/s)", windowed, Double(off) / 1_048_576 / (windowed / 1000)))
        print(String(format: "  whole file with GetObject:  %.0f ms (%.1f MB/s), rc 0x%04x, %d B", single, Double(whole.count) / 1_048_576 / (single / 1000), wrc, whole.count))

        _ = try? await camera?.requestCloseSession()
        print("\ndone")
        exit(0)
    }
}

let probe = Probe()
probe.start()
RunLoop.main.run()
