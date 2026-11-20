import AudioCore
import Foundation
import Observation

protocol AudioControlling: Sendable {
    func activeProcesses() async -> [AudioProcess]
    func setGain(_ gain: Gain, appID: String, processes: [AudioProcess]) async throws
    func reconcile(_ sources: [String: [AudioProcess]]) async -> [String: MixerAudioError]
    func releaseAtUnity(appID: String) async
    func shutdown() async
}

extension AudioMixer: AudioControlling {}

/// The interface's open apps, current gains, and contextual recovery state.
@MainActor
@Observable
public final class MixerModel {
    /// A failure the user can address from the menu.
    public enum Issue: Equatable {
        /// Audio could not be captured. macOS may need to grant access.
        case captureUnavailable
        /// The current physical route cannot safely play back the tapped audio.
        case unsupportedRoute
    }

    /// Open applications that are playing or are likely to play audio.
    public private(set) var sources: [ActiveSource] = []
    /// Most recent actionable failure, shown only after a mixer adjustment.
    public private(set) var issue: Issue?

    private var desired: [String: Gain] = [:]
    private var selected: [String: Gain] = [:]
    private var applied: [String: Gain] = [:]
    @ObservationIgnored private let audio: any AudioControlling
    @ObservationIgnored private let applications: @MainActor () -> [OpenApplication]
    @ObservationIgnored private let preferences: VolumePreferences
    @ObservationIgnored private var monitor: Task<Void, Never>?
    @ObservationIgnored private var refreshing = false
    @ObservationIgnored private var shuttingDown = false
    @ObservationIgnored private var updates: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private var blocked: [String: ActiveSource] = [:]
    @ObservationIgnored private var previouslyObserved = Set<String>()
    private var activatedThisLaunch = false
    @ObservationIgnored private var automaticCaptureBlocked = false
    @ObservationIgnored private var deferredRetryID: String?

    /// Creates a mixer without opening any audio taps.
    public convenience init(defaults: UserDefaults = .standard) {
        self.init(defaults: defaults, audio: AudioMixer(), applications: openApplications)
    }

    init(defaults: UserDefaults, audio: any AudioControlling,
         applications: @escaping @MainActor () -> [OpenApplication]) {
        self.audio = audio
        self.applications = applications
        preferences = VolumePreferences(defaults: defaults)
    }

    /// Begins observing output activity without requesting capture.
    public func start() {
        guard monitor == nil else { return }
        monitor = Task { [weak self] in
            while !Task.isCancelled {
                guard self != nil else { return }
                await self?.refresh()
                try? await Task.sleep(for: .milliseconds(550))
            }
        }
    }

    /// Refreshes the menu immediately when the user opens it.
    public func refresh() async {
        guard !refreshing, !shuttingDown else { return }
        refreshing = true
        defer { refreshing = false }
        let processes = await audio.activeProcesses()
        await refresh(processes)
    }

    /// Returns the current slider position on its normalized scale.
    public func volume(for source: ActiveSource) -> Double {
        let saved = activatedThisLaunch ? preferences.gain(for: source.persistenceKey) : .unity
        return Double((desired[source.id] ?? selected[source.id] ?? applied[source.id] ?? saved).value)
    }

    /// Applies a deliberate user adjustment and triggers permission in context if needed.
    public func setVolume(_ value: Double, for source: ActiveSource) {
        guard !shuttingDown, let current = sources.first(where: { $0.id == source.id }) else { return }
        let id = current.id
        let gain = Gain(Float(value))
        if gain == Gain(Float(volume(for: current))), blocked[id] == nil { return }
        blocked.removeValue(forKey: id)
        desired[id] = gain
        if current.processes.isEmpty {
            saveSilentAdjustment(gain, for: current)
            if automaticCaptureBlocked, gain != .unity { deferredRetryID = id }
        } else {
            submit(gain, for: current, userInitiated: true)
        }
    }

    /// Closes a recovery notice while leaving the audio path unchanged.
    public func dismissIssue() {
        issue = nil
    }

    /// Releases private Core Audio objects.
    public func shutDown() async {
        shuttingDown = true
        monitor?.cancel()
        monitor = nil
        updates.values.forEach { $0.cancel() }
        updates.removeAll()
        await audio.shutdown()
    }

