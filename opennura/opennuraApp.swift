import SwiftUI

@main
struct opennuraApp: App {
    @StateObject private var auth = NuraAuthManager(configStore: NuraConfigStore())

    var body: some Scene {
        WindowGroup {
            ContentView(auth: auth)
        }
    }
}
