import Darwin
import Foundation
import VoxClipCore

extension ExportSafety {
    package enum PublicationPhase { case willPublish, didPublish, willRollback, willRollbackMove }
    package struct FileIdentity: Equatable, Sendable {
        let device: Int32
        let inode: UInt64
        let birthSeconds: Int64
        let birthNanoseconds: Int64
        init(_ attributes: stat) {
            device = attributes.st_dev; inode = attributes.st_ino
            birthSeconds = Int64(attributes.st_birthtimespec.tv_sec)
            birthNanoseconds = Int64(attributes.st_birthtimespec.tv_nsec)
        }
    }
    package enum DestinationApproval: Equatable, Sendable { case absent, replace(FileIdentity) }

    package static func approveDestinations(_ destinations: [URL]) throws -> [URL: DestinationApproval] {
        var approvals: [URL: DestinationApproval] = [:]
        for destination in destinations {
            var attributes = stat()
            if lstat(destination.path, &attributes) == 0 {
                guard attributes.st_mode & S_IFMT == S_IFREG else {
                    throw VoxClipError.exportFailed("The destination must be a regular file, not a folder or special file")
                }
                approvals[destination] = .replace(FileIdentity(attributes))
            } else if errno == ENOENT { approvals[destination] = .absent }
            else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        return approvals
    }

    package static func publish(_ partial: URL, to destination: URL,
                                approval: DestinationApproval? = nil) throws {
        let approvals = try approval.map { [destination: $0] } ?? approveDestinations([destination])
        try publishAll([(partial, destination)], approvals: approvals)
    }

    private struct Publication {
        let directory: ScratchCleanup.ExportDirectory
        let privateDescriptor: Int32
        let parentDescriptor: Int32
        let staged: URL
        let destination: URL
        let approval: DestinationApproval
        let exported: FileIdentity
        var published = false
        var backup: FileIdentity?
    }

    package static func publishAll(_ outputs: [(partial: URL, destination: URL)],
                                   approvals supplied: [URL: DestinationApproval]? = nil,
                                   events: ((PublicationPhase, URL) throws -> Void)? = nil) throws {
        var publications: [Publication] = []
        var retained: Set<Int> = []
        defer {
            for (index, publication) in publications.enumerated() {
                close(publication.privateDescriptor); close(publication.parentDescriptor)
                if !retained.contains(index) { ScratchCleanup.discardExportDirectory(publication.directory) }
            }
            for output in outputs { discardPartial(output.partial) }
        }
        do {
            let approvals = try supplied ?? approveDestinations(outputs.map(\.destination))
            guard Set(outputs.map(\.destination)).count == outputs.count else {
                throw VoxClipError.exportFailed("Export outputs overlap")
            }
            for output in outputs {
                try Task.checkCancellation()
                guard let approval = approvals[output.destination] else { throw conflict(output.destination) }
                let directory = try ScratchCleanup.createExportDirectory(in: output.destination.deletingLastPathComponent(), recovery: true)
                let privateDescriptor = open(directory.url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                let parentDescriptor = open(output.destination.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard privateDescriptor >= 0, parentDescriptor >= 0 else {
                    let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                    if privateDescriptor >= 0 { close(privateDescriptor) }
                    if parentDescriptor >= 0 { close(parentDescriptor) }
                    ScratchCleanup.discardExportDirectory(directory)
                    throw error
                }
                let staged = directory.url.appendingPathComponent(output.destination.lastPathComponent + ".rollback-" + UUID().uuidString)
                do {
                    guard let exported = try identity(at: output.partial.path, descriptor: AT_FDCWD) else { throw POSIXError(.ENOENT) }
                    try renameItem(output.partial.path, from: AT_FDCWD, to: staged.lastPathComponent, in: privateDescriptor, flags: UInt32(RENAME_EXCL))
                    publications.append(Publication(directory: directory, privateDescriptor: privateDescriptor,
                        parentDescriptor: parentDescriptor, staged: staged, destination: output.destination,
                        approval: approval, exported: exported))
                } catch {
                    close(privateDescriptor); close(parentDescriptor)
                    ScratchCleanup.discardExportDirectory(directory)
                    throw error
                }
            }
            for index in publications.indices {
                try Task.checkCancellation()
                let publication = publications[index]
                try events?(.willPublish, publication.destination)
                let flags = publication.approval == .absent ? UInt32(RENAME_EXCL) : UInt32(RENAME_SWAP)
                do {
                    try renameItem(publication.staged.lastPathComponent, from: publication.privateDescriptor,
                                   to: publication.destination.lastPathComponent, in: publication.parentDescriptor, flags: flags)
                } catch let error as POSIXError where [.EEXIST, .ENOENT, .ENOTEMPTY].contains(error.code) {
                    throw conflict(publication.destination)
                }
                publications[index].published = true
                if case .replace(let approved) = publication.approval {
                    let swapped = try identity(at: publication.staged.lastPathComponent, descriptor: publication.privateDescriptor)
                    publications[index].backup = swapped
                    if swapped != approved { throw conflict(publication.destination) }
                }
                try events?(.didPublish, publication.destination)
            }
            try Task.checkCancellation()
        } catch {
            var rollbackFailure: (any Error)?
            var recoveryMessages: [String] = []
            for index in publications.indices.reversed() where publications[index].published {
                do {
                    try events?(.willRollback, publications[index].destination)
                    try rollback(publications[index], events: events)
                } catch {
                    rollbackFailure = rollbackFailure ?? error
                    let publication = publications[index]
                    if publication.approval != .absent || (try? identity(at: publication.staged.lastPathComponent, descriptor: publication.privateDescriptor)) != nil {
                        retained.insert(index)
                        let path = publication.directory.url.lastPathComponent + "/" + publication.staged.lastPathComponent
                        recoveryMessages.append("\(VoxClipError.exportRecoveryMessagePrefix)\(publication.destination.lastPathComponent). The previous version is saved as \(path).")
                    }
                }
            }
            if !recoveryMessages.isEmpty { throw VoxClipError.exportFailed(recoveryMessages.joined(separator: " ")) }
            if let rollbackFailure { throw rollbackFailure }
            throw error
        }
    }

    private static func rollback(_ publication: Publication,
                                 events: ((PublicationPhase, URL) throws -> Void)?) throws {
        let destination = publication.destination.lastPathComponent
        let staged = publication.staged.lastPathComponent
        let current = try identity(at: destination, descriptor: publication.parentDescriptor)
        if current == nil && publication.approval == .absent { return }
        guard current == publication.exported else { throw conflict(publication.destination) }
        try events?(.willRollbackMove, publication.destination)
        if publication.approval == .absent {
            try renameItem(destination, from: publication.parentDescriptor, to: staged, in: publication.privateDescriptor, flags: UInt32(RENAME_EXCL))
            if try identity(at: staged, descriptor: publication.privateDescriptor) != publication.exported {
                try renameItem(staged, from: publication.privateDescriptor, to: destination, in: publication.parentDescriptor, flags: UInt32(RENAME_EXCL))
                throw conflict(publication.destination)
            }
        } else {
            guard try identity(at: staged, descriptor: publication.privateDescriptor) == publication.backup else { throw conflict(publication.destination) }
            try renameItem(staged, from: publication.privateDescriptor, to: destination, in: publication.parentDescriptor, flags: UInt32(RENAME_SWAP))
            if try identity(at: staged, descriptor: publication.privateDescriptor) != publication.exported {
                try renameItem(staged, from: publication.privateDescriptor, to: destination, in: publication.parentDescriptor, flags: UInt32(RENAME_SWAP))
                throw conflict(publication.destination)
            }
        }
    }

    private static func identity(at name: String, descriptor: Int32) throws -> FileIdentity? {
        var attributes = stat()
        if fstatat(descriptor, name, &attributes, AT_SYMLINK_NOFOLLOW) == 0 { return FileIdentity(attributes) }
        if errno == ENOENT { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    private static func renameItem(_ source: String, from sourceDescriptor: Int32,
                                   to destination: String, in destinationDescriptor: Int32, flags: UInt32) throws {
        guard renameatx_np(sourceDescriptor, source, destinationDescriptor, destination, flags) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    private static func conflict(_ destination: URL) -> VoxClipError {
        .exportFailed("A file named \(destination.lastPathComponent) appeared in the export folder. Export again to replace it, or choose another name.")
    }
}
