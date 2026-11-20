import CoreAudio
import Foundation
import OSLog
import RTAtomic

final class TapSession {
    private static let logger = Logger(subsystem: "com.orfeus.macos", category: "Audio")

    let processes: Set<AudioObjectID>
    let route: Route
    private var tap: AudioObjectID = 0
    private var device: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var state: UnsafeMutablePointer<RenderState>?
    private var atomics: OpaquePointer?
    private var description: CATapDescription?
    private var started = false
    private(set) var isPlaying = false
    private(set) var gain: Gain = .unity

    private var lastCallbackCount: UInt32 = 0
    private var lastCallbackChange = ContinuousClock.now

    init(processes: Set<AudioObjectID>, route: Route) {
        self.processes = processes
        self.route = route
    }

    func configure(gain: Gain) throws {
        self.gain = gain
        // This process-specific tap stays unmuted until capture proves that it receives
        // audio. Denied permission or a stream that goes quiet leaves playback intact.
        let description = CATapDescription(processes: processes.sorted(), deviceUID: route.uid, stream: 0)
        description.name = "Orfeus"
        description.isPrivate = true
        description.muteBehavior = .unmuted
        self.description = description
        guard check(AudioHardwareCreateProcessTap(description, &tap), operation: "create tap"),
              tap != 0,
              let tapUID = HAL.string(tap, kAudioTapPropertyUID),
              let format = HAL.audioFormat(tap, kAudioTapPropertyFormat),
              PCMLayout(format) == route.layout else { throw MixerAudioError.captureUnavailable }

        let configuration: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Orfeus",
            kAudioAggregateDeviceUIDKey: "com.orfeus.macos." + UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: route.uid,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: route.uid]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: tapUID,
                                              kAudioSubTapDriftCompensationKey: true]],
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: false
        ]
        guard check(AudioHardwareCreateAggregateDevice(configuration as CFDictionary, &device),
                    operation: "create aggregate"),
              device != 0 else { throw MixerAudioError.unsupportedRoute }

        // The route excludes physical input streams. Validate that the aggregate
        // exposes precisely the private tap as input.
        let tapChannels = route.layout.bufferChannels
        guard HAL.streamBuffers(device, scope: kAudioObjectPropertyScopeInput) == tapChannels,
              HAL.streamBuffers(device, scope: kAudioObjectPropertyScopeOutput) == tapChannels,
              let atomics = mixer_atomics_create(gain.value) else { throw MixerAudioError.unsupportedRoute }

        let state = UnsafeMutablePointer<RenderState>.allocate(capacity: 1)
        state.initialize(to: RenderState(atomic: atomics, tapBufferCount: route.layout.bufferCount,
                                        channelsPerBuffer: route.layout.channelsPerBuffer))
        self.atomics = atomics
        self.state = state

        guard check(AudioDeviceCreateIOProcID(device, renderAudio, state, &ioProc), operation: "install callback"),
              let ioProc,
              check(AudioDeviceStart(device, ioProc), operation: "start callback") else {
            throw MixerAudioError.captureUnavailable
        }
        started = true
    }

    var hasInputSignal: Bool {
        guard let atomics else { return false }
        return mixer_signal_present(atomics) != 0
    }

    var renderFailed: Bool {
        guard let atomics else { return true }
        return mixer_render_failed(atomics) != 0
    }

    var live: Bool {
        guard let atomics else { return false }
        let count = mixer_callback_count(atomics)
        if lastCallbackCount != count {
            lastCallbackCount = count
            lastCallbackChange = .now
        }
        return !renderFailed && ContinuousClock.now - lastCallbackChange < .seconds(3)
    }

    func enablePlayback() throws {
        guard let description, let atomics else { throw MixerAudioError.captureUnavailable }
        description.muteBehavior = .mutedWhenTapped
        var address = HAL.address(kAudioTapPropertyDescription)
        let reference = Unmanaged.passUnretained(description)
        let status = withUnsafePointer(to: reference) { pointer in
            AudioObjectSetPropertyData(tap, &address, 0, nil,
                                       UInt32(MemoryLayout.size(ofValue: reference)),
                                       UnsafeRawPointer(pointer))
        }
        guard check(status, operation: "enable attenuated playback") else {
            throw MixerAudioError.captureUnavailable
        }
        mixer_playback_enable(atomics)
        isPlaying = true
    }

    func apply(_ gain: Gain) {
        self.gain = gain
        if let atomics { mixer_gain_store(atomics, gain.value) }
    }

    /// Retain callback memory if the HAL could not detach the IOProc. The owner
    /// retries cleanup without letting an active IOProc touch freed storage.
    @discardableResult
    func dispose() -> Bool {
        if let ioProc {
            if started, check(AudioDeviceStop(device, ioProc), operation: "stop callback") {
                started = false
            }
            if check(AudioDeviceDestroyIOProcID(device, ioProc), operation: "detach callback") {
                self.ioProc = nil
                started = false
            }
        }
        if device != 0, check(AudioHardwareDestroyAggregateDevice(device), operation: "destroy aggregate") {
            device = 0
            ioProc = nil
            started = false
        }
        if tap != 0, check(AudioHardwareDestroyProcessTap(tap), operation: "destroy tap") {
            tap = 0
            description = nil
        }
        if ioProc == nil {
            if let state {
                state.deinitialize(count: 1)
                state.deallocate()
                self.state = nil
            }
            if let atomics {
                mixer_atomics_destroy(atomics)
                self.atomics = nil
            }
        }
        return tap == 0 && device == 0 && ioProc == nil
    }

    private func check(_ status: OSStatus, operation: StaticString) -> Bool {
        if status == noErr { return true }
        Self.logger.error("Core Audio operation \(operation, privacy: .public) returned \(status, privacy: .public)")
        return false
    }
}
