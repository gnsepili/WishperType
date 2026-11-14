@preconcurrency import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

struct MicrophoneDevice: Identifiable, Hashable {
    let id: String
    let name: String
}

struct AudioRecording {
    let url: URL
    let duration: Double
    let hasSpeech: Bool
}

@MainActor
final class AudioRecorder {
    var onLevel: ((Float) -> Void)?
    /// Runs on the audio processing queue. Do not block or synchronously dispatch to main.
    var onPCM: (@Sendable (Data) -> Void)? {
        didSet { writer?.setPCMHandler(onPCM) }
    }
    var onFailure: ((String) -> Void)?
    var permissionGranted: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }

    private var engine: AVAudioEngine?
    private var writer: CaptureWriter?
    private var configurationObserver: NSObjectProtocol?
    private var recordingID: UUID?
    private var tapInstalled = false
    private var lastLevelTime: UInt64 = 0

    static func microphones() -> [MicrophoneDevice] {
        CaptureDevices.inputs().compactMap { device in
            guard let uid = CaptureDevices.string(device, selector: kAudioDevicePropertyDeviceUID),
                  let name = CaptureDevices.string(device, selector: kAudioObjectPropertyName) else { return nil }
            return MicrophoneDevice(id: uid, name: name)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func requestPermission() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return true
        case .notDetermined: return await AVCaptureDevice.requestAccess(for: .audio)
        default: return false
        }
    }

    func start(at url: URL, deviceID: String) throws {
        guard writer == nil else { throw CaptureFailure("A recording is already in progress.") }
        guard permissionGranted else { throw CaptureFailure("Microphone permission is required to record audio.") }
        guard url.isFileURL, url.pathExtension.lowercased() == "m4a" else {
            throw CaptureFailure("The audio recording destination must be a local .m4a file.")
        }
        var device: AudioDeviceID
        if deviceID.isEmpty {
            var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
            device = kAudioObjectUnknown
            var size = UInt32(MemoryLayout<AudioDeviceID>.size)
            guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                             &size, &device) == noErr else {
                throw CaptureFailure("The default microphone is unavailable.")
            }
        } else {
            guard let selected = CaptureDevices.inputs().first(where: {
                CaptureDevices.string($0, selector: kAudioDevicePropertyDeviceUID) == deviceID
            }) else { throw CaptureFailure("The selected microphone is disconnected or unavailable.") }
            device = selected
        }
        guard device != kAudioObjectUnknown, CaptureDevices.hasInput(device), CaptureDevices.hasSampleRate(device) else {
            throw CaptureFailure("No usable microphone is available. Connect an input device and try again.")
        }

        let engine = AVAudioEngine()
        let input = engine.inputNode
        guard let audioUnit = input.audioUnit else { throw CaptureFailure("The microphone audio unit is unavailable.") }
        let status = AudioUnitSetProperty(audioUnit, kAudioOutputUnitProperty_CurrentDevice,
                                          kAudioUnitScope_Global, 0, &device,
                                          UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw CaptureFailure("Could not select the microphone (Core Audio \(status)).") }
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate.isFinite, format.sampleRate > 0, format.channelCount > 0 else {
            throw CaptureFailure("The microphone reported an invalid audio format. Reconnect it and try again.")
        }

        let id = UUID()
        let writer = try CaptureWriter(url: url, inputFormat: format, onPCM: onPCM, onLevel: { [weak self] level in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recordingID == id else { return }
                let now = DispatchTime.now().uptimeNanoseconds
                guard now - self.lastLevelTime >= 50_000_000 else { return }
                self.lastLevelTime = now
                self.onLevel?(level)
            }
        }, onFailure: { [weak self] message in
            DispatchQueue.main.async { [weak self] in
                guard let self, self.recordingID == id else { return }
                _ = self.endRecording(discard: false, failure: message)
            }
        })
        self.engine = engine
        self.writer = writer
        recordingID = id
        lastLevelTime = 0
        input.installTap(onBus: 0, bufferSize: 1_024, format: format) { buffer, _ in
            writer.enqueue(buffer)
        }
        tapInstalled = true
        do {
            engine.prepare()
            try engine.start()
            configurationObserver = NotificationCenter.default.addObserver(
                forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
            ) { [weak self] _ in
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.recordingID == id else { return }
                    _ = self.endRecording(discard: false,
                                         failure: "The microphone configuration changed or the device disconnected. Please record again.")
                }
            }
        } catch {
            _ = endRecording(discard: true)
            throw CaptureFailure("Could not start microphone capture: \(error.localizedDescription)")
        }
    }

    /// Closes the input gate and synchronously drains conversion, file writes and
    /// PCM callbacks, including the converter's tail, before the file is returned.
    func stop() -> AudioRecording? { endRecording(discard: false) }

    func cancel() { _ = endRecording(discard: true) }

    private func endRecording(discard: Bool, failure: String? = nil) -> AudioRecording? {
        guard let writer else { return nil }
        recordingID = nil
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        tapInstalled = false
        engine = nil
        self.writer = nil
        let result = writer.finish(discard: discard)
        if !discard, let message = result.failure ?? failure { onFailure?(message) }
        return discard ? nil : result.recording
    }

    deinit {
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        engine?.stop()
        if tapInstalled { engine?.inputNode.removeTap(onBus: 0) }
        _ = writer?.finish(discard: true)
    }
}

