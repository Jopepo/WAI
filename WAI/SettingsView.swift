//
//  SettingsView.swift
//  WAI
//
//  Created by Jopepo on 29/06/2026.
//

import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var timeInputReferenceRawValue: String
    @StateObject private var dataService = DataService.shared
    @StateObject private var hotelDataService = HotelDataService.shared
    @StateObject private var whatsNewDataService = WhatsNewDataService.shared
    @State private var isRefreshingData = false
    @State private var refreshStatusMessage: String?
    @State private var lastRefreshCheck: Date?

    private var timeInputReference: Binding<TimeInputReference> {
        Binding(
            get: {
                TimeInputReference(rawValue: timeInputReferenceRawValue) ?? .utc
            },
            set: { newValue in
                timeInputReferenceRawValue = newValue.rawValue
            }
        )
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerSection
                    timeInputSection
                    documentsSection
                    appSection
                    feedbackSection
                }
                .padding()
            }
            .navigationTitle("Settings")
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

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("WAI Settings")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Fine-tune how WAI reads your flight times and check the current data source.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var timeInputSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Time input")
                    .font(.headline)

                Text("Choose how WAI should read the time you enter in the calculator.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Picker("Time input", selection: timeInputReference) {
                    ForEach(TimeInputReference.allCases) { reference in
                        Text(reference.title).tag(reference)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
    }

    private var documentsSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Documents")
                        .font(.headline)

                    Spacer()

                    Button {
                        refreshOperationalData()
                    } label: {
                        if isRefreshingData {
                            ProgressView()
                        } else {
                            Label("Refresh", systemImage: "arrow.clockwise")
                        }
                    }
                    .font(.subheadline)
                    .disabled(isRefreshingData)
                }

                if let refreshStatusMessage {
                    Text(refreshStatusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                documentRow(
                    title: "Transport Times",
                    sourceInfo: dataService.sourceInfo
                )

                Divider()

                documentRow(
                    title: "Hotel Map",
                    sourceInfo: hotelDataService.sourceInfo
                )
            }
        }
    }

    private func documentRow(title: String, sourceInfo: OperationalDataSourceInfo) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Text(sourceInfo.document)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(sourceInfo.sourceLabel)
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.gray.opacity(0.12))
                    .clipShape(Capsule())
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(sourceInfo.revision)
                    .font(.subheadline)
                    .fontWeight(.bold)

                Text(formattedDocumentDate(sourceInfo.date))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var appSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 10) {
                Text("App")
                    .font(.headline)

                HStack {
                    Text("Version")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Spacer()

                    Text(appVersionLabel)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                }
            }
        }
    }

    private var feedbackSection: some View {
        settingsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Feedback")
                    .font(.headline)

                Text("Found a wrong transport time, bug, or confusing result?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Link(destination: feedbackMailtoURL) {
                    Label("Send feedback", systemImage: "envelope")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func refreshOperationalData() {
        isRefreshingData = true
        refreshStatusMessage = "Checking for data updates..."

        Task {
            let transportUpdated = await dataService.refreshRemoteData()
            let hotelUpdated = await hotelDataService.refreshRemoteData()
            let whatsNewUpdated = await whatsNewDataService.refreshRemoteData()
            lastRefreshCheck = Date()
            refreshStatusMessage = refreshSummary(
                transportUpdated: transportUpdated,
                hotelUpdated: hotelUpdated,
                whatsNewUpdated: whatsNewUpdated
            )
            isRefreshingData = false
        }
    }

    private func refreshSummary(
        transportUpdated: Bool,
        hotelUpdated: Bool,
        whatsNewUpdated: Bool
    ) -> String {
        let updatedCount = [transportUpdated, hotelUpdated, whatsNewUpdated].filter { $0 }.count
        let checkedAt = lastRefreshCheck.map { formattedRefreshTime($0) } ?? "now"

        if updatedCount == 3 {
            return "Updated all data sources · Checked \(checkedAt)"
        }

        if updatedCount > 0 {
            return "Updated \(updatedCount) of 3 data sources · Checked \(checkedAt)"
        }

        return "No remote updates applied; using current cached or bundled data · Checked \(checkedAt)"
    }

    private func formattedRefreshTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
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

    private var feedbackMailtoURL: URL {
        let subject = "WAI Feedback"
        let body = """
        Hi João,

        I want to send feedback about WAI.

        Transport document: FO/CP/CRS Nº141 REV71 · 03 Jul 2026
        App version: \(appVersionLabel)

        Feedback / bug:

        """

        let encodedSubject = subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? subject
        let encodedBody = body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? body
        let urlString = "mailto:joao.p.possidonio@gmail.com?subject=\(encodedSubject)&body=\(encodedBody)"

        return URL(string: urlString) ?? URL(string: "mailto:joao.p.possidonio@gmail.com")!
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
        return "\(version) · Build \(build)"
    }
}

#Preview {
    SettingsView(timeInputReferenceRawValue: .constant(TimeInputReference.utc.rawValue))
}
