import Foundation

struct TranslationHistoryEntry: Codable, Identifiable, Sendable {
    let id: UUID
    let documentName: String
    let completedAt: Date
    let pageCount: Int
    let translatedFilename: String
    let bilingualFilename: String
}

struct TranslationHistoryStore: Sendable {
    struct Documents {
        let source: URL
        let translated: URL
        let bilingual: URL
    }

    let root: URL

    func directory(for id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func prepare(id: UUID, source: URL) throws -> URL {
        let job = directory(for: id)
        try FileManager.default.createDirectory(
            at: job, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let snapshot = job.appendingPathComponent("source.pdf")
        try FileManager.default.copyItem(at: source.resolvingSymlinksInPath(), to: snapshot)
        return snapshot
    }

    func record(
        id: UUID, documentName: String, pageCount: Int, translated: URL, bilingual: URL
    ) throws {
        let job = directory(for: id).resolvingSymlinksInPath()
        guard translated.deletingLastPathComponent() == job,
              bilingual.deletingLastPathComponent() == job else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let entry = TranslationHistoryEntry(
            id: id, documentName: documentName, completedAt: Date(), pageCount: pageCount,
            translatedFilename: translated.lastPathComponent, bilingualFilename: bilingual.lastPathComponent
        )
        _ = try documents(for: entry)
        try JSONEncoder().encode(entry).write(to: manifest(in: job), options: .atomic)
    }

    func entries() -> [TranslationHistoryEntry] {
        let jobs = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
        )) ?? []
        return jobs.compactMap { job -> TranslationHistoryEntry? in
            guard let id = UUID(uuidString: job.lastPathComponent),
                  let data = try? Data(contentsOf: manifest(in: job)),
                  let entry = try? JSONDecoder().decode(TranslationHistoryEntry.self, from: data),
                  entry.id == id, entry.pageCount > 0,
                  (try? documents(for: entry)) != nil else { return nil }
            return entry
        }.sorted {
            if $0.completedAt == $1.completedAt { return $0.id.uuidString < $1.id.uuidString }
            return $0.completedAt > $1.completedAt
        }
    }

    func documents(for entry: TranslationHistoryEntry) throws -> Documents {
        let job = directory(for: entry.id).resolvingSymlinksInPath()

        func pdf(_ filename: String) throws -> URL {
            guard !filename.contains("/"), (filename as NSString).pathExtension.lowercased() == "pdf" else {
                throw CocoaError(.fileReadInvalidFileName)
            }
            let url = job.appendingPathComponent(filename).resolvingSymlinksInPath()
            guard url.deletingLastPathComponent() == job,
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return url
        }

        return try Documents(
            source: pdf("source.pdf"),
            translated: pdf(entry.translatedFilename),
            bilingual: pdf(entry.bilingualFilename)
        )
    }

    func discardIncomplete(id: UUID) {
        let job = directory(for: id)
        guard !FileManager.default.fileExists(atPath: manifest(in: job).path) else { return }
        try? FileManager.default.removeItem(at: job)
    }

    private func manifest(in job: URL) -> URL {
        job.appendingPathComponent("history.json")
    }
}
