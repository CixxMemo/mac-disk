import XCTest
@testable import DiskAtlasCore

final class TrashPolicyTests: XCTestCase {
    private let home = "/Users/me"
    private func policy(protected: [String] = []) -> TrashPolicy {
        TrashPolicy(home: home, applications: "/Applications", protectedPaths: protected)
    }

    func testRejectsOutsideHome() {
        XCTAssertNotNil(policy().check("/etc/hosts"))
        XCTAssertNotNil(policy().check("/opt/homebrew"))
        XCTAssertNotNil(policy().check("/Users/other/.npm"))
        XCTAssertNotNil(policy().check("/Users/me2/.npm"), "ana klasör adıyla başlayan başka klasör")
    }

    func testRejectsHomeAndContainers() {
        for path in ["/Users/me", "/Users/me/Library", "/Users/me/Library/Caches", "/Users/me/Library/Application Support",
                     "/Users/me/Library/Containers", "/Users/me/Downloads", "/Users/me/Applications"] {
            XCTAssertNotNil(policy().check(path), path)
        }
    }

    func testRejectsPersonalAndSecretFolders() {
        for path in ["/Users/me/Documents", "/Users/me/Documents/proj/node_modules", "/Users/me/Desktop/x", "/Users/me/Pictures/a.photoslibrary",
                     "/Users/me/Movies", "/Users/me/Music/x", "/Users/me/.ssh", "/Users/me/.gnupg/keys", "/Users/me/Library/Keychains",
                     "/Users/me/Library/Mobile Documents/com~apple~CloudDocs", "/Users/me/Library/CloudStorage/Dropbox",
                     "/Users/me/Library/Messages", "/Users/me/Library/Mail/V10", "/Users/me/Library/Safari"] {
            XCTAssertNotNil(policy().check(path), path)
        }
    }

    func testRejectsTrash() {
        XCTAssertNotNil(policy().check("/Users/me/.Trash"))
        XCTAssertNotNil(policy().check("/Users/me/.Trash/old"))
    }

    func testRejectsNonCanonicalPaths() {
        for path in ["/Users/me/a/../b", "/Users/me/a/", "Users/me/a", "", "/Users/me/./a", "/Users/me//a", "~/a"] {
            XCTAssertNotNil(policy().check(path), path)
        }
    }

    func testAllowsCacheFolders() {
        XCTAssertNil(policy().check("/Users/me/.npm"))
        XCTAssertNil(policy().check("/Users/me/Library/Caches/pip"))
        XCTAssertNil(policy().check("/Users/me/Library/Developer/Xcode/DerivedData"))
    }

    func testApplicationsOnlyDirectAppBundles() {
        XCTAssertNil(policy().check("/Applications/Foo.app"))
        for path in ["/Applications", "/Applications/Foo.app/Contents", "/Applications/Utilities", "/Applications/Folder/Foo.app"] {
            XCTAssertNotNil(policy().check(path), path)
        }
        XCTAssertNotNil(TrashPolicy(home: home, applications: nil, protectedPaths: []).check("/Applications/Foo.app"))
    }

    func testRejectsProtectedPathAndItsDescendants() {
        let p = policy(protected: ["/Users/me/Library/Application Support/minecraft/saves"])
        XCTAssertNotNil(p.check("/Users/me/Library/Application Support/minecraft/saves"))
        XCTAssertNotNil(p.check("/Users/me/Library/Application Support/minecraft/saves/world1"))
    }

    func testRejectsParentOfProtectedPath() {
        let p = policy(protected: ["/Users/me/Library/Application Support/minecraft/saves"])
        XCTAssertNotNil(p.check("/Users/me/Library/Application Support/minecraft"))
        XCTAssertNil(p.check("/Users/me/Library/Application Support/minecraft/mods"))
        XCTAssertNil(p.check("/Users/me/Library/Application Support/minecraft/savesX"))
    }

    func testCaseInsensitive() {
        XCTAssertNotNil(policy().check("/Users/me/documents/x"))
        XCTAssertNotNil(policy(protected: ["/Users/me/Foo"]).check("/Users/me/FOO"))
    }
}
