import SwiftUI
import SwiftData

@main
struct BoulderApp: App {
    var body: some Scene {
        WindowGroup {
            AlbumsView()
        }
        .modelContainer(for: [Album.self, ClimbRoute.self, RoutePhoto.self])
    }
}
