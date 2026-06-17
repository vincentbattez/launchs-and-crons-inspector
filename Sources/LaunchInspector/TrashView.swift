import SwiftUI

/// Corbeille interne : liste des jobs supprimés, avec restauration.
struct TrashView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if model.trash.isEmpty {
                    ContentUnavailableView(
                        "Corbeille vide",
                        systemImage: "trash",
                        description: Text("Les jobs supprimés apparaissent ici et peuvent être restaurés.")
                    )
                } else {
                    List {
                        ForEach(model.trash.sorted { $0.date > $1.date }) { entry in
                            TrashRow(entry: entry)
                        }
                    }
                }
            }
            .navigationTitle("Corbeille")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Fermer") { dismiss() }
                }
            }
        }
        .frame(minWidth: 520, minHeight: 380)
    }
}

private struct TrashRow: View {
    let entry: TrashEntry
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.displayName).fontWeight(.medium)
                Text("\(entry.kind.label) · supprimé le \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let path = entry.originalPath {
                    Text(path).font(.caption2).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
                } else if let line = entry.cronLine {
                    Text(line).font(.system(.caption2, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer()
            Button("Restaurer", systemImage: "arrow.uturn.backward") {
                Task { await model.restore(entry) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 2)
    }
}
