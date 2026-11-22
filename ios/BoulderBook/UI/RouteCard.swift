import SwiftUI

struct RouteCard: View {
    let route: ClimbRoute
    var compact = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack(alignment: .topLeading) {
                cover
                    .frame(width: compact ? 140 : nil, height: compact ? 170 : 180)
                    .frame(maxWidth: compact ? 140 : .infinity)
                    .clipped()
                statusBadge
                    .padding(8)
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if !route.grade.isEmpty {
                        Text(route.grade)
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Theme.gradeColor(route.grade).opacity(0.25), in: Capsule())
                            .foregroundStyle(Theme.gradeColor(route.grade))
                    }
                    Text(route.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                }
                HStack(spacing: 4) {
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.caption2)
                    Text("\(route.photos.count)")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    @ViewBuilder
    private var cover: some View {
        if let cover = route.cover {
            GeometryReader { geo in
                Image(uiImage: UIImage(data: cover.previewData ?? cover.imageData) ?? UIImage())
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
            }
        } else {
            ZStack {
                Rectangle().fill(Theme.accentDim.opacity(0.25))
                Image(systemName: "figure.climbing")
                    .font(.largeTitle)
                    .foregroundStyle(Theme.accent)
            }
        }
    }

    private var statusBadge: some View {
        HStack(spacing: 3) {
            Image(systemName: route.status == .sent ? "checkmark.seal.fill" : "flag.fill")
                .font(.caption2)
            Text(route.status.label)
                .font(.caption2.weight(.semibold))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(.ultraThinMaterial, in: Capsule())
        .foregroundStyle(route.status == .sent ? Theme.accent : Theme.warm)
    }
}
