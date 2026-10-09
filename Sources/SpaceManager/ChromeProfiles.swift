import Foundation

/// Chrome profile discovery. Reads Chrome's Local State file — read-only,
/// no Chrome APIs involved. Directory names are the exact values Chrome's
/// --profile-directory switch accepts.
///
/// The read happens ONLY when the user clicks Refresh in Preferences: on
/// macOS 27 it's gated by TCC (kTCCServiceSystemPolicyAppDataDetailed), so
/// runtime callers use the snapshot stored in Settings instead.
enum ChromeProfiles {
    struct Profile: Identifiable, Equatable, Codable {
        let directory: String   // "Default", "Profile 1" — the switch value
        let name: String        // user-facing, e.g. "Taylor"
        let email: String?
        /// Whether it appears in the switcher's profile submenu.
        var enabled: Bool = true
        var id: String { directory }
        var label: String { email.map { "\(name) (\($0))" } ?? name }

        init(directory: String, name: String, email: String?, enabled: Bool = true) {
            self.directory = directory
            self.name = name
            self.email = email
            self.enabled = enabled
        }

        private enum CodingKeys: String, CodingKey { case directory, name, email, enabled }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            directory = try c.decode(String.self, forKey: .directory)
            name = try c.decode(String.self, forKey: .name)
            email = try c.decodeIfPresent(String.self, forKey: .email)
            enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        }
    }

    static var localStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    /// Empty array when Chrome isn't installed or the file is unreadable —
    /// callers treat that as "profile targeting unavailable", never an error.
    static func load(from url: URL = localStateURL) -> [Profile] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Log.chrome.error("Local State unreadable: \(error.localizedDescription, privacy: .public)")
            return []
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]]
        else {
            Log.chrome.error("Local State read (\(data.count, privacy: .public) bytes) but no profile info_cache parsed")
            return []
        }
        let order = (profile["profiles_order"] as? [String]) ?? cache.keys.sorted()
        let profiles: [Profile] = order.compactMap { dir in
            guard let info = cache[dir],
                  (info["is_ephemeral"] as? Bool) != true else { return nil }
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(directory: dir,
                           name: (info["name"] as? String) ?? dir,
                           email: email)
        }
        Log.chrome.notice("Local State read (\(data.count, privacy: .public) bytes), \(profiles.count, privacy: .public) profiles parsed")
        return profiles
    }

    /// Fold a fresh read into the stored snapshot: fresh order and names win,
    /// each surviving directory keeps its `enabled` flag, new directories
    /// arrive enabled, and directories Chrome no longer lists are dropped.
    static func merge(existing: [Profile], fresh: [Profile]) -> [Profile] {
        let flags = Dictionary(existing.map { ($0.directory, $0.enabled) },
                               uniquingKeysWith: { first, _ in first })
        return fresh.map { p in
            var merged = p
            merged.enabled = flags[p.directory] ?? true
            return merged
        }
    }
}
