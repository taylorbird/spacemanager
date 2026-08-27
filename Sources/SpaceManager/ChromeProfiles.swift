import Foundation

/// Chrome profile discovery. Reads Chrome's Local State file — read-only,
/// no Chrome APIs involved. Directory names are the exact values Chrome's
/// --profile-directory switch accepts.
enum ChromeProfiles {
    struct Profile: Identifiable, Equatable {
        let directory: String   // "Default", "Profile 1" — the switch value
        let name: String        // user-facing, e.g. "Taylor"
        let email: String?
        var id: String { directory }
        var label: String { email.map { "\(name) (\($0))" } ?? name }
    }

    static var localStateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Google/Chrome/Local State")
    }

    /// Empty array when Chrome isn't installed or the file is unreadable —
    /// callers treat that as "profile targeting unavailable", never an error.
    static func load(from url: URL = localStateURL) -> [Profile] {
        guard let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let profile = root["profile"] as? [String: Any],
              let cache = profile["info_cache"] as? [String: [String: Any]]
        else { return [] }
        let order = (profile["profiles_order"] as? [String]) ?? cache.keys.sorted()
        return order.compactMap { dir in
            guard let info = cache[dir],
                  (info["is_ephemeral"] as? Bool) != true else { return nil }
            let email = (info["user_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            return Profile(directory: dir,
                           name: (info["name"] as? String) ?? dir,
                           email: email)
        }
    }

    /// Guard against launching with a stale directory name: Chrome silently
    /// CREATES a junk profile for an unknown --profile-directory value.
    static func exists(_ directory: String) -> Bool {
        load().contains { $0.directory == directory }
    }
}
