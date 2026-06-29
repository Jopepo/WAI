import Foundation

@MainActor
final class CalculationHistoryStore: ObservableObject {

    @Published private(set) var history: [CalculationHistoryItem] = []
    @Published private(set) var lastCalculation: CalculationHistoryItem?

    private let historyKey = "wai.calculationHistory"
    private let lastCalculationKey = "wai.lastCalculation"
    private let maxHistoryItems = 25

    init() {
        load()
    }

    func save(_ item: CalculationHistoryItem) {
        lastCalculation = item

        history.removeAll { $0.id == item.id }
        history.insert(item, at: 0)

        if history.count > maxHistoryItems {
            history = Array(history.prefix(maxHistoryItems))
        }

        persist()
    }

    func clearHistory() {
        history = []
        lastCalculation = nil
        persist()
    }

    func delete(_ item: CalculationHistoryItem) {
        history.removeAll { $0.id == item.id }

        if lastCalculation?.id == item.id {
            lastCalculation = history.first
        }

        persist()
    }

    private func load() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        if let lastData = UserDefaults.standard.data(forKey: lastCalculationKey),
           let decodedLast = try? decoder.decode(CalculationHistoryItem.self, from: lastData) {
            lastCalculation = decodedLast
        }

        if let historyData = UserDefaults.standard.data(forKey: historyKey),
           let decodedHistory = try? decoder.decode([CalculationHistoryItem].self, from: historyData) {
            history = decodedHistory
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        if let lastCalculation,
           let lastData = try? encoder.encode(lastCalculation) {
            UserDefaults.standard.set(lastData, forKey: lastCalculationKey)
        } else {
            UserDefaults.standard.removeObject(forKey: lastCalculationKey)
        }

        if let historyData = try? encoder.encode(history) {
            UserDefaults.standard.set(historyData, forKey: historyKey)
        }
    }
}
