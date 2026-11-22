import Foundation
import SwiftData
import Compression

// MARK: - Mask codec

/// Binary hold-mask blob: header (w, h as UInt32) + zlib-deflated per-hold bitmap.
enum MaskCodec {
    static func encode(_ masks: [[UInt8]], width: Int, height: Int) -> Data {
        var header = Data(capacity: 8 + masks.count * 4)
        appendUInt32(&header, UInt32(width))
        appendUInt32(&header, UInt32(height))
        for m in masks {
            guard let deflated = zlib(Data(m), compress: true) else { continue }
            appendUInt32(&header, UInt32(deflated.count))
            header.append(deflated)
        }
        return header
    }

    static func decode(_ data: Data) -> (masks: [[UInt8]], width: Int, height: Int)? {
        guard data.count >= 8 else { return nil }
        let width = Int(readUInt32(data, 0))
        let height = Int(readUInt32(data, 4))
        guard width > 0, height > 0 else { return nil }
        var offset = 8
        var masks: [[UInt8]] = []
        while offset + 4 <= data.count {
            let size = Int(readUInt32(data, offset))
            offset += 4
            guard offset + size <= data.count else { return nil }
            let blob = data.subdata(in: offset..<(offset + size))
            offset += size
            guard let raw = zlib(blob, compress: false),
                  raw.count == width * height else { return nil }
            masks.append(Array(raw))
        }
        return (masks, width, height)
    }

    private static func zlib(_ data: Data, compress: Bool) -> Data? {
        let input = [UInt8](data)
        let bufferSize = compress ? input.count + 4096 : input.count * 8 + 4096
        var output = [UInt8](repeating: 0, count: bufferSize)
        let status = input.withUnsafeBufferPointer { src in
            output.withUnsafeMutableBufferPointer { dst in
                if compress {
                    compression_encode_buffer(
                        dst.baseAddress!, dst.count,
                        src.baseAddress!, src.count,
                        nil, COMPRESSION_ZLIB
                    )
                } else {
                    compression_decode_buffer(
                        dst.baseAddress!, dst.count,
                        src.baseAddress!, src.count,
                        nil, COMPRESSION_ZLIB
                    )
                }
            }
        }
        guard status > 0 else { return nil }
        return Data(output[0..<status])
    }

    private static func appendUInt32(_ data: inout Data, _ value: UInt32) {
        let v = value.littleEndian
        data.append(contentsOf: [UInt8(v & 0xff), UInt8((v >> 8) & 0xff), UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)])
    }

    private static func readUInt32(_ data: Data, _ offset: Int) -> UInt32 {
        let bytes = [UInt8](data.subdata(in: offset..<(offset + 4)))
        return UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
    }
}

// MARK: - Entities

enum RouteStatus: String, Codable, CaseIterable {
    case project
    case sent

    var label: String { self == .project ? "Проект" : "Пролез" }
    var symbol: String { self == .project ? "flag" : "checkmark.seal.fill" }
}

/// Decoded per-photo hold data kept alongside the image blob.
struct StoredHold: Codable {
    var id: Int
    var box: [Int]        // x0, y0, x1, y1 in bitmap coords
    var lab: [Double]     // OpenCV-scaled LAB
    var bgr: [Double]
    var conf: Double
    var selected: Bool
}

@Model
final class RoutePhoto {
    @Attribute(.unique) var id: UUID
    var sortOrder: Int
    @Attribute(.externalStorage) var imageData: Data
    /// Pre-rendered outline view for previews (nil -> fall back to imageData).
    @Attribute(.externalStorage) var previewData: Data?
    @Attribute(.externalStorage) var masksBlob: Data
    var holdsJSON: Data
    var bitmapWidth: Int
    var bitmapHeight: Int
    var route: ClimbRoute?

    init(
        image: Data, preview: Data? = nil, masksBlob: Data, holds: [StoredHold],
        bitmapSize: (Int, Int), sortOrder: Int
    ) {
        self.id = UUID()
        self.sortOrder = sortOrder
        self.imageData = image
        self.previewData = preview
        self.masksBlob = masksBlob
        self.holdsJSON = (try? JSONEncoder().encode(holds)) ?? Data("[]".utf8)
        self.bitmapWidth = bitmapSize.0
        self.bitmapHeight = bitmapSize.1
    }

    var holds: [StoredHold] {
        (try? JSONDecoder().decode([StoredHold].self, from: holdsJSON)) ?? []
    }
}

@Model
final class ClimbRoute {
    @Attribute(.unique) var id: UUID
    var grade: String
    var levelRaw: Int?
    var notes: String
    var statusRaw: String
    var attempts: Int
    var createdAt: Date
    var climbedAt: Date?
    var album: Album?
    @Relationship(deleteRule: .cascade, inverse: \RoutePhoto.route) var photos: [RoutePhoto]

    var level: Int {
        get { levelRaw ?? 5 }
        set { levelRaw = newValue }
    }

    init(
        grade: String = "", level: Int = 5, notes: String = "",
        status: RouteStatus = .project, attempts: Int = 0, album: Album? = nil
    ) {
        self.id = UUID()
        self.grade = grade
        self.levelRaw = level
        self.notes = notes
        self.statusRaw = status.rawValue
        self.attempts = attempts
        self.createdAt = Date()
        self.climbedAt = nil
        self.album = album
        self.photos = []
    }

    var status: RouteStatus {
        get { RouteStatus(rawValue: statusRaw) ?? .project }
        set { statusRaw = newValue.rawValue; if newValue == .sent && climbedAt == nil { climbedAt = Date() } }
    }

    var sortedPhotos: [RoutePhoto] {
        photos.sorted { $0.sortOrder < $1.sortOrder }
    }

    var cover: RoutePhoto? { sortedPhotos.first }
}

@Model
final class Album {
    @Attribute(.unique) var id: UUID
    var name: String
    var symbol: String
    var createdAt: Date
    @Relationship(deleteRule: .cascade, inverse: \ClimbRoute.album) var routes: [ClimbRoute]

    init(name: String, symbol: String = "square.stack.3d.up") {
        self.id = UUID()
        self.name = name
        self.symbol = symbol
        self.createdAt = Date()
        self.routes = []
    }
}
