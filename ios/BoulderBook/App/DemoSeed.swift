import Foundation
import SwiftData
import UIKit

/// Seeds demo content from bundled wall photos (launch argument -demoSeed).
/// Runs the real detector and the real color selection, so screenshots show
/// the actual highlight rendering.
enum DemoSeed {
    static var isActive: Bool {
        ProcessInfo.processInfo.arguments.contains("-demoSeed")
    }

    static func seedIfNeeded(context: ModelContext) {
        guard isActive else { return }
        let fetched = (try? context.fetch(FetchDescriptor<Album>())) ?? []
        guard fetched.isEmpty else { return }

        let album = Album(name: "Мой зал", symbol: "figure.climbing")
        context.insert(album)

        let demoRoutes: [(image: String, grade: String, notes: String)] = [
            ("wall1", "7A", "Класика на нависании, нужен крюк на полке"),
            ("wall2", "6B+", "Техничная на маленьких зацепках"),
            ("wall3", "7B", "Долгий вынос перед топом"),
        ]

        let group = DispatchGroup()
        for (index, spec) in demoRoutes.enumerated() {
            guard let url = Bundle.main.url(forResource: spec.image, withExtension: "jpg"),
                  let img = UIImage(contentsOfFile: url.path)?.downscaled(maxSide: 2000),
                  let detector = HoldDetector.load() else { continue }
            group.enter()
            detector.detect(image: img) { holds in
                defer { group.leave() }
                guard !holds.isEmpty, let first = holds.first else { return }
                var session = RouteSession(
                    image: img, holds: holds, bitmapSize: (first.bw, first.bh)
                )
                // pick the reference near the image center: usually a real route hold
                _ = session.selectRoute(x: session.bitmapWidth / 2, y: session.bitmapHeight / 2)
                if session.selectionCount < 3 {
                    session.clearSelection()
                    _ = session.selectRoute(
                        x: session.bitmapWidth * 2 / 3, y: session.bitmapHeight / 3
                    )
                }

                let route = ClimbRoute(
                    grade: spec.grade,
                    notes: spec.notes, status: index == 0 ? .sent : .project,
                    attempts: index == 0 ? 4 : 1, album: album
                )
                context.insert(route)

                guard let imageData = img.jpegData(compressionQuality: 0.85) else { return }
                let masks = session.holds.map { $0.mask }
                let blob = MaskCodec.encode(masks, width: session.bitmapWidth, height: session.bitmapHeight)
                let preview = session.renderHighlight().jpegData(compressionQuality: 0.85)
                let photo = RoutePhoto(
                    image: imageData, preview: preview, masksBlob: blob, holds: session.storedHolds(),
                    bitmapSize: (session.bitmapWidth, session.bitmapHeight), sortOrder: 0
                )
                photo.route = route
                context.insert(photo)
            }
        }
        group.notify(queue: .main) {
            try? context.save()
            NotificationCenter.default.post(name: .demoSeedDidFinish, object: nil)
        }
    }
}

extension Notification.Name {
    static let demoSeedDidFinish = Notification.Name("demoSeedDidFinish")
}
