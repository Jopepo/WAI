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
    let items: [WhatsNewItem]

    var sourceInfo: OperationalDataDocumentSource? {
        source
    }
}

struct WhatsNewItem: Identifiable, Codable {
    let id: String
    let title: String
    let detail: String
    let priority: WhatsNewPriority
    let category: WhatsNewCategory
    let documentRevision: String
}
