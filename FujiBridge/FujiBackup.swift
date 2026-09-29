import CoreBluetooth
import Foundation

/// The camera settings backup over Bluetooth, as XApp's BTCameraModel does it (decompiled 2.2.1):
///
/// 1. listen to FILE_TRANSACTION_STATE and BACKUP_STATE
/// 2. write BACKUP_REQUEST = 1 (settings; 2 would be IPTC)
/// 3. wait up to 10 s for BACKUP_STATE = 1 (transferable); 0 means the camera is busy
/// 4. write FILE_PARTIAL_SIZE = 120, FILE_TRANSFER_INDEX = 0
/// 5. on each TRANSACTION_STATE 1 or 2, read FILE_PARTIAL_DATA: u16 seq, u32 len, data. The last chunk has
///    seq 0xFFFF and ends with a u16 sum of every data byte
/// 6. on TRANSACTION_STATE 3, check the sum, read FILE_INFORMATION (name in bytes 0–39, u32 size at 40),
///    write FILE_TRANSFER_RESULT = 3 (finish); on any error write 0
enum FujiBackup {
    enum Failure: Error, CustomStringConvertible {
        case unsupported
        case busy
        case noAnswer(String)
        case badChunk
        case checksum(expected: Int, got: Int)
        case ended(Int)

        var description: String {
            switch self {
            case .unsupported: return "This camera does not offer a settings backup over Bluetooth."
            case .busy: return "The camera is busy. Leave its menus and try again."
            case .noAnswer(let step): return "The camera did not answer (\(step))."
            case .badChunk: return "The camera sent a malformed piece of the backup."
            case .checksum(let expected, let got): return String(format: "The backup arrived damaged (checksum %04X, expected %04X).", got, expected)
            case .ended(let state): return "The camera ended the transfer (state \(state))."
            }
        }
    }

    static func run(_ gatt: GATTClient, progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in },
                    log: (String, String) -> Void) async throws -> (name: String, data: Data) {
        for needed in [FujiBLE.backupRequest, FujiBLE.backupState, FujiBLE.filePartialData, FujiBLE.fileTransactionState] {
            guard await gatt.has(needed) else { throw Failure.unsupported }
        }
        await gatt.subscribe(FujiBLE.fileTransactionState)
        await gatt.subscribe(FujiBLE.backupState)
        do {
            try await gatt.write(FujiBLE.backupRequest, Data([0x01, 0x00]))
            log("Backup requested", "BACKUP_REQUEST = 01 00")
            guard let ready = await gatt.nextValue(FujiBLE.backupState, timeout: 10) else { throw Failure.noAnswer("backup state") }
            guard ready.first == 1 else { throw Failure.busy }
            try await gatt.write(FujiBLE.filePartialSize, Data([120, 0, 0, 0]))
            try await gatt.write(FujiBLE.fileIndex, Data([0, 0, 0, 0]))
            var data = Data()
            var sum = 0
            var expected: Int?
            while true {
                guard let state = await gatt.nextValue(FujiBLE.fileTransactionState, timeout: 20), state.count >= 2 else {
                    throw Failure.noAnswer("transfer state")
                }
                let code = Int(state[state.startIndex]) | Int(state[state.startIndex + 1]) << 8
                switch code {
                case 1, 2:
                    let chunk = try await gatt.read(FujiBLE.filePartialData)
                    let part = try parse(chunk)
                    if part.last {
                        // The final piece ends with the checksum of everything before it.
                        let body = part.payload.dropLast(2)
                        let tail = Array(part.payload.suffix(2))
                        data.append(body)
                        sum += body.reduce(0) { $0 + Int($1) }
                        if tail.count == 2 { expected = Int(tail[0]) | Int(tail[1]) << 8 }
                    } else {
                        data.append(part.payload)
                        sum += part.payload.reduce(0) { $0 + Int($1) }
                    }
                    progress(data.count, 0)
                case 3:
                    if let expected, expected != sum & 0xffff {
                        try? await gatt.write(FujiBLE.fileTransferResult, Data([0, 0]))
                        throw Failure.checksum(expected: expected, got: sum & 0xffff)
                    }
                    var name = "backup.dat"
                    if let info = try? await gatt.read(FujiBLE.fileInformation), info.count >= 44 {
                        let bytes = Array(info)
                        let raw = bytes[0..<40].prefix { $0 != 0 }
                        if let text = String(bytes: raw, encoding: .utf8), !text.isEmpty { name = text }
                        let size = Int(bytes[40]) | Int(bytes[41]) << 8 | Int(bytes[42]) << 16 | Int(bytes[43]) << 24
                        if size > 0, size < data.count { data = data.prefix(size) }
                    }
                    try? await gatt.write(FujiBLE.fileTransferResult, Data([3, 0]))
                    log("Backup received", "\(name), \(data.count) bytes, checksum \(expected == nil ? "absent" : "ok").")
                    return (name, data)
                default:
                    throw Failure.ended(code)
                }
            }
        } catch {
            try? await gatt.write(FujiBLE.fileTransferResult, Data([0, 0]))
            throw error
        }
    }

    /// FILE_PARTIAL_DATA: u16 seq, u32 len, len bytes. seq 0xFFFF marks the last piece.
    static func parse(_ chunk: Data) throws -> (last: Bool, payload: Data) {
        let bytes = Array(chunk)
        guard bytes.count >= 6 else { throw Failure.badChunk }
        let seq = Int(bytes[0]) | Int(bytes[1]) << 8
        let length = Int(bytes[2]) | Int(bytes[3]) << 8 | Int(bytes[4]) << 16 | Int(bytes[5]) << 24
        guard length >= 0, 6 + length <= bytes.count else { throw Failure.badChunk }
        return (seq == 0xffff, Data(bytes[6..<(6 + length)]))
    }
}
