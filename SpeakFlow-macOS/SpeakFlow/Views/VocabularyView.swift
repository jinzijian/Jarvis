import SwiftUI
import os.log

private let logger = Logger(subsystem: "com.speakflow", category: "VocabularyView")

struct VocabularyContentEntry: Identifiable {
    let id = UUID()
    var correct: String
    var wrong: String
    var count: Int
    var lastUsed: String
}

struct VocabularyContent: View {
    @EnvironmentObject var appState: AppState
    @State private var entries: [VocabularyContentEntry] = []
    @State private var isLoading = true
    @State private var showAddSheet = false
    @State private var newCorrect = ""
    @State private var newWrong = ""
    @State private var isAdding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Vocabulary")
                        .font(.system(size: 20, weight: .bold))
                    Text("Whisper will use these words to improve transcription accuracy")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button {
                    showAddSheet = true
                } label: {
                    Label("Add", systemImage: "plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            }

            if isLoading {
                HStack {
                    Spacer()
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Loading...")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.top, 40)
            } else if entries.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "text.book.closed")
                        .font(.system(size: 36))
                        .foregroundColor(.secondary.opacity(0.5))
                    Text("No vocabulary entries yet")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.secondary)
                    Text("Corrections you make will be analyzed and added here automatically.\nYou can also add words manually.")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                // Table header
                HStack(spacing: 0) {
                    Text("Correct")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Wrong")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Count")
                        .frame(width: 50, alignment: .center)
                    Text("")
                        .frame(width: 30)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)

                // Entries list
                ForEach(entries) { entry in
                    VocabularyRow(entry: entry) {
                        deleteEntry(entry)
                    }
                }
            }

            Spacer()
        }
        .sheet(isPresented: $showAddSheet) {
            addEntrySheet
        }
        .task {
            await loadEntries()
        }
    }

    // MARK: - Add Entry Sheet

    private var addEntrySheet: some View {
        VStack(spacing: 16) {
            Text("Add Vocabulary Entry")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Text("Correct word")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("e.g. SpeakFlow", text: $newCorrect)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Common misheard as")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                TextField("e.g. speak flow", text: $newWrong)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                Button("Cancel") {
                    showAddSheet = false
                    newCorrect = ""
                    newWrong = ""
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Add") {
                    Task { await addEntry() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(newCorrect.isEmpty || newWrong.isEmpty || isAdding)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    // MARK: - Actions

    private func loadEntries() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let token = try await AuthService.shared.getValidToken()

            var request = URLRequest(url: URL(string: "\(Constants.apiBaseURL)/vocabulary")!)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

            struct APIEntry: Decodable {
                let correct: String
                let wrong: String
                let count: Int
                let last_used: String
            }
            struct APIResponse: Decodable {
                let entries: [APIEntry]
            }

            let result = try JSONDecoder().decode(APIResponse.self, from: data)
            entries = result.entries.map {
                VocabularyContentEntry(correct: $0.correct, wrong: $0.wrong, count: $0.count, lastUsed: $0.last_used)
            }
        } catch {
            logger.error("Failed to load vocabulary: \(error.localizedDescription)")
        }
    }

    private func addEntry() async {
        isAdding = true
        defer { isAdding = false }

        do {
            let token = try await AuthService.shared.getValidToken()

            var request = URLRequest(url: URL(string: "\(Constants.apiBaseURL)/vocabulary")!)
            request.httpMethod = "POST"
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")

            let body = ["correct": newCorrect, "wrong": newWrong]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

            showAddSheet = false
            newCorrect = ""
            newWrong = ""
            await loadEntries()
            await VocabularyService.shared.syncVocabulary()
        } catch {
            logger.error("Failed to add vocabulary: \(error.localizedDescription)")
        }
    }

    private func deleteEntry(_ entry: VocabularyContentEntry) {
        Task {
            do {
                let token = try await AuthService.shared.getValidToken()
                let correctEncoded = entry.correct.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.correct
                let wrongEncoded = entry.wrong.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? entry.wrong

                var request = URLRequest(url: URL(string: "\(Constants.apiBaseURL)/vocabulary/\(correctEncoded)/\(wrongEncoded)")!)
                request.httpMethod = "DELETE"
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

                let (_, response) = try await URLSession.shared.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else { return }

                entries.removeAll { $0.id == entry.id }
                await VocabularyService.shared.syncVocabulary()
            } catch {
                logger.error("Failed to delete vocabulary: \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Row View

private struct VocabularyRow: View {
    let entry: VocabularyContentEntry
    let onDelete: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(entry.correct)
                .font(.system(size: 13, weight: .medium))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.wrong)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(entry.count)")
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 50, alignment: .center)

            Button {
                onDelete()
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundColor(.red.opacity(isHovering ? 1 : 0))
            }
            .buttonStyle(.plain)
            .frame(width: 30)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color(nsColor: .controlBackgroundColor) : Color.clear)
        )
        .onHover { isHovering = $0 }
    }
}
