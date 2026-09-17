import Foundation

/// Signed-in Library hides the on-device block until the user turns it on. Signed-out Library
/// always shows it — that is the only history / subscriptions / playlists they have.
nonisolated enum LocalLibraryVisibility {
    static func showsDeviceRows(isSignedIn: Bool, preferenceEnabled: Bool) -> Bool {
        !isSignedIn || preferenceEnabled
    }
}
