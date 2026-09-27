// winrec.swift OWNER SECONDS OUT.mov — records one app window (largest window of OWNER) with ScreenCaptureKit.
import AppKit
import AVFoundation
import CoreMedia
import ScreenCaptureKit

_ = NSApplication.shared
let args = CommandLine.arguments
let owner = args[1], seconds = Double(args[2])!, out = URL(fileURLWithPath: args[3])

final class Recorder: NSObject, SCStreamOutput {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    var started = false
    init(url: URL, width: Int, height: Int) throws {
        try? FileManager.default.removeItem(at: url)
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 30_000_000],
        ])
        input.expectsMediaDataInRealTime = true
        writer.add(input)
    }
    func stream(_ stream: SCStream, didOutputSampleBuffer buffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, buffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attachments.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        if !started {
            writer.startWriting()
            writer.startSession(atSourceTime: buffer.presentationTimeStamp)
            started = true
        }
        if input.isReadyForMoreMediaData { input.append(buffer) }
    }
}

let done = DispatchSemaphore(value: 0)
Task {
    do {
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        let mine = content.windows.filter { w in
            let app = w.owningApplication
            return (app?.applicationName == owner || app?.bundleIdentifier == "md.thomas.fujibridge") && w.windowLayer == 0
        }
        guard let window = mine.max(by: { $0.frame.height < $1.frame.height }) else {
            print("no window; apps:", Set(content.windows.compactMap { $0.owningApplication?.applicationName }).sorted()); exit(1)
        }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = Double(filter.pointPixelScale)
        let width = Int(window.frame.width * scale) / 2 * 2, height = Int(window.frame.height * scale) / 2 * 2
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.showsCursor = false
        config.capturesAudio = false
        let recorder = try Recorder(url: out, width: width, height: height)
        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(recorder, type: .screen, sampleHandlerQueue: DispatchQueue(label: "rec"))
        try await stream.startCapture()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await stream.stopCapture()
        recorder.input.markAsFinished()
        await recorder.writer.finishWriting()
        print("wrote \(out.path) \(width)x\(height)")
    } catch {
        print("error: \(error)")
    }
    done.signal()
}
done.wait()
