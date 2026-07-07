import SwiftUI

struct RoomNumberEditView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var roomNumber: String

    let item: CalculationHistoryItem
    let onSave: (CalculationHistoryItem, String) -> Void

    init(
        item: CalculationHistoryItem,
        onSave: @escaping (CalculationHistoryItem, String) -> Void
    ) {
        self.item = item
        self.onSave = onSave
        _roomNumber = State(initialValue: item.roomNumber ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Saved calculation") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(item.stationIATA) - \(item.stationCity)")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        Text("ETD: \(formattedDate(item.etdDate)) · \(item.inputTimeText) · \(item.inputReference.title)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }

                Section("Room") {
                    TextField("Room number", text: $roomNumber)
                        .keyboardType(.numbersAndPunctuation)
                }
            }
            .navigationTitle("Room Number")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") {
                        dismiss()
                    }
                }

                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(item, roomNumber)
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }

    private func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }
}

#Preview {
    RoomNumberEditView(
        item: CalculationHistoryItem(
            stationIATA: "OPO",
            stationCity: "Porto",
            etdDate: Date(),
            inputReference: .utc,
            inputTimeText: "06:00",
            pickupTimeText: "04:30 OPO (04:30 LIS)",
            wakeupTimeText: "03:30 OPO (03:30 LIS)",
            roomNumber: nil,
            appliedRuleLabel: nil
        ),
        onSave: { _, _ in }
    )
}
