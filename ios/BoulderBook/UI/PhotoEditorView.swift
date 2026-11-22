import SwiftUI
import Photos

/// Full-screen editor for one photo of a route: tap to pick the route color,
/// tap to toggle holds, delta-E slider, export PNG without background.
struct PhotoEditorStubView: View {
    @Binding var stub: RouteEditView.PhotoStub
    var onDone: () -> Void

    @State private var session: RouteSession?
    @State private var rendered: UIImage?
    @State private var statusText = "Тапните по зацепке трассы"
    @State private var showShare = false
    @State private var shareImage: UIImage?
    @State private var savedToast = false
    @State private var zoom: CGFloat = 1
    @State private var zoomAnchor: CGFloat = 1
    @State private var panOffset: CGSize = .zero
    @State private var pendingPan: CGSize = .zero
    @State private var isPinching = false
    @State private var isRendering = false
    @State private var renderDirty = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                editorCanvas
                controls
            }
            .background(Color.black.ignoresSafeArea())
            .navigationTitle("Разметка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Готово") {
                        if let s = session {
                            stub.holds = s.holds
                        }
                        stub.edited = true
                        onDone()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportCutout()
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(session?.selectionCount == 0)
                }
            }
            .onAppear { rebuild() }
            .sheet(isPresented: $showShare) {
                if let shareImage {
                    ShareSheet(items: [shareImage])
                }
            }
            .overlay(alignment: .bottom) {
                if savedToast {
                    Label("Сохранено в Фото", systemImage: "checkmark.circle.fill")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(.bottom, 90)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
    }

    private var editorCanvas: some View {
        GeometryReader { geo in
            Group {
                let img = rendered ?? stub.image
                let fitted = img.size.fitted(in: geo.size)
                let scaled = CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
                let origin = CGPoint(
                    x: geo.size.width / 2 + panOffset.width - scaled.width / 2,
                    y: geo.size.height / 2 + panOffset.height - scaled.height / 2
                )
                Image(uiImage: img)
                    .resizable()
                    .frame(width: scaled.width, height: scaled.height)
                    .position(x: origin.x + scaled.width / 2, y: origin.y + scaled.height / 2)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .contentShape(Rectangle())
                    .gesture(
                        SpatialTapGesture().onEnded { value in
                            tap(at: value.location, origin: origin, fitted: fitted, image: img)
                        }
                    )
                    .simultaneousGesture(panGesture(canvasSize: geo.size, fitted: fitted))
                    .simultaneousGesture(zoomGesture())
            }
            .overlay(alignment: .topTrailing) {
                if zoom > 1.05 {
                    Button {
                        zoom = 1; zoomAnchor = 1
                        panOffset = .zero; pendingPan = .zero
                    } label: {
                        Image(systemName: "arrow.down.right.and.arrow.up.left")
                            .font(.caption.weight(.semibold))
                            .padding(8)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(18)
                }
            }
            .overlay(alignment: .topLeading) {
                if isRendering {
                    ProgressView()
                        .padding(10)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(18)
                }
            }
        }
        .padding(12)
        .clipped()
    }

    private func panGesture(canvasSize: CGSize, fitted: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { value in
                // a second finger pinching would also translate — ignore that
                guard !isPinching, zoom > 1.02 else { return }
                let maxX = max(0, (fitted.width * zoom - canvasSize.width) / 2 + 24)
                let maxY = max(0, (fitted.height * zoom - canvasSize.height) / 2 + 24)
                panOffset = CGSize(
                    width: min(max(pendingPan.width + value.translation.width, -maxX), maxX),
                    height: min(max(pendingPan.height + value.translation.height, -maxY), maxY)
                )
            }
            .onEnded { _ in pendingPan = panOffset }
    }

    private func zoomGesture() -> some Gesture {
        MagnificationGesture()
            .onChanged { value in
                isPinching = true
                zoom = min(max(zoomAnchor * value, 1), 10)
            }
            .onEnded { _ in
                zoomAnchor = zoom
                isPinching = false
                if zoom <= 1.02 {
                    zoom = 1; zoomAnchor = 1
                    panOffset = .zero; pendingPan = .zero
                }
            }
    }

    private var controls: some View {
        VStack(spacing: 14) {
            HStack {
                Label(statusText, systemImage: "hand.tap")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                Spacer()
                Text("\(session?.selectionCount ?? 0) зацепок")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
            HStack(spacing: 12) {
                Text("ΔE")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Slider(
                    value: Binding(
                        get: { session?.maxDE ?? 30 },
                        set: { v in
                            session?.maxDE = v
                            session?.autoSelect()
                            rerender()
                        }
                    ),
                    in: 5...60
                )
                .tint(Theme.accent)
                Text("\(Int(session?.maxDE ?? 30))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 26)
            }
            HStack(spacing: 10) {
                Button {
                    session?.clearSelection()
                    statusText = "Тапните по зацепке трассы"
                    rerender()
                } label: {
                    Label("Сброс", systemImage: "arrow.counterclockwise")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .tint(.white)
                Button {
                    saveToPhotos()
                } label: {
                    Label("В Фото", systemImage: "square.and.arrow.down")
                        .font(.footnote.weight(.semibold))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(session?.selectionCount == 0)
            }
        }
        .padding(16)
        .background(.ultraThinMaterial)
    }

    // MARK: - Logic

    private func rebuild() {
        if let holds = stub.holds, let size = stub.bitmapSize {
            session = RouteSession(image: stub.image, holds: holds, bitmapSize: size)
            statusText = stub.holds?.contains(where: \.selected) == true
                ? "Тап — добавить/убрать зацепку"
                : "Тапните по зацепке трассы"
        } else if let detector = HoldDetector.load() {
            statusText = "Ищу зацепки…"
            detector.detect(image: stub.image) { holds in
                session = RouteSession(image: stub.image, holds: holds, bitmapSize: (holds.first?.bw ?? 1, holds.first?.bh ?? 1))
                statusText = holds.isEmpty
                    ? "Зацепок не найдено [\(HoldDetector.lastDebugInfo)]"
                    : "Найдено \(holds.count) зацепок. Тапните по трассе"
                rerender()
            }
        } else {
            statusText = "Модель не загрузилась"
        }
        rerender()
    }

    private func tap(at point: CGPoint, origin: CGPoint, fitted: CGSize, image: UIImage) {
        guard let session else { return }
        let relX = (point.x - origin.x) / (fitted.width * zoom)
        let relY = (point.y - origin.y) / (fitted.height * zoom)
        guard relX >= 0, relX <= 1, relY >= 0, relY <= 1 else { return }
        let bx = Int(relX * CGFloat(session.bitmapWidth))
        let by = Int(relY * CGFloat(session.bitmapHeight))
        var changed = false
        if session.referenceId == nil {
            if session.selectRoute(x: bx, y: by) {
                statusText = "Тап — добавить/убрать зацепку"
                changed = true
            } else {
                statusText = "Тут нет зацепки — тапните по ней"
            }
        } else if let id = session.hold(atX: bx, y: by) {
            session.toggle(id)
            changed = true
        } else if session.selectRoute(x: bx, y: by) {
            statusText = "Новый эталон цвета"
            changed = true
        } else {
            statusText = "Тут нет зацепки"
        }
        if changed {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            syncStub(from: session)
            rerender()
        }
    }

    private func syncStub(from session: RouteSession) {
        stub.holds = session.holds
        stub.bitmapSize = (session.bitmapWidth, session.bitmapHeight)
    }

    /// CI composition runs off-main; the previous render stays on screen
    /// until the fresh one arrives, so taps never freeze the UI.
    private func rerender() {
        guard let session else {
            rendered = nil
            return
        }
        if isRendering {
            renderDirty = true   // coalesce: one fresh render after the busy one
            return
        }
        isRendering = true
        session.renderHighlightAsync { [session] img in
            rendered = img
            isRendering = false
            if renderDirty {
                renderDirty = false
                rerender()
            }
        }
    }

    /// Export matches what the user sees: the photo with the outline markup.
    private func exportCutout() {
        guard let session else { return }
        shareImage = rendered ?? session.renderHighlight()
        showShare = true
    }

    private func saveToPhotos() {
        guard let session else { return }
        let image = rendered ?? session.renderHighlight()
        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
        withAnimation { savedToast = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            withAnimation { savedToast = false }
        }
    }
}

/// Editor for a photo already stored on a route.
struct PhotoEditorView: View {
    let photo: RoutePhoto
    var onUpdate: (RoutePhotoUpdate) -> Void
    @Environment(\.dismiss) private var dismiss

    struct RoutePhotoUpdate {
        var masksBlob: Data
        var holdsJSON: Data
        var previewData: Data?
    }

    @State private var stub = RouteEditView.PhotoStub(image: UIImage(), holds: nil, bitmapSize: nil)
    @State private var loaded = false

    var body: some View {
        Group {
            if loaded {
                PhotoEditorStubView(stub: $stub) {
                    if let holds = stub.holds, let size = stub.bitmapSize {
                        let masks = holds.map { $0.mask }
                        let session = RouteSession(image: stub.image, holds: holds, bitmapSize: size)
                        let blob = MaskCodec.encode(masks, width: size.0, height: size.1)
                        onUpdate(
                            RoutePhotoUpdate(
                                masksBlob: blob,
                                holdsJSON: (try? JSONEncoder().encode(session.storedHolds())) ?? Data(),
                                previewData: session.renderHighlight().jpegData(compressionQuality: 0.85)
                            )
                        )
                    }
                    dismiss()
                }
            } else {
                ProgressView("Загружаю фото…")
            }
        }
        .onAppear {
            if let img = UIImage(data: photo.imageData) {
                var s = stub
                s.image = img
                s.storedID = photo.id
                if let session = RouteSessionDecoder.decode(photo: photo, image: img) {
                    s.holds = session.holds
                    s.bitmapSize = (session.bitmapWidth, session.bitmapHeight)
                }
                stub = s
                loaded = true
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

extension CGSize {
    func fitted(in container: CGSize) -> CGSize {
        let scale = min(container.width / width, container.height / height)
        return CGSize(width: width * scale, height: height * scale)
    }
}
