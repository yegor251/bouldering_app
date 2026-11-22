import SwiftUI
import SwiftData

struct AlbumDetailView: View {
    let album: Album
    @Environment(\.modelContext) private var context
    @State private var editingRoute: ClimbRoute?
    @State private var addingRoute = false

    var body: some View {
        ScrollView {
            if album.routes.isEmpty {
                ContentUnavailableView {
                    Label("Альбом пуст", systemImage: album.symbol)
                } description: {
                    Text("Добавьте первую трассу в этот альбом")
                }
                .padding(.top, 100)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160), spacing: 12)], spacing: 12) {
                    ForEach(album.routes.sorted { $0.createdAt > $1.createdAt }) { route in
                        NavigationLink(value: route) {
                            RouteCard(route: route)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(role: .destructive) {
                                context.delete(route)
                            } label: {
                                Label("Удалить трассу", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .background(Theme.bg)
        .navigationTitle(album.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    addingRoute = true
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .sheet(isPresented: $addingRoute) {
            RouteEditView(album: album)
        }
    }
}
