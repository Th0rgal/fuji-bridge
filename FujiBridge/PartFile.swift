import Foundation

/// A photo being copied, streamed to a hidden file next to where it will land.
///
/// Every window goes to disk as it arrives, so memory stays flat and a run that dies (Wi-Fi gone, app
/// suspended, camera switched off) leaves what it got. The next run finds the `.part` and asks the camera
/// only for the rest. The expected length is in the name: a resized copy and the original never mix.
final class PartFile {
    let url: URL
    let destination: URL
    private let handle: FileHandle
    private(set) var length: Int
    /// Bytes found on disk from an earlier run when this one started.
    let resumed: Int

    init(directory: URL, name: String, total: Int) throws {
        destination = directory.appendingPathComponent(name)
        url = directory.appendingPathComponent(Self.partName(name, total: total))
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        // Leftovers for this photo at another size (resized before, original now) are of no use.
        for stale in Self.parts(of: name, in: directory) where stale != url {
            try? fm.removeItem(at: stale)
        }
        if !fm.fileExists(atPath: url.path) {
            fm.createFile(atPath: url.path, contents: nil)
        }
        handle = try FileHandle(forUpdating: url)
        let size = Int(try handle.seekToEnd())
        // Resume on a 512-byte boundary: the body is ~40× slower from an unaligned offset.
        let keep = size <= total ? size / 512 * 512 : 0
        try handle.truncate(atOffset: UInt64(keep))
        try handle.seek(toOffset: UInt64(keep))
        length = keep
        resumed = keep
    }

    func append(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try handle.write(contentsOf: data)
        length += data.count
    }

    /// Drops the tail past `offset` (a window cut mid-way, realigned).
    func truncate(to offset: Int) throws {
        try handle.truncate(atOffset: UInt64(offset))
        try handle.seek(toOffset: UInt64(offset))
        length = offset
    }

    /// Moves the finished file into place, over any older copy of the same name.
    func finish() throws {
        try handle.synchronize()
        try handle.close()
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: url)
        } else {
            try fm.moveItem(at: url, to: destination)
        }
    }

    /// Keeps the bytes for the next run.
    func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    static func partName(_ name: String, total: Int) -> String {
        ".\(name).\(total).part"
    }

    static func parts(of name: String, in directory: URL) -> [URL] {
        let prefix = ".\(name)."
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil, options: [])) ?? []
        return all.filter { $0.lastPathComponent.hasPrefix(prefix) && $0.pathExtension == "part" }
    }

    /// Bytes waiting in `.part` files in `directory`, for the home screen and the report.
    static func pending(in directory: URL) -> Int {
        let all = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [])) ?? []
        return all.filter { $0.pathExtension == "part" && $0.lastPathComponent.hasPrefix(".") }
            .compactMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .reduce(0, +)
    }
}

/// Whether a saved photo is whole. A JPEG starts with FF D8 and ends with the FF D9 end-of-image marker;
/// a transfer cut short keeps the start and loses the end, and shows as a grey lower half.
enum JPEGCheck {
    static func applies(_ url: URL) -> Bool {
        ["jpg", "jpeg"].contains(url.pathExtension.lowercased())
    }

    /// True for a whole JPEG, and for anything that is not a JPEG (nothing to check).
    static func complete(_ url: URL) -> Bool {
        guard applies(url) else { return true }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 2), head == Data([0xff, 0xd8]),
              let size = try? handle.seekToEnd(), size > 4 else { return false }
        // Some writers pad after the marker; look in the last 64 bytes.
        let tail = min(size, 64)
        try? handle.seek(toOffset: size - tail)
        guard let end = try? handle.readToEnd() else { return false }
        return zip(end, end.dropFirst()).contains { $0 == 0xff && $1 == 0xd9 }
    }
}
