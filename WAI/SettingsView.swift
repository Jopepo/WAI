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
            VStack(alignment: .leading, spacing: 10) {
                Text("Documents")
                    .font(.headline)

                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Transport Times")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("FO/CP/CRS Nº141")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    VStack(alignment: .trailing, spacing: 4) {
                        Text("REV70")
                            .font(.subheadline)
                            .fontWeight(.bold)

                        Text("29 Jun 2026")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
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

    private var feedbackMailtoURL: URL {
        let subject = "WAI Feedback"
        let body = """
        Hi João,

        I want to send feedback about WAI.

        Transport document: FO/CP/CRS Nº141 REV70 · 29 Jun 2026
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
