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

struct WhatsNewDocument: Codable, OperationalDataDocument {
    let source: OperationalDataDocumentSource?
    let maxVisibleItems: Int?
    let items: [WhatsNewItem]

    var sourceInfo: OperationalDataDocumentSource? {
        source
    }

    var isValid: Bool {
        guard !items.isEmpty else {
            return false
        }

        let ids = items.map(\.id)
        guard Set(ids).count == ids.count else {
            return false
        }

        return items.allSatisfy(\.isValid)
    }
}

struct WhatsNewItem: Identifiable, Codable {
    let id: String
    let title: String
    let detail: String
    let priority: WhatsNewPriority
    let category: WhatsNewCategory
    let documentRevision: String

    var isValid: Bool {
        !id.isEmpty
        && !title.isEmpty
        && !detail.isEmpty
        && !documentRevision.isEmpty
    }
}
