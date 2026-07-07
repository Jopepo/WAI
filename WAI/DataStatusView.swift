import SwiftUI

struct DataStatusView: View {
    @Environment(\.dismiss) private var dismiss
    @StateObject private var dataService = DataService.shared
    @StateObject private var hotelDataService = HotelDataService.shared
    @StateObject private var whatsNewDataService = WhatsNewDataService.shared

    let lastRefreshCheck: Date?

    var body: some View {
        NavigationStack {
            List {
                Section("Last check") {
                    HStack {
                        Text("Checked")
                        Spacer()
                        Text(lastRefreshCheck.map(formattedDateTime) ?? "Not yet")
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Data sources") {
                    dataSourceRow(
                        title: "Transport Times",
                        sourceInfo: dataService.sourceInfo,
                        remoteURL: RemoteDataConfiguration.transportRulesURL
                    )

                    dataSourceRow(
                        title: "Hotel Map",
                        sourceInfo: hotelDataService.sourceInfo,
                        remoteURL: RemoteDataConfiguration.hotelMapURL
                    )

                    dataSourceRow(
                        title: "What's New",
                        sourceInfo: whatsNewDataService.sourceInfo,
                        remoteURL: RemoteDataConfiguration.whatsNewURL
                    )
                }
            }
            .navigationTitle("Data Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func dataSourceRow(
        title: String,
        sourceInfo: OperationalDataSourceInfo,
        remoteURL: URL?
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Spacer()

                Text(sourceInfo.sourceLabel)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.gray.opacity(0.12))
                    .clipShape(Capsule())
            }

            Text(sourceInfo.document)
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack {
                Text(sourceInfo.revision)
                    .font(.caption)
                    .fontWeight(.semibold)

                Text(formattedDocumentDate(sourceInfo.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let remoteURL {
                Text(remoteURL.absoluteString)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDocumentDate(_ rawDate: String) -> String {
        let inputFormatter = DateFormatter()
        inputFormatter.dateFormat = "yyyy-MM-dd"
        inputFormatter.locale = Locale(identifier: "en_US_POSIX")

        guard let date = inputFormatter.date(from: rawDate) else {
            return rawDate
        }

        let outputFormatter = DateFormatter()
        outputFormatter.dateStyle = .medium
        outputFormatter.timeStyle = .none
        return outputFormatter.string(from: date)
    }

    private func formattedDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

#Preview {
    DataStatusView(lastRefreshCheck: Date())
}