private struct CaptureFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private enum CaptureDevices {
    static func inputs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var devices = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        let status = devices.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return devices.prefix(Int(size) / MemoryLayout<AudioDeviceID>.size).filter { hasInput($0) }
    }

    static func string(_ device: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func hasInput(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration,
                                                mScope: kAudioDevicePropertyScopeInput,
                                                mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= MemoryLayout<AudioBufferList>.size else { return false }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, memory) == noErr else { return false }
        let buffers = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self))
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    static func hasSampleRate(_ device: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate,
                                                mScope: kAudioObjectPropertyScopeGlobal,
                                                mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr && rate.isFinite && rate > 0
    }
}

/// The gate protects tap submissions; everything else (including mutable PCM
/// callbacks) belongs exclusively to queue. Tap-owned buffers are copied before return.
private final class CaptureWriter: @unchecked Sendable {
    // Ownership transfers from the tap to queue. The converter invokes its input
    // block synchronously on that queue, so supplied is never accessed concurrently.
    private final class InputBuffer: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
        var supplied = false
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    private let queue = DispatchQueue(label: "WhisperType.audio-writer", qos: .userInitiated)
    private let gate = NSLock()
    private var accepting = true
    private var queuedBuffers = 0
    private let url: URL
    private let outputFormat: AVAudioFormat
    private let onLevel: @Sendable (Float) -> Void
    private let onFailure: @Sendable (String) -> Void
    private var onPCM: (@Sendable (Data) -> Void)?
    private var converter: AVAudioConverter?
    private var file: AVAudioFile?
    private var inputFrameCount: Int64 = 0
    private var frameCount: Int64 = 0
    private var activeFrames: Int64 = 0
    private var failure: String?
    private var pendingPCM = Data()
    private var lastEmission = DispatchTime.now().uptimeNanoseconds
    private var ended = false

