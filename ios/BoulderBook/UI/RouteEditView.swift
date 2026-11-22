import SwiftUI
import SwiftData
import PhotosUI

struct RouteEditView: View {
    var route: ClimbRoute?
    var album: Album?
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var grade = ""
    @State private var level = 5
    @State private var notes = ""
    @State private var status: RouteStatus = .project
    @State private var attempts = 0
    @State private var pickedItems: [PhotosPickerItem] = []
    @State private var processedItems = Set<PhotosPickerItem>()
    @State private var photoStubs: [PhotoStub] = []
    @State private var editingStub: PhotoStub?
    @State private var processing = false

    struct PhotoStub: Identifiable {
        let id = UUID()
        var image: UIImage
        var holds: [DetectedHold]?
        var bitmapSize: (Int, Int)?
        var storedID: UUID? = nil   // RoutePhoto record this stub represents
        var edited = false          // markup was touched in the editor
    }

    private let grades = ["", "6A", "6A+", "6B", "6B+", "6C", "6C+", "7A", "7A+", "7B", "7B+", "7C", "7C+", "8A", "8A+", "8B", "8B+"]

    var body: some View {
        NavigationStack {
            Form {
                Section("Трасса") {
                    Picker("Категория", selection: $grade) {
                        ForEach(grades, id: \.self) { g in
                            Text(g.isEmpty ? "Не указана" : g).tag(g)
                        }
                    }
                    Picker("Уровень", selection: $level) {
                        ForEach(1...10, id: \.self) { l in
                            Text("Уровень \(l)").tag(l)
                        }
                    }
                    Picker("Статус", selection: $status) {
                        ForEach(RouteStatus.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Stepper("Попыток: \(attempts)", value: $attempts, in: 0...999)
                    TextField("Заметки", text: $notes, axis: .vertical)
                        .lineLimit(2...5)
                }
                Section {
                    if photoStubs.isEmpty {
                        Label("Добавьте фото стены — модель найдёт зацепки", systemImage: "camera.metering.matrix")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 10) {
                                ForEach(photoStubs) { stub in
                                    photoCell(stub)
                                }
                            }
                        }
                    }
                    PhotosPicker(
                        selection: $pickedItems,
                        maxSelectionCount: 10,
                        matching: .images
                    ) {
                        Label(processing ? "Обрабатываю…" : "Добавить фото", systemImage: processing ? "hourglass" : "plus.viewfinder")
                    }
                    .disabled(processing)
                } header: {
                    Text("Фото трассы")
                } footer: {
                    Text("Тапните по миниатюре, чтобы изменить разметку")
                }
            }
            .navigationTitle(route == nil ? "Новая трасса" : "Изменить")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.immediately)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Сохранить") { save() }
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Готово") { hideKeyboard() }
                }
            }
            .onChange(of: pickedItems) { _, items in
                // PhotosPicker fires onChange twice on dismissal — only
                // process items we have not seen yet (prevents duplicates).
                let fresh = items.filter { !processedItems.contains($0) }
                guard !fresh.isEmpty else { return }
                fresh.forEach { processedItems.insert($0) }
                processPicked(fresh)
            }
            .onAppear {
                guard let route else { return }
                grade = route.grade
                level = (1...10).contains(route.level) ? route.level : 5
                notes = route.notes
                status = route.status
                attempts = route.attempts
                photoStubs = route.sortedPhotos.map { photo in
                    var stub = PhotoStub(image: UIImage(data: photo.imageData) ?? UIImage())
                    stub.storedID = photo.id
                    if let session = RouteSessionDecoder.decode(photo: photo, image: stub.image) {
                        stub.holds = session.holds
                        stub.bitmapSize = (session.bitmapWidth, session.bitmapHeight)
                    }
                    return stub
                }
            }
            .fullScreenCover(item: $editingStub) { stub in
                if let idx = photoStubs.firstIndex(where: { $0.id == stub.id }) {
                    let binding = Binding<PhotoStub>(
                        get: { photoStubs[idx] },
                        set: { photoStubs[idx] = $0 }
                    )
                    PhotoEditorStubView(stub: binding) {
                        editingStub = nil
                    }
                }
            }
        }
    }

    private func photoCell(_ stub: PhotoStub) -> some View {
        VStack(spacing: 4) {
            Button {
                editingStub = stub
            } label: {
                thumb(stub)
                    .frame(width: 86, height: 112)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(alignment: .bottomTrailing) {
                        Image(systemName: "wand.and.stars")
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(.black.opacity(0.45), in: Circle())
                            .padding(4)
                    }
            }
            .buttonStyle(.plain)
            Button(role: .destructive) {
                photoStubs.removeAll { $0.id == stub.id }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
    }

    @ViewBuilder
    private func thumb(_ stub: PhotoStub) -> some View {
        if let holds = stub.holds, let size = stub.bitmapSize {
            let session = RouteSession(image: stub.image, holds: holds, bitmapSize: size)
            Image(uiImage: session.renderHighlight())
                .resizable().scaledToFill()
        } else {
            Image(uiImage: stub.image)
                .resizable().scaledToFill()
        }
    }

    private func processPicked(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        processing = true
        let itemsCopy = items
        pickedItems = []
        let detector = HoldDetector.load()
        Task {
            for item in itemsCopy {
                if let data = try? await item.loadTransferable(type: Data.self),
                   let img = UIImage(data: data)?.downscaled(maxSide: 2000) {
                    let holds = await withCheckedContinuation { cont in
                        if let detector {
                            detector.detect(image: img) { cont.resume(returning: $0) }
                        } else {
                            cont.resume(returning: [])
                        }
                    }
                    let size = holds.first.map { ($0.bw, $0.bh) }
                    await MainActor.run {
                        let stub = PhotoStub(image: img, holds: holds, bitmapSize: size)
                        photoStubs.append(stub)
                        if editingStub == nil {
                            editingStub = stub
                        }
                    }
                }
            }
            await MainActor.run { processing = false }
        }
    }

    private func save() {
        let route: ClimbRoute
        if let existing = self.route {
            existing.grade = grade
            existing.level = level
            existing.status = status
            existing.attempts = attempts
            existing.notes = notes
            route = existing
        } else {
            let created = ClimbRoute(grade: grade, level: level, notes: notes, status: status, attempts: attempts, album: album)
            context.insert(created)
            route = created
        }
        syncPhotos(to: route)
        try? context.save()
        dismiss()
    }

    /// Photos the user did not touch keep their stored detection untouched —
    /// no model re-run, same masks, same preview.
    private func syncPhotos(to route: ClimbRoute) {
        let keptIDs = Set(photoStubs.compactMap(\.storedID))
        for photo in route.photos where !keptIDs.contains(photo.id) {
            context.delete(photo)
        }
        for (order, stub) in photoStubs.enumerated() {
            if let id = stub.storedID, let existing = route.photos.first(where: { $0.id == id }) {
                if stub.edited {
                    refresh(existing, from: stub, order: order)
                } else {
                    existing.sortOrder = order
                }
            } else {
                insertPhoto(stub, to: route, order: order)
            }
        }
    }

    private func refresh(_ photo: RoutePhoto, from stub: PhotoStub, order: Int) {
        guard let holds = stub.holds, let size = stub.bitmapSize else { return }
        let session = RouteSession(image: stub.image, holds: holds, bitmapSize: size)
        photo.masksBlob = MaskCodec.encode(holds.map { $0.mask }, width: size.0, height: size.1)
        photo.holdsJSON = (try? JSONEncoder().encode(session.storedHolds())) ?? photo.holdsJSON
        photo.previewData = session.renderHighlight().jpegData(compressionQuality: 0.85)
        photo.sortOrder = order
    }

    private func insertPhoto(_ stub: PhotoStub, to route: ClimbRoute, order: Int) {
        guard let imageData = stub.image.jpegData(compressionQuality: 0.85) else { return }
        if let holds = stub.holds, let size = stub.bitmapSize {
            let session = RouteSession(image: stub.image, holds: holds, bitmapSize: size)
            let blob = MaskCodec.encode(holds.map { $0.mask }, width: size.0, height: size.1)
            let preview = session.renderHighlight().jpegData(compressionQuality: 0.85)
            let photo = RoutePhoto(
                image: imageData, preview: preview, masksBlob: blob,
                holds: session.storedHolds(), bitmapSize: size, sortOrder: order
            )
            photo.route = route
            context.insert(photo)
        } else {
            let photo = RoutePhoto(image: imageData, masksBlob: Data(), holds: [], bitmapSize: (0, 0), sortOrder: order)
            photo.route = route
            context.insert(photo)
        }
    }
}

extension View {
    func hideKeyboard() {
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

extension UIImage {
    func downscaled(maxSide: CGFloat) -> UIImage {        let maxDim = max(size.width, size.height)
        guard maxDim > maxSide else { return self }
        let scale = maxSide / maxDim
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: newSize, format: format)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: newSize))
        }
    }
}
