import XCTest
@testable import FreeTube

final class LocalLibraryVisibilityTests: XCTestCase {
    func testSignedOutLibraryAlwaysShowsOnThisDeviceRows() {
        XCTAssertTrue(LocalLibraryVisibility.showsDeviceRows(isSignedIn: false, preferenceEnabled: false))
    }

    func testSignedInLibraryHidesOnThisDeviceRowsUntilToggled() {
        XCTAssertFalse(LocalLibraryVisibility.showsDeviceRows(isSignedIn: true, preferenceEnabled: false))
        XCTAssertTrue(LocalLibraryVisibility.showsDeviceRows(isSignedIn: true, preferenceEnabled: true))
    }
}
