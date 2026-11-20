import AudioCore
import CoreFoundation
import Foundation

@MainActor
struct VolumePreferences {
    let defaults: UserDefaults
    private let storageKey = "applicationGains"

    var audioApplicationIDs: Set<String> {
        let values = defaults.dictionary(forKey: storageKey) ?? [:]
        return Set(values.compactMap { (identifier, value) in
            guard gain(from: value) != .unity else { return nil }
            return validBundleID(identifier)
        })
    }

    func gain(for identifier: String?) -> Gain {
        guard let identifier = validBundleID(identifier) else { return .unity }
        return gain(from: defaults.dictionary(forKey: storageKey)?[identifier])
    }

    private func gain(from value: Any?) -> Gain {
        guard let raw = value as? NSNumber, CFGetTypeID(raw) != CFBooleanGetTypeID() else { return .unity }
        return Gain(raw.floatValue)
    }

    func save(_ gain: Gain, for identifier: String?) {
        guard let identifier = validBundleID(identifier) else { return }
        var values = defaults.dictionary(forKey: storageKey) ?? [:]
        if gain == .unity {
            values.removeValue(forKey: identifier)
        } else {
            values[identifier] = gain.value
        }
        defaults.set(values, forKey: storageKey)
    }
}
