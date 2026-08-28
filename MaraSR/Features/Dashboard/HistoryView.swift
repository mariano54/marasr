import AppKit
import SwiftData
import SwiftUI

struct HistoryView: View {
  @ObservedObject var appState: AppState
  @Environment(\.modelContext) private var modelContext
  @Query(sort: \TranscriptionRecord.createdAt, order: .reverse)
  private var records: [TranscriptionRecord]
  @State private var searchText = ""

  private var filteredRecords: [TranscriptionRecord] {
    guard !searchText.isEmpty else {
      return records
    }
    return records.filter {
      $0.text.localizedCaseInsensitiveContains(searchText)
        || $0.destinationApplication.localizedCaseInsensitiveContains(
          searchText
        )
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 3) {
          Text("Transcription history")
            .font(.title2.bold())
          Text("\(records.count) private, on-device transcripts")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        Spacer()
        if !records.isEmpty {
          Button("Clear history", role: .destructive) {
            records.forEach(modelContext.delete)
            try? modelContext.save()
          }
        }
      }

      if filteredRecords.isEmpty {
        ContentUnavailableView(
          searchText.isEmpty ? "No transcriptions yet" : "No matches",
          systemImage: "waveform",
          description: Text(
            searchText.isEmpty
              ? "Hold Right Command and start speaking."
              : "Try a different search."
          )
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        List {
          ForEach(filteredRecords) { record in
            HistoryRow(record: record) {
              NSPasteboard.general.clearContents()
              NSPasteboard.general.setString(
                record.text,
                forType: .string
              )
            } paste: {
              appState.paste(record.text)
            } delete: {
              modelContext.delete(record)
              try? modelContext.save()
            }
          }
        }
        .listStyle(.inset)
      }
    }
    .padding(24)
    .searchable(text: $searchText, prompt: "Search history")
  }
}

private struct HistoryRow: View {
  let record: TranscriptionRecord
  let copy: () -> Void
  let paste: () -> Void
  let delete: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(record.text)
        .font(.body)
        .textSelection(.enabled)
        .lineLimit(4)

      HStack(spacing: 8) {
        Label(
          record.createdAt.formatted(
            date: .abbreviated,
            time: .shortened
          ),
          systemImage: "calendar"
        )
        Label(
          record.destinationApplication,
          systemImage: "macwindow"
        )
        Text(record.duration.formatted(.number.precision(.fractionLength(1))) + "s")
        Spacer()
        Button("Copy", action: copy)
          .buttonStyle(.borderless)
        Button("Paste", action: paste)
          .buttonStyle(.borderless)
        Button(role: .destructive, action: delete) {
          Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
      }
      .font(.caption)
      .foregroundStyle(.secondary)
    }
    .padding(.vertical, 8)
  }
}
