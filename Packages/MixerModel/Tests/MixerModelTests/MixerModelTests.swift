import AudioCore
import Foundation
import Testing
@testable import MixerModel

@Test func groupsActiveHelpersAndFiltersBackgroundServices() {
    let apps = [
        OpenApplication(pid: 20, bundleID: "app.test.Browser", name: "Browser"),
        OpenApplication(pid: 30, bundleID: "app.test.Player", name: "Player"),
        OpenApplication(pid: 40, bundleID: "app.test.Quiet", name: "Quiet")
    ]
    let processes = [
        AudioProcess(id: 4, pid: 21, bundleID: "unrelated.id", outputDevices: [3]),
        AudioProcess(id: 3, pid: 30, bundleID: "app.test.Player", outputDevices: [3]),
        AudioProcess(id: 2, pid: 22, bundleID: "app.test.Browser.helper", outputDevices: [3]),
        AudioProcess(id: 5, pid: 23, bundleID: "background.unrelated", outputDevices: [3])
    ]
    let sources = activeSources(processes: processes, applications: apps) { $0 == 21 ? 20 : nil }
    #expect(sources.map(\.name) == ["Browser", "Player"])
    #expect(sources.first?.processes.map(\.id) == [2, 4])
}

@MainActor
@Test func preferencesClampValuesAndAreIsolatedByApplication() {
    let suite = "volume-preferences-tests-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else {
        Issue.record("Unable to create local defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = VolumePreferences(defaults: defaults)
    defaults.set(["app.test.One": -1, "app.test.Two": true, "app.test.Three": "0.4"],
                 forKey: "applicationGains")
    #expect(preferences.gain(for: "app.test.One").value == 0)
    #expect(preferences.gain(for: "app.test.Two") == .unity)
    #expect(preferences.gain(for: "app.test.Three") == .unity)
    preferences.save(Gain(0.45), for: "app.test.Two")
    #expect(preferences.gain(for: "app.test.Two") == Gain(0.45))
    #expect(preferences.gain(for: "app.test.One") == Gain(0))
    preferences.save(.unity, for: "app.test.Two")
    #expect(preferences.gain(for: "app.test.Two") == .unity)
    #expect(preferences.gain(for: "/path/to/app") == .unity)
}

@MainActor
@Test func savedVolumesDoNotCauseCaptureBeforeAnAdjustment() async {
    let suite = "activation-tests-" + UUID().uuidString
    guard let defaults = UserDefaults(suiteName: suite) else {
        Issue.record("Unable to create local defaults suite")
        return
    }
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = VolumePreferences(defaults: defaults)
    preferences.save(Gain(0.35), for: "app.test.One")
    let process = AudioProcess(id: 1, pid: 10, bundleID: "app.test.One", outputDevices: [3])
    let audio = MockAudio(processes: [process])
    let model = MixerModel(defaults: defaults, audio: audio) {
        [OpenApplication(pid: 10, bundleID: "app.test.One", name: "One")]
    }
    await model.refresh()
    #expect(await audio.gains.isEmpty)
    guard let source = model.sources.first else {
        Issue.record("No source discovered")
        return
    }
    #expect(model.volume(for: source) == 1)
    model.setVolume(0.5, for: source)
    let deadline = ContinuousClock.now + .seconds(2)
    while preferences.gain(for: "app.test.One") != Gain(0.5), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(10))
    }
    #expect(await audio.gains == [Gain(0.5)])
    #expect(preferences.gain(for: "app.test.One") == Gain(0.5))
    await model.shutDown()
}

private actor MockAudio: AudioControlling {
    let processes: [AudioProcess]
    private(set) var gains: [Gain] = []

    init(processes: [AudioProcess]) { self.processes = processes }

    func activeProcesses() async -> [AudioProcess] { processes }

    func setGain(_ gain: Gain, appID: String, processes: [AudioProcess]) async throws {
        gains.append(gain)
    }

    func reconcile(_ sources: [String: [AudioProcess]]) async -> [String: MixerAudioError] { [:] }
    func releaseAtUnity(appID: String) async {}
    func shutdown() async {}
}
