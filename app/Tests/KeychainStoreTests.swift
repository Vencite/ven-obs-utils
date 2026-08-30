import Foundation

@main
struct KeychainStoreTests {
    static func main() throws {
        let store = KeychainStore(
            service: "works.ven.obs-utils.tests.\(UUID().uuidString)",
            account: "obs-websocket"
        )
        defer { try? store.delete() }

        try store.write("first-secret")
        guard try store.read() == "first-secret" else {
            fatalError("Keychain should return written password")
        }

        try store.write("updated-secret")
        guard try store.read() == "updated-secret" else {
            fatalError("Keychain should replace existing password")
        }

        try store.delete()
        guard try store.read() == nil else {
            fatalError("Deleted Keychain item should be absent")
        }

        print("KeychainStoreTests: PASS")
    }
}