    init(url: URL, inputFormat: AVAudioFormat, onPCM: (@Sendable (Data) -> Void)?,
         onLevel: @escaping @Sendable (Float) -> Void, onFailure: @escaping @Sendable (String) -> Void) throws {
        self.url = url
        self.onPCM = onPCM
        self.onLevel = onLevel
        self.onFailure = onFailure
        guard let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 24_000,
                                               channels: 1, interleaved: false) else {
            throw CaptureFailure("Could not create the recording audio format.")
        }
        self.outputFormat = outputFormat
        try queue.sync {
            guard let converter = AVAudioConverter(from: inputFormat, to: outputFormat) else {
                throw CaptureFailure("The microphone format cannot be converted to 24 kHz mono audio.")
            }
            converter.downmix = inputFormat.channelCount > 1
            converter.primeMethod = .none
            self.converter = converter
            file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderBitRateKey: 64_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ], commonFormat: .pcmFormatFloat32, interleaved: false)
        }
    }

    func setPCMHandler(_ handler: (@Sendable (Data) -> Void)?) {
        queue.async { if !self.ended { self.onPCM = handler } }
    }

    func enqueue(_ buffer: AVAudioPCMBuffer) {
        gate.lock()
        defer { gate.unlock() }
        guard accepting, buffer.frameLength > 0 else { return }
        guard queuedBuffers < 256 else {
            accepting = false
            queue.async { self.reportFailure("Audio processing could not keep up with the microphone.") }
            return
        }
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else {
            accepting = false
            queue.async { self.reportFailure("Could not allocate a microphone audio buffer.") }
            return
        }
        copy.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let destination = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard source.count == destination.count else {
            accepting = false
            queue.async { self.reportFailure("The microphone audio format changed during recording.") }
            return
        }
        for index in source.indices {
            guard let from = source[index].mData, let to = destination[index].mData,
                  source[index].mDataByteSize <= destination[index].mDataByteSize else {
                accepting = false
                queue.async { self.reportFailure("The microphone returned an invalid audio buffer.") }
                return
            }
            memcpy(to, from, Int(source[index].mDataByteSize))
            destination[index].mDataByteSize = source[index].mDataByteSize
        }
        queuedBuffers += 1
        let owned = InputBuffer(copy)
        queue.async {
            defer {
                self.gate.lock()
                self.queuedBuffers -= 1
                self.gate.unlock()
            }
            guard self.failure == nil, !self.ended else { return }
            autoreleasepool { self.convert(owned) }
        }
    }

    func finish(discard: Bool) -> (recording: AudioRecording, failure: String?) {
        gate.lock()
        accepting = false
        gate.unlock()
        return queue.sync {
            if !ended {
                if !discard, failure == nil { convert(nil) }
                if !discard, !pendingPCM.isEmpty { onPCM?(pendingPCM) }
                pendingPCM.removeAll()
                onPCM = nil
                converter = nil
                // AVAudioFile finalizes the AAC container on release, on this queue.
                file = nil
                ended = true
                if discard { try? FileManager.default.removeItem(at: url) }
            }
            return (AudioRecording(url: url, duration: Double(frameCount) / 24_000,
                                   hasSpeech: activeFrames >= 1_200), failure)
        }
    }

    private func convert(_ input: InputBuffer?) {
        guard let converter else { return }
        if let input { inputFrameCount += Int64(input.buffer.frameLength) }
        let capacity = AVAudioFrameCount(max(2_048, ceil(Double(input?.buffer.frameLength ?? 0)
                                                       * 24_000 / converter.inputFormat.sampleRate) + 512))
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            reportFailure("Could not allocate a resampled audio buffer.")
            return
        }
        while failure == nil {
            output.frameLength = 0
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                if let input, !input.supplied {
                    input.supplied = true
                    inputStatus.pointee = .haveData
                    return input.buffer
                }
                // noDataNow preserves converter state across taps; only stop sends EOF.
                inputStatus.pointee = input == nil ? .endOfStream : .noDataNow
                return nil
            }
            guard status != .error, error == nil else {
                reportFailure("Audio conversion failed: \(error?.localizedDescription ?? "unknown converter error")")
                return
            }
            let producedFrames = output.frameLength
            if input == nil {
                // The resampler can emit filter padding at EOF. Keep file duration
                // and streamed PCM tied to captured frames, not that synthetic tail.
                let expectedFrames = Int64((Double(inputFrameCount) * 24_000 / converter.inputFormat.sampleRate).rounded())
                output.frameLength = AVAudioFrameCount(min(Int64(producedFrames), max(0, expectedFrames - frameCount)))
            }
            if output.frameLength > 0 { write(output) }
            switch status {
            case .haveData:
                guard producedFrames > 0 else {
                    reportFailure("The audio converter stopped making progress.")
                    return
                }
            case .inputRanDry, .endOfStream: return
            case .error: return
            @unknown default:
                reportFailure("The audio converter returned an unsupported status.")
                return
            }
        }
    }

    private func write(_ buffer: AVAudioPCMBuffer) {
        guard let file, let samples = buffer.floatChannelData?[0] else {
            reportFailure("The recording audio buffer is unavailable.")
            return
        }
        let count = Int(buffer.frameLength)
        var energy: Double = 0
        var peak: Float = 0
        var pcm = Data(count: count * 2)
        pcm.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            for index in 0..<count {
                let sample = samples[index].isFinite ? max(-1, min(1, samples[index])) : 0
                samples[index] = sample
                energy += Double(sample) * Double(sample)
                peak = max(peak, abs(sample))
                let value = Int16(max(-32_768, min(32_767, (sample * 32_768).rounded())))
                let bits = UInt16(bitPattern: value)
                bytes[index * 2] = UInt8(truncatingIfNeeded: bits)
                bytes[index * 2 + 1] = UInt8(truncatingIfNeeded: bits >> 8)
            }
        }
        do { try file.write(from: buffer) }
        catch {
            reportFailure("Could not write the audio recording: \(error.localizedDescription)")
            return
        }
        frameCount += Int64(count)
        let rms = sqrt(energy / Double(max(1, count)))
        if rms >= 0.00015 || (peak >= 0.001 && rms >= 0.0001) { activeFrames += Int64(count) }
        pendingPCM.append(pcm)
        let now = DispatchTime.now().uptimeNanoseconds
        if now - lastEmission >= 50_000_000 {
            lastEmission = now
            let level = Float(max(0, min(1, (20 * log10(max(rms, 0.000001)) + 70) / 64)))
            onLevel(level)
            onPCM?(pendingPCM)
            pendingPCM.removeAll(keepingCapacity: true)
        }
    }

    private func reportFailure(_ message: String) {
        guard failure == nil else { return }
        failure = message
        onFailure(message)
    }
}
