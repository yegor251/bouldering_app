import SwiftUI
import SwiftData

struct AlbumsView: View {
    @Query(sort: \Album.createdAt, order: .reverse) private var albums: [Album]
    @Query(sort: \ClimbRoute.createdAt, order: .reverse) private var recentRoutes: [ClimbRoute]
    @Environment(\.modelContext) private var modelContext
    @State private var showingAdd = false
    @State private var refreshID = UUID()
    @State private var path = NavigationPath()

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if albums.isEmpty && recentRoutes.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .navigationTitle("Коллекция")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showingAdd = true
                    } label: {
                        Image(systemName: "folder.badge.plus")
                    }
                }
            }
            .sheet(isPresented: $showingAdd) { NewAlbumSheet() }
            .onAppear {
                DemoSeed.seedIfNeeded(context: modelContext)
                tryOpenDemoRoute()
            }
            .onReceive(NotificationCenter.default.publisher(for: .demoSeedDidFinish)) { _ in
                refreshID = UUID()
                tryOpenDemoRoute()
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("Пока пусто", systemImage: "figure.climbing")
        } description: {
            Text("Создайте альбом и добавьте первую трассу —\nфото, тап по зацепке, и она в коллекции")
        } actions: {
            Button("Создать альбом") { showingAdd = true }
                .buttonStyle(.borderedProminent)
        }
    }

    private var list: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !recentRoutes.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Недавние трассы", systemImage: "clock")
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(recentRoutes.prefix(10)) { route in
                                    NavigationLink(value: route) {
                                        RouteCard(route: route, compact: true)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            .padding(.horizontal, 16)
                        }
                    }
                }
                if !albums.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        sectionTitle("Альбомы", systemImage: "square.stack.3d.up")
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                            ForEach(albums) { album in
                                NavigationLink(value: album) {
                                    AlbumCard(album: album)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.horizontal, 16)
                    }
                }
                if albums.isEmpty && !recentRoutes.isEmpty {
                    NavigationLink(value: recentRoutes[0]) { RouteCard(route: recentRoutes[0]) }
                        .padding(.horizontal, 16)
                }
                modelVersionFooter
            }
            .padding(.vertical, 8)
        }
        .id(refreshID)
        .background(Theme.bg)
        .navigationDestination(for: Album.self) { AlbumDetailView(album: $0) }
        .navigationDestination(for: ClimbRoute.self) { RouteDetailView(route: $0) }
    }

    private func sectionTitle(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.headline)
            .padding(.horizontal, 16)
    }

    private var modelVersionFooter: some View {
        Text("Модель: \(HoldDetector.modelVersion)")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
    }

    private func tryOpenDemoRoute() {
        guard ProcessInfo.processInfo.arguments.contains("-demoOpenRoute"),
              path.isEmpty, let first = recentRoutes.first else { return }
        path.append(first)
    }
}

struct AlbumCard: View {
    let album: Album

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                if let cover = album.routes.sorted(by: { $0.createdAt > $1.createdAt }).first?.cover,
                   let img = UIImage(data: cover.previewData ?? cover.imageData) {
                    Image(uiImage: img)
                        .resizable().scaledToFill()
                        .frame(width: 150, height: 110)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(Theme.accentDim.opacity(0.3))
                        .frame(width: 150, height: 110)
                        .overlay {
                            Image(systemName: album.symbol)
                                .font(.title)
                                .foregroundStyle(Theme.accent)
                        }
                }
            }
            Text(album.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text("\(album.routes.count) трасс")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

struct NewAlbumSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var symbol = "square.stack.3d.up"

    private let icons = [
        "square.stack.3d.up", "flag.fill", "mountain.2.fill", "figure.climbing",
        "flame.fill", "star.fill", "bolt.fill", "heart.fill",
    ]

    var body: some View {
        NavigationStack {
            Form {
                TextField("Название", text: $name)
                Section("Иконка") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                        ForEach(icons, id: \.self) { icon in
                            Button {
                                symbol = icon
                            } label: {
                                Image(systemName: icon)
                                    .font(.title2)
                                    .frame(width: 44, height: 44)
                                    .background(
                                        symbol == icon ? Theme.accent.opacity(0.25) : .clear,
                                        in: RoundedRectangle(cornerRadius: 10)
                                    )
                                    .foregroundStyle(symbol == icon ? Theme.accent : .secondary)
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
            .navigationTitle("Новый альбом")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Создать") {
                        let trimmed = name.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty else { return }
                        context.insert(Album(name: trimmed, symbol: symbol))
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium])
    }
}
