import Foundation

struct Faults: Equatable, Sendable {
    var flakyHandshake = true
    var requireOk = true
    var stallChunk = true
    var lieAboutSize = true
    var impatientOpen = false

    static let none = Faults(
        flakyHandshake: false,
        requireOk: false,
        stallChunk: false,
        lieAboutSize: false,
        impatientOpen: false
    )
}

final class RunControl: @unchecked Sendable {
    var aborted = false
    var ok = false
}

enum Reply {
    case silent
    case bytes(Data)
    case stall(Data)
}

/// In-process X100VI. Speaks the same length-prefixed packets as the body.
final class VirtualBody: @unchecked Sendable {
    let faults: Faults
    let control: RunControl
    let frames: [CardFrame]
    private(set) var initCount = 0
    private(set) var correctSize: UInt16 = 0
    private var stallArmed: Bool
    private var pendingSet: UInt32?
    private var failNextInit: Bool
    private(set) var openTids: [UInt32] = []
    private(set) var partials: [(handle: Int, offset: Int, ask: Int)] = []
    private(set) var compressSmall: UInt16 = 0
    /// Nil lists the card. An empty array is a body that answered D621 with no handles.
    var listedHandles: [Int]?
    private(set) var infoSeen: [(handle: Int, compress: UInt16, correct: UInt16, reported: Int)] = []

    init(faults: Faults, control: RunControl, frames: [CardFrame]) {
        self.faults = faults
        self.control = control
        self.frames = frames
        self.stallArmed = faults.stallChunk
        self.failNextInit = false
        self.listedHandles = nil
    }

    /// Each new command socket may Init-Fail once. libfuji retries that per handshake.
    func noteConnect() {
        failNextInit = faults.flakyHandshake
    }

    var cameraState: UInt32 {
        if !faults.requireOk || control.ok { return 2 }
        return 0
    }

    func handle(_ packet: Data) -> Reply {
        guard packet.count >= 8 else { return .bytes(Data()) }
        let kind = LE.u32(packet, 4)
        if packet.count == 82 && kind == 1 {
            return handshake()
        }
        if let prop = pendingSet, Packets.ptpType(packet) == 2 {
            pendingSet = nil
            applySet(prop, Packets.payload(packet))
            let tid = LE.u32(packet, 8)
            return .bytes(Packets.response(code: Fuji.setProp, tid: tid))
        }
        guard Packets.ptpType(packet) == 1 else { return .silent }
        return command(packet)
    }

    private func handshake() -> Reply {
        initCount += 1
        if failNextInit {
            failNextInit = false
            var fail = Data(count: 16)
            LE.put32(&fail, 0, 16)
            LE.put32(&fail, 4, 5)
            return .bytes(fail)
        }
        var ack = Data(count: 82)
        LE.put32(&ack, 0, 0x52)
        LE.put32(&ack, 4, 2)
        var offset = 28
        for unit in "X100VI".utf16 {
            LE.put16(&ack, offset, unit)
            offset += 2
        }
        return .bytes(ack)
    }

    private func command(_ packet: Data) -> Reply {
        let code = Packets.ptpCode(packet)
        let tid = LE.u32(packet, 8)
        let params = paramsOf(packet)
        switch code {
        case Fuji.openSession:
            openTids.append(tid)
            return .bytes(Packets.response(code: code, tid: tid))
        case Fuji.setProp:
            pendingSet = params.first ?? 0
            return .silent
        case Fuji.getProp:
            let prop = params.first ?? 0
            let payload = propValue(prop)
            return .bytes(Packets.dataPhase(code: code, tid: tid, payload: payload)
                + Packets.response(code: code, tid: tid))
        case Fuji.getObjectInfo:
            let handle = Int(params.first ?? 0)
            guard frames.contains(where: { $0.handle == handle }) else {
                return .bytes(Packets.response(code: code, tid: tid, rc: Fuji.invalidObject))
            }
            let payload = objectInfo(handle)
            return .bytes(Packets.dataPhase(code: code, tid: tid, payload: payload)
                + Packets.response(code: code, tid: tid))
        case Fuji.getPartial:
            let handle = Int(params.first ?? 0)
            let offset = Int(params.count > 1 ? params[1] : 0)
            let ask = Int(params.count > 2 ? params[2] : 0)
            guard frames.contains(where: { $0.handle == handle }) else {
                return .bytes(Packets.response(code: code, tid: tid, rc: Fuji.invalidObject))
            }
            partials.append((handle, offset, ask))
            return partial(handle: handle, offset: offset, ask: ask, code: code, tid: tid)
        default:
            return .bytes(Packets.response(code: code, tid: tid))
        }
    }

