import Foundation

enum WhatsNewPriority: String, Codable {
    case high
    case medium
    case low
}

enum WhatsNewCategory: String, Codable {
    case transport
    case hotel
    case document
    case app
}

struct WhatsNewItem: Identifiable, Codable {
    let id: String
    let title: String
    let detail: String
    let priority: WhatsNewPriority
    let category: WhatsNewCategory
    let documentRevision: String
}

extension WhatsNewItem {
    static let current: [WhatsNewItem] = [
        WhatsNewItem(
            id: "wai-v2-release",
            title: "WAI v2",
            detail: "Hotel details, saved calculations, settings, and update notes are now part of WAI.",
            priority: .high,
            category: .app,
            documentRevision: "v2.0"
        ),
        WhatsNewItem(
            id: "rev70-ath-added",
            title: "ATH added",
            detail: "Athens now has transport time and hotel information available in WAI.",
            priority: .high,
            category: .transport,
            documentRevision: "REV70 / REV51"
        ),
        WhatsNewItem(
            id: "rev70-cwb-added",
            title: "CWB added",
            detail: "Curitiba now has transport time and hotel information available in WAI.",
            priority: .high,
            category: .transport,
            documentRevision: "REV70 / REV51"
        ),
        WhatsNewItem(
            id: "rev70-rai-added",
            title: "RAI added",
            detail: "Praia now has transport time and hotel information available in WAI.",
            priority: .high,
            category: .transport,
            documentRevision: "REV70 / REV51"
        ),
        WhatsNewItem(
            id: "rev70-sid-added",
            title: "SID added",
            detail: "Sal now has transport time and hotel information available in WAI.",
            priority: .high,
            category: .transport,
            documentRevision: "REV70 / REV51"
        ),
        WhatsNewItem(
            id: "rev70-transport-document",
            title: "Transport Times updated",
            detail: "Transport rules updated to FO/CP/CRS Nº141 REV70 · 29 Jun 2026.",
            priority: .low,
            category: .document,
            documentRevision: "REV70"
        ),
        WhatsNewItem(
            id: "rev51-hotel-document",
            title: "Hotel Map updated",
            detail: "Hotel data updated to FO/CP/CRS Nº140 REV51 · 29 Jun 2026.",
            priority: .medium,
            category: .hotel,
            documentRevision: "REV51"
        )
    ]
}
