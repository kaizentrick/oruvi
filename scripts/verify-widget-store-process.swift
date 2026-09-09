import Foundation

/// Compiled twice into real app-like bundles, one of them sandboxed. Uses exactly
/// the production shared-container resolver and serializer with synthetic data.
@main struct VerifyWidgetStoreProcess {
    static func main() throws {
        let store = WidgetSnapshotStore.shared()
        guard let operation = CommandLine.arguments.dropFirst().first else { fatalError("Missing operation") }
        if operation == "write" {
            var value = WidgetSnapshot()
            value.state = .ready; value.session = "ci-session"; value.trackID = "ci-track"
            value.sourceID = "oruvi.system"; value.title = "Música de prueba 🎵"; value.artist = "CI only"
            value.playing = true; value.artwork = Data([1,2,3,4])
            try store.write(value)
            precondition(store.read() == value)
            print("PASS: signed host wrote and read back production widget snapshot")
        } else if operation == "read" {
            guard let value = store.read() else { fatalError("Sandbox did not read the host snapshot") }
            precondition(value.title == "Música de prueba 🎵" && value.playing && value.canControl)
            precondition(value.artwork == Data([1,2,3,4]) && value.trackID == "ci-track")
            print("PASS: separate sandbox process read identical title, artwork bytes and transport state")
        } else if operation == "clear" { store.clear() }
        else { fatalError("Unsupported operation") }
    }
}
