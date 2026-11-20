import AudioCore
import AppKit
import Darwin
import UniformTypeIdentifiers

/// An open application displayed as one mixer row, regardless of helper count.
public struct ActiveSource: Identifiable, Equatable, Sendable {
    /// The application identity used for routing and user preferences.
    public let id: String
    /// The localized application name reported by macOS.
    public let name: String
    /// The process identifier of the application that owns the mixer row.
    public let applicationPID: Int32
    let persistenceKey: String?
    let processes: [AudioProcess]
}

struct OpenApplication {
    let pid: Int32
    let bundleID: String?
    let name: String
    var mayPlayAudio = false

    var persistenceKey: String? { validBundleID(bundleID) }
    var id: String { persistenceKey ?? "pid:\(pid)" }
}

@MainActor
func openApplications() -> [OpenApplication] {
    NSWorkspace.shared.runningApplications.compactMap { app in
        guard app.processIdentifier != getpid(), app.activationPolicy != .prohibited,
              !app.isTerminated, let name = app.localizedName, !name.isEmpty else { return nil }
        return OpenApplication(pid: app.processIdentifier, bundleID: app.bundleIdentifier, name: name,
                               mayPlayAudio: hasAudioMetadata(app))
    }
}

func activeSources(
    processes: [AudioProcess],
    applications: [OpenApplication],
    knownAudioIDs: Set<String> = [],
    parentPID: (Int32) -> Int32? = openParentPID
) -> [ActiveSource] {
    let byPID = Dictionary(applications.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
    var grouped: [String: [AudioProcess]] = [:]

    for process in processes {
        guard let app = owner(of: process, applications: applications, byPID: byPID, parentPID: parentPID)
        else { continue }
        grouped[app.id, default: []].append(process)
    }

    var included = Set<String>()
    return applications.compactMap { app -> ActiveSource? in
        let members = grouped[app.id] ?? []
        guard !members.isEmpty || app.mayPlayAudio || knownAudioIDs.contains(app.id),
              included.insert(app.id).inserted else { return nil }
        return ActiveSource(id: app.id, name: app.name, applicationPID: app.pid,
                            persistenceKey: app.persistenceKey,
                            processes: members.sorted { $0.id < $1.id })
    }.sorted {
        let order = $0.name.localizedStandardCompare($1.name)
        return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
    }
}

@MainActor
private func hasAudioMetadata(_ app: NSRunningApplication) -> Bool {
    if let id = app.bundleIdentifier?.lowercased(), knownAudioApplications.contains(id) {
        return true
    }

    guard let url = app.bundleURL, let info = Bundle(url: url)?.infoDictionary else { return false }
    if let category = info["LSApplicationCategoryType"] as? String,
       audioCategories.contains(category.lowercased()) || category.lowercased().hasSuffix("-games") {
        return true
    }
    guard let documentTypes = info["CFBundleDocumentTypes"] as? [[String: Any]] else { return false }
    return documentTypes.contains { document in
        let typeIdentifiers = document["LSItemContentTypes"] as? [String] ?? []
        let extensions = document["CFBundleTypeExtensions"] as? [String] ?? []
        let mimeTypes = document["CFBundleTypeMIMETypes"] as? [String] ?? []
        let types = typeIdentifiers.compactMap { UTType($0) }
            + extensions.compactMap { UTType(filenameExtension: $0) }
            + mimeTypes.compactMap { UTType(mimeType: $0) }
        return types.contains { $0.conforms(to: .audio) || $0.conforms(to: .movie) }
    }
}

private let audioCategories: Set<String> = [
    "public.app-category.entertainment", "public.app-category.games",
    "public.app-category.music", "public.app-category.video"
]

private let knownAudioApplications: Set<String> = [
    // Browsers often declare web formats only, even though web pages can play or call.
    "com.apple.safari", "com.apple.safaritechnologypreview",
    "com.google.chrome", "com.google.chrome.beta", "com.google.chrome.canary",
    "org.chromium.chromium", "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition",
    "com.microsoft.edgemac", "com.brave.browser", "com.operasoftware.opera",
    "com.vivaldi.vivaldi", "company.thebrowser.browser", "app.zen-browser.zen",
    // Streaming, communication, and other common media apps.
    "com.spotify.client", "com.apple.music", "com.apple.tv", "com.apple.podcasts",
    "com.apple.quicktimeplayerx", "com.apple.voicememos", "com.apple.facetime",
    "org.videolan.vlc", "com.colliderli.iina", "com.tidal.desktop",
    "com.hnc.discord", "com.tinyspeck.slackmacgap", "us.zoom.xos",
    "com.microsoft.teams", "com.microsoft.teams2", "net.whatsapp.whatsapp",
    "ru.keepcoder.telegram", "org.whispersystems.signal-desktop", "com.valvesoftware.steam"
]

private func owner(
    of process: AudioProcess,
    applications: [OpenApplication],
    byPID: [Int32: OpenApplication],
    parentPID: (Int32) -> Int32?
) -> OpenApplication? {
    if let direct = byPID[process.pid] { return direct }
    var pid = process.pid
    for _ in 0..<12 {
        guard let parent = parentPID(pid), parent > 1, parent != pid else { break }
        if let app = byPID[parent] { return app }
        pid = parent
    }
    // Some media helpers are launched by a system service. A qualified bundle
    // identifier can still associate them with the most specific open app.
    guard let bundleID = validBundleID(process.bundleID) else { return nil }
    return applications.filter {
        guard let hostID = validBundleID($0.bundleID) else { return false }
        return bundleID == hostID || bundleID.hasPrefix(hostID + ".")
    }.max { ($0.bundleID?.count ?? 0) < ($1.bundleID?.count ?? 0) }
}

private func openParentPID(_ pid: Int32) -> Int32? {
    var info = proc_bsdinfo()
    let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, expected) == expected,
          let parent = Int32(exactly: info.pbi_ppid) else { return nil }
    return parent
}

func validBundleID(_ id: String?) -> String? {
    guard let id, !id.isEmpty, id.utf8.count <= 255,
          id.utf8.allSatisfy({
              (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) ||
              $0 == 45 || $0 == 46
          }) else { return nil }
    return id
}
