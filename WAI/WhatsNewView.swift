import SwiftUI

struct WhatsNewView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataService = WhatsNewDataService.shared

    private var items: [WhatsNewItem] {
        dataService.items
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerSection

                    ForEach(items) { item in
                        whatsNewCard(item)
                    }
                }
                .padding()
            }
            .navigationTitle("What's New")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .task {
            await dataService.refreshRemoteData()
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("What's New")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Recent updates to transport times, hotel data, and app behaviour.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func whatsNewCard(_ item: WhatsNewItem) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                priorityIcon(for: item.priority)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(item.title)
                            .font(item.priority == .high ? .headline : .subheadline)
                            .fontWeight(item.priority == .high ? .bold : .semibold)

                        Spacer()

                        Text(item.documentRevision)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.gray.opacity(0.12))
                            .clipShape(Capsule())
                    }

                    Text(item.detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(backgroundOpacity(for: item.priority))
        .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func priorityIcon(for priority: WhatsNewPriority) -> some View {
        Image(systemName: iconName(for: priority))
            .font(.headline)
            .foregroundStyle(iconColor(for: priority))
            .frame(width: 24)
    }

    private func iconName(for priority: WhatsNewPriority) -> String {
        switch priority {
        case .high:
            return "star.fill"
        case .medium:
            return "info.circle.fill"
        case .low:
            return "doc.text.fill"
        }
    }

    private func iconColor(for priority: WhatsNewPriority) -> Color {
        switch priority {
        case .high:
            return .orange
        case .medium:
            return .blue
        case .low:
            return .secondary
        }
    }

    private func backgroundOpacity(for priority: WhatsNewPriority) -> Color {
        switch priority {
        case .high:
            return .orange.opacity(0.12)
        case .medium:
            return .blue.opacity(0.08)
        case .low:
            return .gray.opacity(0.08)
        }
    }
}

#Preview {
    WhatsNewView()
}
