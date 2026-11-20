import CoreAudio
import Foundation

/// A process currently running an output stream in Core Audio.
public struct AudioProcess: Equatable, Sendable {
    /// The Core Audio process object identifier.
    public let id: UInt32
    /// The system process identifier.
    public let pid: Int32
    /// The process bundle identifier reported by Core Audio, when available.
    public let bundleID: String?
    /// The device identifiers on which this process is playing audio.
    public let outputDevices: [UInt32]

    /// Creates a value representing an observed output process.
    public init(id: UInt32, pid: Int32, bundleID: String?, outputDevices: [UInt32]) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.outputDevices = outputDevices
    }
}

/// The types of failure for which the UI can offer recovery.
public enum MixerAudioError: Error, Equatable, Sendable {
    /// The application no longer has active audio.
    case sourceStopped
    /// The active route cannot safely pass the tap through.
    case unsupportedRoute
    /// macOS rejected capture or the tap could not provide usable audio.
    case captureUnavailable
}

enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain
        )
    }

    static func read<T>(
        _ object: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        into value: inout T
    ) -> Bool {
        var address = address
        var size = UInt32(MemoryLayout<T>.size)
        let expectedSize = size
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, UnsafeMutableRawPointer(pointer))
        }
        return status == noErr && size == expectedSize
    }

    static func objects(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> [AudioObjectID]? {
        var address = address(selector, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr,
              size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.stride)),
              size <= 1_048_576 else { return nil }
        if size == 0 { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.stride
        var values = [AudioObjectID](repeating: 0, count: count)
        let status = values.withUnsafeMutableBufferPointer { pointer in
            guard let base = pointer.baseAddress else { return kAudioHardwareBadPropertySizeError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
        }
        guard status == noErr, size <= count * MemoryLayout<AudioObjectID>.stride,
              size.isMultiple(of: UInt32(MemoryLayout<AudioObjectID>.stride)) else { return nil }
        return Array(values.prefix(Int(size) / MemoryLayout<AudioObjectID>.stride))
    }

    static func string(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> String? {
        var value: Unmanaged<CFString>?
        guard read(object, address(selector), into: &value) else { return nil }
        return value?.takeRetainedValue() as String?
    }

    static func outputProcesses() -> [AudioProcess] {
        let ids = objects(system, kAudioHardwarePropertyProcessObjectList) ?? []
        return ids.compactMap { id in
            var running: UInt32 = 0
            var pid: pid_t = 0
            guard read(id, address(kAudioProcessPropertyIsRunningOutput), into: &running),
                  running == 1,
                  read(id, address(kAudioProcessPropertyPID), into: &pid),
                  pid > 0, pid != getpid() else { return nil }
            let devices = objects(id, kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput) ?? []
            return AudioProcess(id: id, pid: pid,
                                bundleID: string(id, kAudioProcessPropertyBundleID),
                                outputDevices: devices)
        }
    }

    static func audioFormat(
        _ object: AudioObjectID, _ selector: AudioObjectPropertySelector
    ) -> AudioStreamBasicDescription? {
        var format = AudioStreamBasicDescription()
        guard read(object, address(selector), into: &format) else { return nil }
        return format
    }

    static func streamBuffers(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> [UInt32]? {
        var address = address(kAudioDevicePropertyStreamConfiguration, scope: scope)
        var size: UInt32 = 0
        let firstBufferOffset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.stride
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= firstBufferOffset, size <= 65_536 else { return nil }
        let capacity = size
        let storage = UnsafeMutableRawPointer.allocate(
            byteCount: max(Int(capacity), MemoryLayout<AudioBufferList>.size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr,
              size >= firstBufferOffset, size <= capacity else { return nil }
        let list = storage.assumingMemoryBound(to: AudioBufferList.self)
        let count = Int(list.pointee.mNumberBuffers)
        guard count <= (Int(size) - firstBufferOffset) / MemoryLayout<AudioBuffer>.stride else { return nil }
        return UnsafeMutableAudioBufferListPointer(list).map(\.mNumberChannels)
    }
}

/// A single output route is necessary to play the tapped signal on its original device.
func commonOutputDevice(in lists: [[UInt32]]) -> UInt32? {
    guard let first = lists.first, first.count == 1, let device = first.first, device != 0,
          lists.allSatisfy({ $0 == first }) else { return nil }
    return device
}

struct Route: Equatable {
    let id: AudioObjectID
    let uid: String
    let stream: AudioStreamID
    let layout: PCMLayout

    init?(id: AudioObjectID) {
        guard let uid = HAL.string(id, kAudioDevicePropertyDeviceUID), !uid.isEmpty,
              HAL.objects(id, kAudioDevicePropertyStreams,
                          scope: kAudioObjectPropertyScopeInput) == [],
              let streams = HAL.objects(id, kAudioDevicePropertyStreams,
                                        scope: kAudioObjectPropertyScopeOutput),
              streams.count == 1, let stream = streams.first,
              let format = HAL.audioFormat(stream, kAudioStreamPropertyVirtualFormat),
              let layout = PCMLayout(format),
              HAL.streamBuffers(id, scope: kAudioObjectPropertyScopeOutput) == layout.bufferChannels
        else { return nil }
        self.id = id
        self.uid = uid
        self.stream = stream
        self.layout = layout
    }
}

struct PCMLayout: Equatable {
    let channelCount: Int
    let bufferCount: Int
    let sampleRate: Double

    var channelsPerBuffer: Int { channelCount / bufferCount }
    var bufferChannels: [UInt32] {
        Array(repeating: UInt32(channelsPerBuffer), count: bufferCount)
    }

    init?(_ format: AudioStreamBasicDescription) {
        let supportedFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked |
                             kAudioFormatFlagIsNonInterleaved
        let requiredFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked
        guard format.mFormatID == kAudioFormatLinearPCM, format.mBitsPerChannel == 32,
              format.mFormatFlags & requiredFlags == requiredFlags,
              format.mFormatFlags & ~supportedFlags == 0,
              (1...32).contains(format.mChannelsPerFrame),
              format.mSampleRate.isFinite, format.mSampleRate > 0 else { return nil }
        let channels = Int(format.mChannelsPerFrame)
        let buffers = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : channels
        guard format.mBytesPerFrame == MemoryLayout<Float>.size * channels / buffers else { return nil }
        channelCount = channels
        bufferCount = buffers
        sampleRate = format.mSampleRate
    }
}
