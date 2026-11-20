import CoreAudio
import Foundation

/// Owns private Core Audio taps and device registrations away from the UI actor.
public actor AudioMixer {
    private var sessions: [String: TapSession] = [:]
    private var retiring: [TapSession] = []
    private var shuttingDown = false
    private var captureVerified = false

    /// Starts with no capture and does not prompt for permissions.
    public init() {}

    /// Returns active output process records without reading audio samples.
    public func activeProcesses() -> [AudioProcess] {
        retryCleanup()
        return HAL.outputProcesses()
    }

    /// Changes the gain of a logical application, using only its current output processes.
    public func setGain(_ gain: Gain, appID: String, processes: [AudioProcess]) async throws {
        try Task.checkCancellation()
        guard !shuttingDown else { throw CancellationError() }
        if gain == .unity {
            if let session = sessions[appID], session.isPlaying {
                // Allow a few hardware buffers to complete the ramp to unity before
                // returning playback to the original process.
                session.apply(gain)
            } else {
                remove(appID)
            }
            return
        }

        let live = HAL.outputProcesses()
        let processIDs = Set(processes.map(\.id))
        let sources = live.filter { candidate in
            processes.contains { $0.id == candidate.id && $0.pid == candidate.pid }
        }
        guard !sources.isEmpty, sources.count == processIDs.count else { throw MixerAudioError.sourceStopped }
        guard let device = commonOutputDevice(in: sources.map(\.outputDevices)),
              let route = Route(id: device) else { throw MixerAudioError.unsupportedRoute }

        let session: TapSession
        if let current = sessions[appID], current.processes == processIDs, current.route == route {
            session = current
            session.apply(gain)
        } else {
            remove(appID)
            // Never install a second tap over a process while an older registration is
            // still being cleaned up.
            retryCleanup()
            guard !retiring.contains(where: { !$0.processes.isDisjoint(with: processIDs) })
            else { throw MixerAudioError.captureUnavailable }
            session = TapSession(processes: processIDs, route: route)
            sessions[appID] = session
            do {
                try session.configure(gain: gain)
            } catch {
                remove(appID)
                throw error
            }
        }

        do {
            let deadline = ContinuousClock.now + .seconds(captureVerified ? 3 : 30)
            while ContinuousClock.now < deadline {
                try Task.checkCancellation()
                guard sessions[appID] === session else { throw CancellationError() }
                if session.isPlaying { return }
                if session.renderFailed { break }
                if session.hasInputSignal {
                    try session.enablePlayback()
                    captureVerified = true
                    return
                }
                try await Task.sleep(for: .milliseconds(40))
            }
            throw MixerAudioError.captureUnavailable
        } catch {
            if !(error is CancellationError), sessions[appID] === session { remove(appID) }
            throw error
        }
    }

    /// Removes sessions whose sources or output routes changed, and flags render failures.
    public func reconcile(_ sources: [String: [AudioProcess]]) -> [String: MixerAudioError] {
        var errors: [String: MixerAudioError] = [:]
        for (key, session) in sessions {
            let group = sources[key] ?? []
            guard Set(group.map(\.id)) == session.processes,
                  let device = commonOutputDevice(in: group.map(\.outputDevices)),
                  let route = Route(id: device), route == session.route else {
                remove(key)
                errors[key] = .sourceStopped
                continue
            }
            if session.isPlaying && !session.live {
                remove(key)
                errors[key] = .captureUnavailable
            }
        }
        return errors
    }

    /// Releases a unity-gain session after the ramp finishes.
    public func releaseAtUnity(appID: String) {
        if sessions[appID]?.gain == .unity { remove(appID) }
    }

    /// Stops callbacks and destroys all private HAL objects before orderly termination.
    public func shutdown() {
        shuttingDown = true
        for key in Array(sessions.keys) {
            remove(key)
        }
        retryCleanup()
    }

    private func remove(_ key: String) {
        guard let session = sessions.removeValue(forKey: key) else { return }
        if !session.dispose() {
            retiring.append(session)
        }
    }

    private func retryCleanup() {
        retiring.removeAll { $0.dispose() }
    }
}
