import XCTest
@testable import DiskAtlasCore

final class PermissionProbeTests: XCTestCase {
    func testFullDiskAccessGrantedDeniedUnknown() {
        let granted = FakeFileSystem()
        granted.addDir("/probe", children: [])
        XCTAssertEqual(PermissionProbe(fileSystem: granted, probePath: "/probe").fullDiskAccess(), .granted)

        let denied = FakeFileSystem()
        denied.addDir("/probe", children: [], listError: "PermissionError: Operation not permitted")
        XCTAssertEqual(PermissionProbe(fileSystem: denied, probePath: "/probe").fullDiskAccess(), .denied)

        let unknown = FakeFileSystem()
        XCTAssertEqual(PermissionProbe(fileSystem: unknown, probePath: "/probe").fullDiskAccess(), .unknown)
    }
}
