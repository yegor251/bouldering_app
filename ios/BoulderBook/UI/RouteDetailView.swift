import SwiftUI
import SwiftData

struct RouteDetailView: View {
    @Bindable var route: ClimbRoute
    @Environment(\.modelContext) private var context
    @State private var editingPhoto: RoutePhoto?
    @State private var editingRoute = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                photoPager
                infoCard
                if !route.notes.isEmpty { notesCard }
            }
            .padding(16)
        }
        .background(Theme.bg)
        .navigationTitle("Трасса")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Изменить") { editingRoute = true }
            }
        }
        .sheet(isPresented: $editingRoute) {
            RouteEditView(route: route)
        }
        .fullScreenCover(item: $editingPhoto) { photo in
            PhotoEditorView(photo: photo) { updated in
                photo.masksBlob = updated.masksBlob
                photo.holdsJSON = updated.holdsJSON
                photo.previewData = updated.previewData
                try? context.save()
            }
        }
    }

    private var photoPager: some View {
        TabView {
            ForEach(route.sortedPhotos) { photo in
                PhotoThumb(photo: photo, cornerRadius: 16)
                    .padding(.horizontal, 4)
                    .onTapGesture { editingPhoto = photo }
            }
        }
        .tabViewStyle(.page(indexDisplayMode: route.photos.count > 1 ? .automatic : .never))
        .frame(height: 420)
    }

    private var infoCard: some View {
        VStack(spacing: 12) {
            HStack {
                if !route.grade.isEmpty {
                    Text(route.grade)
                        .font(.title3.weight(.bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Theme.gradeColor(route.grade).opacity(0.2), in: Capsule())
                        .foregroundStyle(Theme.gradeColor(route.grade))
                }
                Spacer()
                statusPicker
            }
            HStack {
                infoRow("Уровень", "\(route.level)", icon: "chart.bar.fill")
                Divider().frame(height: 28)
                infoRow("Попыток", "\(route.attempts)", icon: "arrow.triangle.2.circlepath")
            }
            HStack {
                infoRow("Добавлена", route.createdAt.formatted(date: .abbreviated, time: .omitted), icon: "calendar")
                Spacer()
                attemptButton
            }
        }
        .cardStyle()
    }

    private var statusPicker: some View {
        Picker("Статус", selection: Binding(
            get: { route.status },
            set: { route.status = $0 }
        )) {
            ForEach(RouteStatus.allCases, id: \.self) { s in
                Text(s.label).tag(s)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 180)
    }

    private var attemptButton: some View {
        Button {
            route.attempts += 1
        } label: {
            Label("Попытка +1", systemImage: "plus.circle.fill")
                .font(.subheadline.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(Theme.accent)
    }

    private var notesCard: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "note.text")
                .foregroundStyle(.secondary)
            Text(route.notes)
                .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func infoRow(_ title: String, _ value: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.subheadline.weight(.medium))
            }
        }
    }
}

struct PhotoThumb: View {
    let photo: RoutePhoto
    var cornerRadius: CGFloat = 12

    var body: some View {
        Group {
            if let img = UIImage(data: photo.previewData ?? photo.imageData) {
                Image(uiImage: img).resizable().scaledToFit()
            } else {
                Theme.card
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
    }
}

/// Rebuilds a RouteSession from stored photo data (masks + hold metadata).
enum RouteSessionDecoder {
    static func decode(photo: RoutePhoto, image: UIImage) -> RouteSession? {
        guard let decoded = MaskCodec.decode(photo.masksBlob),
              photo.bitmapWidth == decoded.width,
              photo.bitmapHeight == decoded.height else { return nil }
        let stored = photo.holds
        let holds: [DetectedHold] = decoded.masks.enumerated().compactMap { i, mask in
            guard i < stored.count else { return nil }
            let s = stored[i]
            return DetectedHold(
                id: s.id,
                mask: mask,
                bw: photo.bitmapWidth,
                bh: photo.bitmapHeight,
                box: (s.box.count == 4 ? (s.box[0], s.box[1], s.box[2], s.box[3]) : (0, 0, 0, 0)),
                lab: (s.lab.count == 3 ? (s.lab[0], s.lab[1], s.lab[2]) : (0, 128, 128)),
                rgb: (s.bgr.count == 3 ? (s.bgr[2], s.bgr[1], s.bgr[0]) : (0, 0, 0)),
                conf: s.conf,
                selected: s.selected
            )
        }
        return RouteSession(image: image, holds: holds, bitmapSize: (decoded.width, decoded.height))
    }
}
