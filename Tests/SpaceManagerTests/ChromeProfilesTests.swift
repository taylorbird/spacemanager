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
}
