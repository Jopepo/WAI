import SwiftUI
import MapKit
import SafariServices

struct HotelDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var pendingContactAction: HotelContactAction?
    @State private var showingMapOptions = false
    @State private var showingWebMaps = false

    let hotel: Hotel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerSection
                    contactSection
                    mapsSection
                }
                .padding()
            }
            .navigationTitle("Hotel")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .confirmationDialog(
                pendingContactAction?.confirmationTitle ?? "Open contact",
                isPresented: Binding(
                    get: { pendingContactAction != nil },
                    set: { newValue in
                        if !newValue {
                            pendingContactAction = nil
                        }
                    }
                ),
                titleVisibility: .visible
            ) {
                if let pendingContactAction {
                    Button(pendingContactAction.buttonTitle) {
                        if let url = pendingContactAction.url {
                            openURL(url)
                        }
                        self.pendingContactAction = nil
                    }
                }

                Button("Cancel", role: .cancel) {
                    pendingContactAction = nil
                }
            } message: {
                if let pendingContactAction {
                    Text(pendingContactAction.value)
                }
            }
        }
        .sheet(isPresented: $showingWebMaps) {
            if let webMapsURL {
                SafariView(url: webMapsURL)
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(hotel.displayName)
                .font(.largeTitle)
                .fontWeight(.bold)
                .multilineTextAlignment(.leading)

            Text("\(hotel.iata) · \(hotel.city)")
                .font(.headline)
                .foregroundStyle(.secondary)

            Text(hotel.country)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var contactSection: some View {
        detailCard {
            VStack(alignment: .leading, spacing: 14) {
                Text("Contact")
                    .font(.headline)

                if let phone = hotel.phone, !phone.isEmpty {
                    contactButton(title: "Phone", value: phone, systemImage: "phone", action: .phone(phone))
                }

                if let email = hotel.email, !email.isEmpty {
                    contactButton(title: "Email", value: email, systemImage: "envelope", action: .email(email))
                }

                if let fax = hotel.fax, !fax.isEmpty {
                    detailRow(title: "Fax", value: fax, systemImage: "printer")
                }
            }
        }
    }

    private var mapsSection: some View {
        detailCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Maps")
                    .font(.headline)

                Text("Open a maps search for this hotel. Confirm the exact location before travelling.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Button {
                    showingMapOptions = true
                } label: {
                    Label("Open in Maps", systemImage: "map")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .confirmationDialog(
                    "Open hotel in maps",
                    isPresented: $showingMapOptions,
                    titleVisibility: .visible
                ) {
                    Button("Apple Maps") {
                        openHotelInAppleMaps()
                    }

                    Button("Google Maps") {
                        openHotelInGoogleMaps()
                    }

                    Button("Web") {
                        showingWebMaps = true
                    }

                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text(hotel.mapsQuery)
                }
            }
        }
    }

    private func contactButton(title: String, value: String, systemImage: String, action: HotelContactAction) -> some View {
        Button {
            pendingContactAction = action
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: systemImage)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Text(value)
                        .font(.subheadline)
                        .multilineTextAlignment(.leading)
                        .foregroundStyle(.primary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func detailRow(title: String, value: String, systemImage: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Text(value)
                    .font(.subheadline)
                    .textSelection(.enabled)
            }
        }
    }

    private func detailCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.gray.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 18))
    }

    private func openHotelInAppleMaps() {
        guard let url = appleMapsURL else { return }
        UIApplication.shared.open(url)
    }

    private func openHotelInGoogleMaps() {
        guard let googleURL = googleMapsURL else {
            openHotelInAppleMaps()
            return
        }

        UIApplication.shared.open(googleURL, options: [:]) { success in
            if !success {
                openHotelInAppleMaps()
            }
        }
    }

    private var appleMapsURL: URL? {
        let encodedQuery = hotel.mapsQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hotel.mapsQuery
        return URL(string: "https://maps.apple.com/?q=\(encodedQuery)")
    }

    private var googleMapsURL: URL? {
        let encodedQuery = hotel.mapsQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hotel.mapsQuery
        return URL(string: "comgooglemaps://?q=\(encodedQuery)")
    }

    private var webMapsURL: URL? {
        let encodedQuery = hotel.mapsQuery.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? hotel.mapsQuery
        return URL(string: "https://www.google.com/maps/search/?api=1&query=\(encodedQuery)")
    }
}

#Preview {
    HotelDetailView(
        hotel: Hotel(
            iata: "OPO",
            icao: "LPPR",
            city: "Porto",
            country: "Portugal",
            name: "PESTANA DOURO RIVERSIDE",
            phone: "+351 229 761 100",
            email: "sofia.rebocho@pestana.com",
            fax: nil
        )
    )
}


private enum HotelContactAction {
    case phone(String)
    case email(String)

    var confirmationTitle: String {
        switch self {
        case .phone:
            return "Call hotel?"
        case .email:
            return "Email hotel?"
        }
    }

    var buttonTitle: String {
        switch self {
        case .phone:
            return "Call"
        case .email:
            return "Open Mail"
        }
    }

    var value: String {
        switch self {
        case .phone(let value), .email(let value):
            return value
        }
    }

    var url: URL? {
        switch self {
        case .phone(let value):
            let sanitized = value
                .components(separatedBy: CharacterSet(charactersIn: "0123456789+").inverted)
                .joined()
            return URL(string: "tel://\(sanitized)")
        case .email(let value):
            let firstEmail = value
                .components(separatedBy: CharacterSet(charactersIn: ";,"))
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty } ?? value
            let encodedEmail = firstEmail.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? firstEmail
            return URL(string: "mailto:\(encodedEmail)")
        }
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) { }
}
