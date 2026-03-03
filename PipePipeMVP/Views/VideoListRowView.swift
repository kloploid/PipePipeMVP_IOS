import SwiftUI

struct VideoListRowView: View {
    let item: VideoItem

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: item.thumbnailURL) { phase in
                switch phase {
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                default:
                    Color.gray.opacity(0.2)
                }
            }
            .frame(width: 120, height: 68)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 5) {
                Text(item.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(2)
                Text(item.channelTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    if let published = item.publishedText {
                        Text(published)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if let duration = item.durationText {
                        Text("• \(duration)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else if item.isLive {
                        Text("• LIVE")
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.red)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }
}
