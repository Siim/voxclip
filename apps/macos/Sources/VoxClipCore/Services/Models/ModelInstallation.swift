import Foundation

extension ModelStore {
    struct Marker: Codable { let files: [ModelFile]; let installedAt: Date }
    struct Partial: Codable, Equatable { let url: URL; let bytes: Int64; let sha256: String }

    func modelDirectory(_ model: ModelDescriptor) -> URL { locations.models.appendingPathComponent(model.engine.rawValue).appendingPathComponent(model.id) }
    func fileURL(_ model: ModelDescriptor, _ file: ModelFile) -> URL { modelDirectory(model).appendingPathComponent(file.name) }
    func isInstalled(_ model: ModelDescriptor) -> Bool {
        let url = modelDirectory(model).appendingPathComponent("installed.json")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url), let marker = try? decoder.decode(Marker.self, from: data),
              marker.files.map({ Partial(url: URL(fileURLWithPath: $0.name), bytes: $0.bytes, sha256: $0.sha256) }) == model.files.map({ Partial(url: URL(fileURLWithPath: $0.name), bytes: $0.bytes, sha256: $0.sha256) }) else { return false }
        return model.files.allSatisfy { size(fileURL(model, $0)) == $0.bytes }
    }
    func size(_ url: URL) -> Int64 { (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0 }

    func installModel(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        guard !queued.contains(id) else { return }
        queued.insert(id)
        defer { queued.remove(id) }
        while busy { try await Task.sleep(for: .milliseconds(50)) }
        busy = true
        defer { busy = false }
        try await ModelInstallationGate.shared.acquire()
        do {
            try await performInstall(id: id, progress: progress)
            await ModelInstallationGate.shared.release()
        } catch {
            await ModelInstallationGate.shared.release()
            throw error
        }
    }

    private func performInstall(id: String, progress: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        let model = try await catalog.model(id: id)
        var ordered: [ModelDescriptor] = []
        var visited: Set<String> = []
        func collect(_ descriptor: ModelDescriptor, ancestors: Set<String>) async throws {
            guard !ancestors.contains(descriptor.id) else { throw VoxClipError.transcriptionFailed("Cyclic model dependencies") }
            if visited.contains(descriptor.id) { return }
            for required in descriptor.requires { try await collect(catalog.model(id: required), ancestors: ancestors.union([descriptor.id])) }
            visited.insert(descriptor.id)
            ordered.append(descriptor)
        }
        try await collect(model, ancestors: [])
        guard ordered.contains(where: { !isInstalled($0) }) else { return }
        let total = ordered.reduce(Int64(0)) { $0 + $1.totalBytes }
        try FileManager.default.createDirectory(at: locations.models, withIntermediateDirectories: true)
        let remaining = ordered.reduce(Int64(0)) { sum, entry in
            if isInstalled(entry) { return sum }
            return sum + entry.files.reduce(Int64(0)) { subtotal, file in
                let destination = fileURL(entry, file)
                if size(destination) == file.bytes, (try? SpeechSHA256.file(destination)) == file.sha256 { return subtotal }
                let sidecar = destination.appendingPathExtension("partial.json")
                let recorded = (try? Data(contentsOf: sidecar)).flatMap { try? JSONDecoder().decode(Partial.self, from: $0) }
                let matching = recorded == Partial(url: file.url, bytes: file.bytes, sha256: file.sha256)
                let partialBytes = matching ? min(file.bytes, size(destination.appendingPathExtension("partial"))) : 0
                return subtotal + max(0, file.bytes - partialBytes)
            }
        }
        let capacity = try availableCapacity(locations.models)
        if let capacity, Double(capacity) < Double(remaining) * 1.1 + 1_073_741_824 { throw VoxClipError.diskFull("Not enough room for the model") }
        try Task.checkCancellation()
        guard let confirmation, try await confirmation(model, total) else { throw VoxClipError.cancelled }
        var finished: Int64 = 0
        do {
            for entry in ordered {
                try Task.checkCancellation()
                if isInstalled(entry) { finished += entry.totalBytes; continue }
                try FileManager.default.createDirectory(at: modelDirectory(entry), withIntermediateDirectories: true)
                for file in entry.files {
                    let base = finished
                    try await fetch(file, at: fileURL(entry, file)) { received in
                        progress(ModelDownloadProgress(modelID: id, receivedBytes: base + received, totalBytes: total))
                    }
                    finished += file.bytes
                }
                progress(ModelDownloadProgress(modelID: id, receivedBytes: finished, totalBytes: total, verifying: true))
                var object: [String: Any]
                if let bundled = catalog as? BundledModelCatalog {
                    let entryData = try await bundled.entryJSON(id: entry.id)
                    object = try JSONSerialization.jsonObject(with: entryData) as? [String: Any] ?? [:]
                } else {
                    object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any] ?? [:]
                }
                object["installedAt"] = ISO8601DateFormatter().string(from: Date())
                try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: modelDirectory(entry).appendingPathComponent("installed.json"), options: .atomic)
            }
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled { throw VoxClipError.cancelled }
            if (error as NSError).code == NSFileWriteOutOfSpaceError { throw VoxClipError.diskFull("Model download") }
            throw error
        }
    }

    private func fetch(_ file: ModelFile, at destination: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        if size(destination) == file.bytes, try SpeechSHA256.file(destination) == file.sha256 { progress(file.bytes); return }
        let partial = destination.appendingPathExtension("partial")
        let sidecar = destination.appendingPathExtension("partial.json")
        let expected = Partial(url: file.url, bytes: file.bytes, sha256: file.sha256)
        let previous = (try? Data(contentsOf: sidecar)).flatMap { try? JSONDecoder().decode(Partial.self, from: $0) }
        if previous != expected || size(partial) > file.bytes { try? FileManager.default.removeItem(at: partial) }
        try JSONEncoder().encode(expected).write(to: sidecar, options: .atomic)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            do {
                var verified = false
                if size(partial) != file.bytes {
                    if file.url.isFileURL {
                        let input = try FileHandle(forReadingFrom: file.url)
                        defer { try? input.close() }
                        let offset = size(partial)
                        try input.seek(toOffset: UInt64(offset))
                        if !FileManager.default.fileExists(atPath: partial.path) { FileManager.default.createFile(atPath: partial.path, contents: nil) }
                        let output = try FileHandle(forWritingTo: partial)
                        defer { try? output.close() }
                        try output.seekToEnd()
                        var received = offset
                        while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty { try Task.checkCancellation(); try output.write(contentsOf: chunk); received += Int64(chunk.count); progress(received) }
                    } else {
                        try await ModelHTTPDownload.run(file: file, partial: partial, configuration: configuration, progress: progress)
                        verified = true
                    }
                }
                guard size(partial) == file.bytes, try verified || SpeechSHA256.file(partial) == file.sha256 else {
                    try? FileManager.default.removeItem(at: partial)
                    throw VoxClipError.modelChecksumMismatch(file.name)
                }
                if FileManager.default.fileExists(atPath: destination.path) { _ = try FileManager.default.replaceItemAt(destination, withItemAt: partial) }
                else { try FileManager.default.moveItem(at: partial, to: destination) }
                try? FileManager.default.removeItem(at: sidecar)
                progress(file.bytes)
                return
            } catch let failure as SpeechHTTPFailure {
                guard attempt < 2, failure.retryable else { throw VoxClipError.providerError("Model host HTTP \(failure.status)") }
                try await Task.sleep(for: .seconds(failure.retryAfter ?? Double(1 << attempt)))
            } catch let error as URLError {
                guard error.code != .cancelled else { throw error }
                guard attempt < 2 else { throw VoxClipError.offline }
                try await Task.sleep(for: .seconds(1 << attempt))
            }
        }
    }
}

actor ModelInstallationGate {
    static let shared = ModelInstallationGate()
    private var busy = false
    func acquire() async throws {
        while busy { try await Task.sleep(for: .milliseconds(50)) }
        try Task.checkCancellation()
        busy = true
    }
    func release() { busy = false }
}