    /// Test hook: the next window comes back this short, like a body that answers less than it was asked.
    var shortWindow: Int?

    private func partial(handle: Int, offset: Int, ask: Int, code: UInt16, tid: UInt32) -> Reply {
        let total = frames.first { $0.handle == handle }?.bytes ?? ask
        let remain = max(0, total - offset)
        var give = min(ask, remain)
        if let short = shortWindow, short < give {
            shortWindow = nil
            give = short
        }
        if stallArmed && give > Fuji.stallBytes {
            stallArmed = false
            let payload = Data(count: Fuji.stallBytes)
            return .stall(Packets.dataPhase(code: code, tid: tid, payload: payload))
        }
        let payload = Data(count: give)
        return .bytes(Packets.dataPhase(code: code, tid: tid, payload: payload)
            + Packets.response(code: code, tid: tid))
    }

    private func propValue(_ prop: UInt32) -> Data {
        switch prop {
        case Fuji.events:
            // Count, then {code, value}. D222 is first on purpose: a client that
            // reads a u32 at offset 4 would treat the object count as DF00.
            var data = Data(count: 14)
            LE.put16(&data, 0, 2)
            LE.put16(&data, 2, UInt16(Fuji.objectCount & 0xffff))
            LE.put32(&data, 4, UInt32(frames.count))
            LE.put16(&data, 8, UInt16(Fuji.cameraState & 0xffff))
            LE.put32(&data, 10, cameraState)
            return data
        case Fuji.objectVersion, Fuji.remoteVersion:
            return LE.data32(0x0002_000c)
        case Fuji.remoteObjectVersion:
            return LE.data32(5)
        case Fuji.imageGetVersion:
            return LE.data32(0x0002_000a)
        case Fuji.remotePhotoView:
            return LE.data32(1)
        case Fuji.importCount:
            return LE.data32(UInt32(frames.count))
        case Fuji.importHandles:
            let handles = listedHandles ?? frames.map(\.handle)
            return FujiArray.encode(handles)
        default:
            return LE.data32(0)
        }
    }

    private func applySet(_ prop: UInt32, _ payload: Data) {
        let value: UInt16
        if payload.count >= 2 {
            value = LE.u16(payload, 0)
        } else {
            value = 0
        }
        if prop == Fuji.correctSize {
            correctSize = value
        }
        if prop == Fuji.compressSmall {
            compressSmall = value
        }
    }

    private func objectInfo(_ handle: Int) -> Data {
        let frame = frames.first { $0.handle == handle }
        let real = frame?.bytes ?? 0
        let reported = (faults.lieAboutSize && correctSize == 0) ? Fuji.liedSize : real
        infoSeen.append((handle, compressSmall, correctSize, reported))
        return ObjectInfo.payload(name: frame?.name ?? "", bytes: reported, maxPartial: Fuji.partialMax)
    }

    private func paramsOf(_ packet: Data) -> [UInt32] {
        guard packet.count >= 12 else { return [] }
        var params: [UInt32] = []
        var offset = 12
        while offset + 4 <= packet.count {
            params.append(LE.u32(packet, offset))
            offset += 4
        }
        return params
    }
}

final class VirtualLink: ByteLink, @unchecked Sendable {
    let body: VirtualBody
    private var incoming = Data()
    private var outgoing = Data()
    private var stalled = false

    init(body: VirtualBody) {
        self.body = body
    }

    func open() async throws {
        incoming.removeAll()
        outgoing.removeAll()
        stalled = false
        body.noteConnect()
    }

    func close() async {
        incoming.removeAll()
        outgoing.removeAll()
        stalled = false
    }

    func write(_ data: Data) async throws {
        incoming.append(data)
        while incoming.count >= 4 {
            let length = Int(LE.u32(incoming, 0))
            if length < 4 || incoming.count < length { return }
            let packet = incoming.subdata(in: incoming.startIndex..<(incoming.startIndex + length))
            incoming = incoming.subdata(in: (incoming.startIndex + length)..<incoming.endIndex)
            switch body.handle(packet) {
            case .silent:
                break
            case .bytes(let bytes):
                outgoing.append(bytes)
            case .stall(let bytes):
                outgoing.append(bytes)
                stalled = true
            }
        }
    }

    func read(count: Int) async throws -> Data {
        if outgoing.count < count {
            if stalled { throw LinkError.stalled }
            throw LinkError.shortRead
        }
        let chunk = outgoing.subdata(in: outgoing.startIndex..<(outgoing.startIndex + count))
        outgoing = outgoing.subdata(in: (outgoing.startIndex + count)..<outgoing.endIndex)
        return chunk
    }
}