    private func refresh(_ processes: [AudioProcess]) async {
        guard !Task.isCancelled, !shuttingDown else { return }
        let inventory = applications()
        let openIDs = Set(inventory.map(\.id))
        previouslyObserved = previouslyObserved.filter { !$0.hasPrefix("pid:") || openIDs.contains($0) }
        let knownAudioIDs = previouslyObserved.union(preferences.audioApplicationIDs)
        let current = activeSources(processes: processes, applications: inventory, knownAudioIDs: knownAudioIDs)
        previouslyObserved.formUnion(current.lazy.filter { !$0.processes.isEmpty }.map(\.id))
        let liveSources = Dictionary(uniqueKeysWithValues: current.lazy
            .filter { !$0.processes.isEmpty }.map { ($0.id, $0.processes) })

        for source in sources where source.processes != (liveSources[source.id] ?? []) {
            updates.removeValue(forKey: source.id)?.cancel()
            applied.removeValue(forKey: source.id)
        }
        for id in Set(desired.keys).union(selected.keys) where !openIDs.contains(id) {
            desired.removeValue(forKey: id)
            selected.removeValue(forKey: id)
        }
        if let deferredRetryID, !openIDs.contains(deferredRetryID) { self.deferredRetryID = nil }
        blocked = blocked.filter { liveSources[$0.key] == $0.value.processes }
        for source in current where source.processes.isEmpty {
            if let gain = desired[source.id] { saveSilentAdjustment(gain, for: source) }
        }
        if sources != current { sources = current }

        let failures = await audio.reconcile(liveSources)
        guard !Task.isCancelled, !shuttingDown else { return }
        for (id, failure) in failures {
            applied.removeValue(forKey: id)
            if failure == .captureUnavailable, let source = current.first(where: { $0.id == id }) {
                updates.removeValue(forKey: id)?.cancel()
                desired.removeValue(forKey: id)
                show(failure, for: source)
            }
        }
        for source in current where liveSources[source.id] != nil
            && blocked[source.id] == nil && updates[source.id] == nil {
            if let gain = desired[source.id],
               !automaticCaptureBlocked || deferredRetryID == source.id {
                // One prompt attempt at a time until capture works in this launch.
                if activatedThisLaunch || updates.isEmpty {
                    submit(gain, for: source, userInitiated: true)
                }
            } else if activatedThisLaunch, !automaticCaptureBlocked {
                let gain = selected[source.id] ?? preferences.gain(for: source.persistenceKey)
                if gain != .unity && applied[source.id] != gain {
                    submit(gain, for: source, userInitiated: false)
                }
            }
        }
    }

    private func saveSilentAdjustment(_ gain: Gain, for source: ActiveSource) {
        let id = source.id
        if selected[id] != gain {
            selected[id] = gain
            preferences.save(gain, for: source.persistenceKey)
        }
        if gain == .unity {
            desired.removeValue(forKey: id)
            if deferredRetryID == id { deferredRetryID = nil }
        }
    }

    private func submit(_ gain: Gain, for source: ActiveSource, userInitiated: Bool) {
        let id = source.id
        updates[id]?.cancel()
        updates[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if !Task.isCancelled { updates.removeValue(forKey: id) }
            }
            do {
                try await audio.setGain(gain, appID: id, processes: source.processes)
                try Task.checkCancellation()
                applied[id] = gain
                desired.removeValue(forKey: id)
                if userInitiated {
                    selected[id] = gain
                    preferences.save(gain, for: source.persistenceKey)
                    if gain != .unity {
                        activatedThisLaunch = true
                        automaticCaptureBlocked = false
                        deferredRetryID = nil
                    }
                    issue = nil
                }
                if gain == .unity {
                    try await Task.sleep(for: .milliseconds(150))
                    await audio.releaseAtUnity(appID: id)
                }
            } catch is CancellationError {
                // Reconciliation may remove a stale session before it can apply the adjustment.
            } catch let failure as MixerAudioError {
                guard !Task.isCancelled else { return }
                applied.removeValue(forKey: id)
                if failure != .sourceStopped {
                    desired.removeValue(forKey: id)
                    show(failure, for: source)
                }
            } catch {
                guard !Task.isCancelled else { return }
                desired.removeValue(forKey: id)
                show(.captureUnavailable, for: source)
            }
        }
    }

    private func show(_ failure: MixerAudioError, for source: ActiveSource) {
        blocked[source.id] = source
        switch failure {
        case .captureUnavailable:
            applied.removeValue(forKey: source.id)
            automaticCaptureBlocked = true
            deferredRetryID = nil
            issue = .captureUnavailable
        case .unsupportedRoute:
            issue = .unsupportedRoute
        case .sourceStopped:
            break
        }
    }
}
