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
        guard !items.isEmpty,
              items.count <= 100,
              maxVisibleItems.map({ (1...100).contains($0) }) != false,
              source.map(\.isValid) != false else {
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
        OperationalDataFormat.isBoundedText(id, maximumBytes: 128)
        && OperationalDataFormat.isBoundedText(title, maximumBytes: 256)
        && OperationalDataFormat.isBoundedText(detail, maximumBytes: 4_096)
        && OperationalDataFormat.isBoundedText(
            documentRevision,
            maximumBytes: 128
        )
    }
}
