import XCTest
@testable import SpaceManager

final class ChromeProfilesTests: XCTestCase {
    private func write(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalState-\(UUID().uuidString)")
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    func testParsesProfilesInOrder() throws {
        let url = try write(#"""
        {"profile":{"profiles_order":["Profile 1","Default"],
          "info_cache":{
            "Default":{"name":"Taylor","user_name":"t@gmail.com"},
            "Profile 1":{"name":"Work","user_name":"t@work.com"}}}}
        """#)
        let profiles = ChromeProfiles.load(from: url)
        XCTAssertEqual(profiles.map(\.directory), ["Profile 1", "Default"])
        XCTAssertEqual(profiles[1].name, "Taylor")
        XCTAssertEqual(profiles[1].email, "t@gmail.com")
    }

    func testSkipsEphemeralAndHandlesMissingOrder() throws {
        let url = try write(#"""
        {"profile":{"info_cache":{
            "Default":{"name":"Taylor"},
            "Guest":{"name":"Guest","is_ephemeral":true}}}}
        """#)
        let profiles = ChromeProfiles.load(from: url)
        XCTAssertEqual(profiles.map(\.directory), ["Default"])
        XCTAssertNil(profiles[0].email)
    }

    func testUnreadableFileYieldsEmpty() {
        XCTAssertEqual(ChromeProfiles.load(from: URL(fileURLWithPath: "/nonexistent")), [])
    }

    func testMergeKeepsFlagsAddsNewEnabledDropsGone() {
        let existing = [
            ChromeProfiles.Profile(directory: "Default", name: "Taylor", email: nil, enabled: false),
            ChromeProfiles.Profile(directory: "Profile 1", name: "Work", email: nil, enabled: true),
            ChromeProfiles.Profile(directory: "Profile 9", name: "Gone", email: nil, enabled: false),
        ]
        let fresh = [
            ChromeProfiles.Profile(directory: "Profile 2", name: "New", email: nil),
            ChromeProfiles.Profile(directory: "Default", name: "Taylor B", email: "t@gmail.com"),
            ChromeProfiles.Profile(directory: "Profile 1", name: "Work", email: nil),
        ]
        let merged = ChromeProfiles.merge(existing: existing, fresh: fresh)
        XCTAssertEqual(merged.map(\.directory), ["Profile 2", "Default", "Profile 1"])
        XCTAssertEqual(merged.map(\.enabled), [true, false, true])
        XCTAssertEqual(merged[1].name, "Taylor B")
        XCTAssertEqual(merged[1].email, "t@gmail.com")
    }

    func testDecodesSnapshotWithoutEnabledKey() throws {
        let json = #"[{"directory":"Default","name":"Taylor"}]"#
        let decoded = try JSONDecoder().decode([ChromeProfiles.Profile].self,
                                               from: json.data(using: .utf8)!)
        XCTAssertEqual(decoded, [ChromeProfiles.Profile(directory: "Default", name: "Taylor", email: nil)])
        XCTAssertTrue(decoded[0].enabled)
    }

    func testSnapshotRoundTrips() throws {
        let original = [ChromeProfiles.Profile(directory: "Profile 1", name: "Work",
                                               email: "t@work.com", enabled: false)]
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode([ChromeProfiles.Profile].self, from: data), original)
    }
}
