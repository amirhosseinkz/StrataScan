import Foundation

/// Reasons a local interchange directory cannot be safely archived.
///
/// The writer deliberately accepts only a concrete directory tree of regular
/// files. It does not follow symbolic links or add directory, Finder, or other
/// platform metadata entries to the shared archive.
public enum ScanInterchangeArchiveError: Error, Equatable, Sendable {
    case sourceMissing(String)
    case sourceNotDirectory(String)
    case sourceSymbolicLink(String)
    case unsafeEntryPath(String)
    case unsupportedEntry(String)
    case sourceUnreadable(String)
    case emptyDirectory
    case destinationInsideSourceDirectory
    case destinationAlreadyExists(String)
    case archiveTooLarge
    case outputWriteFailed(String)
}

/// Creates a standards-compatible ZIP archive from a generated interchange
/// directory without compression or hidden metadata.
///
/// Every archive entry uses its path relative to the supplied directory, so a
/// shared 3D Tiles archive contains `tileset.json` and `content/scan.glb` at
/// its root rather than inside an extra parent folder. ZIP's store method and
/// data descriptors keep file contents streaming-friendly on Apple platforms.
public struct ScanInterchangeArchiveWriter {
    private static let streamChunkByteCount = 1_048_576

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    /// Writes a ZIP archive for the regular files contained by `sourceURL`.
    ///
    /// The destination is created atomically and must not already exist. The
    /// returned URL is `destinationURL` for convenient use as a share item.
    @discardableResult
    public func writeDirectory(at sourceURL: URL, to destinationURL: URL) throws -> URL {
        let sourceDirectory = try validatedSourceDirectory(at: sourceURL)
        try requireDestinationOutsideSourceDirectory(destinationURL, sourceDirectory: sourceDirectory)
        let entries = try archiveEntries(in: sourceDirectory)
        guard !entries.isEmpty else {
            throw ScanInterchangeArchiveError.emptyDirectory
        }

        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw ScanInterchangeArchiveError.destinationAlreadyExists(destinationURL.path)
        }
        let parentURL = destinationURL.deletingLastPathComponent()
        do {
            try fileManager.createDirectory(at: parentURL, withIntermediateDirectories: true)
        } catch {
            throw ScanInterchangeArchiveError.outputWriteFailed(parentURL.path)
        }

        let stagingURL = parentURL.appending(
            path: ".\(destinationURL.lastPathComponent).\(UUID().uuidString).partial"
        )
        guard fileManager.createFile(atPath: stagingURL.path, contents: nil) else {
            throw ScanInterchangeArchiveError.outputWriteFailed(stagingURL.path)
        }

        do {
            let handle = try FileHandle(forWritingTo: stagingURL)
            defer { try? handle.close() }
            var output = ZIPOutput(handle: handle)
            var centralEntries: [ZIPCentralDirectoryEntry] = []
            centralEntries.reserveCapacity(entries.count)

            for entry in entries {
                centralEntries.append(try write(entry, to: &output))
            }
            try writeCentralDirectory(centralEntries, to: &output)
            try handle.synchronize()
            try fileManager.moveItem(at: stagingURL, to: destinationURL)
            return destinationURL
        } catch let error as ScanInterchangeArchiveError {
            try? fileManager.removeItem(at: stagingURL)
            throw error
        } catch {
            try? fileManager.removeItem(at: stagingURL)
            throw ScanInterchangeArchiveError.outputWriteFailed(destinationURL.path)
        }
    }

    private func validatedSourceDirectory(at sourceURL: URL) throws -> URL {
        let sourceDirectory = sourceURL.standardizedFileURL
        let values: URLResourceValues
        do {
            values = try sourceDirectory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        } catch {
            throw ScanInterchangeArchiveError.sourceMissing(sourceURL.path)
        }
        guard values.isSymbolicLink != true else {
            throw ScanInterchangeArchiveError.sourceSymbolicLink(sourceURL.path)
        }
        guard values.isDirectory == true else {
            throw ScanInterchangeArchiveError.sourceNotDirectory(sourceURL.path)
        }
        return sourceDirectory
    }

    private func requireDestinationOutsideSourceDirectory(
        _ destinationURL: URL,
        sourceDirectory: URL
    ) throws {
        let resolvedSource = sourceDirectory.resolvingSymlinksInPath().standardizedFileURL
        let resolvedDestinationParent = destinationURL.deletingLastPathComponent()
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let sourcePath = resolvedSource.path.hasSuffix("/")
            ? resolvedSource.path
            : resolvedSource.path + "/"
        if resolvedDestinationParent.path == resolvedSource.path
            || resolvedDestinationParent.path.hasPrefix(sourcePath) {
            throw ScanInterchangeArchiveError.destinationInsideSourceDirectory
        }
    }

    private func archiveEntries(in sourceDirectory: URL) throws -> [ZIPSourceEntry] {
        let keys: [URLResourceKey] = [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
            .fileSizeKey
        ]
        var enumerationFailurePath: String?
        guard let enumerator = fileManager.enumerator(
            at: sourceDirectory,
            includingPropertiesForKeys: keys,
            options: [],
            errorHandler: { url, _ in
                enumerationFailurePath = url.path
                return false
            }
        ) else {
            throw ScanInterchangeArchiveError.sourceUnreadable(sourceDirectory.path)
        }

        let sourcePath = sourceDirectory.path.hasSuffix("/")
            ? sourceDirectory.path
            : sourceDirectory.path + "/"
        var entries: [ZIPSourceEntry] = []
        while let object = enumerator.nextObject() {
            guard let entryURL = object as? URL else {
                throw ScanInterchangeArchiveError.unsupportedEntry(sourceDirectory.path)
            }
            let relativePath = try relativeEntryPath(for: entryURL, sourcePath: sourcePath)
            let values: URLResourceValues
            do {
                values = try entryURL.resourceValues(forKeys: Set(keys))
            } catch {
                throw ScanInterchangeArchiveError.sourceUnreadable(relativePath)
            }
            if values.isSymbolicLink == true {
                throw ScanInterchangeArchiveError.sourceSymbolicLink(relativePath)
            }
            if values.isDirectory == true {
                continue
            }
            guard values.isRegularFile == true else {
                throw ScanInterchangeArchiveError.unsupportedEntry(relativePath)
            }
            guard let fileSize = values.fileSize, fileSize >= 0 else {
                throw ScanInterchangeArchiveError.sourceUnreadable(relativePath)
            }
            guard UInt64(fileSize) <= UInt64(UInt32.max) else {
                throw ScanInterchangeArchiveError.archiveTooLarge
            }
            entries.append(
                ZIPSourceEntry(
                    url: entryURL,
                    relativePath: relativePath,
                    fileSize: UInt64(fileSize)
                )
            )
        }
        if let enumerationFailurePath {
            throw ScanInterchangeArchiveError.sourceUnreadable(enumerationFailurePath)
        }
        return entries.sorted { $0.relativePath < $1.relativePath }
    }

    private func relativeEntryPath(for entryURL: URL, sourcePath: String) throws -> String {
        let path = entryURL.standardizedFileURL.path
        guard path.hasPrefix(sourcePath) else {
            throw ScanInterchangeArchiveError.unsafeEntryPath(path)
        }
        let relativePath = String(path.dropFirst(sourcePath.count))
        guard isSafeRelativePath(relativePath), relativePath.utf8.count <= Int(UInt16.max) else {
            throw ScanInterchangeArchiveError.unsafeEntryPath(relativePath)
        }
        return relativePath
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty,
              !path.hasPrefix("/"),
              !path.contains("\\"),
              !path.utf8.contains(0)
        else {
            return false
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func write(_ entry: ZIPSourceEntry, to output: inout ZIPOutput) throws -> ZIPCentralDirectoryEntry {
        guard output.offset <= UInt64(UInt32.max) else {
            throw ScanInterchangeArchiveError.archiveTooLarge
        }
        let localHeaderOffset = UInt32(output.offset)
        let name = Data(entry.relativePath.utf8)
        try writeLocalFileHeader(name: name, to: &output)

        let input: FileHandle
        do {
            input = try FileHandle(forReadingFrom: entry.url)
        } catch {
            throw ScanInterchangeArchiveError.sourceUnreadable(entry.relativePath)
        }
        defer { try? input.close() }

        var crc32 = ZIPCRC32()
        var byteCount: UInt64 = 0
        do {
            while let chunk = try input.read(upToCount: Self.streamChunkByteCount), !chunk.isEmpty {
                let (updatedCount, overflow) = byteCount.addingReportingOverflow(UInt64(chunk.count))
                guard !overflow, updatedCount <= UInt64(UInt32.max) else {
                    throw ScanInterchangeArchiveError.archiveTooLarge
                }
                crc32.update(chunk)
                try output.write(chunk)
                byteCount = updatedCount
            }
        } catch let error as ScanInterchangeArchiveError {
            throw error
        } catch {
            throw ScanInterchangeArchiveError.sourceUnreadable(entry.relativePath)
        }
        guard byteCount == entry.fileSize else {
            throw ScanInterchangeArchiveError.sourceUnreadable(entry.relativePath)
        }

        let checksum = crc32.checksum
        try writeDataDescriptor(
            checksum: checksum,
            byteCount: UInt32(byteCount),
            to: &output
        )
        return ZIPCentralDirectoryEntry(
            name: name,
            checksum: checksum,
            byteCount: UInt32(byteCount),
            localHeaderOffset: localHeaderOffset
        )
    }

    private func writeLocalFileHeader(name: Data, to output: inout ZIPOutput) throws {
        // Bit 3 announces the trailing data descriptor; bit 11 declares that
        // relative entry names are UTF-8. The stored method retains source
        // bytes exactly and does not require a compression framework.
        try output.writeUInt32(0x0403_4B50)
        try output.writeUInt16(20)
        try output.writeUInt16(0x0808)
        try output.writeUInt16(0)
        try output.writeUInt16(0)
        try output.writeUInt16(0x0021) // 1980-01-01; avoids exporting a timestamp.
        try output.writeUInt32(0)
        try output.writeUInt32(0)
        try output.writeUInt32(0)
        try output.writeUInt16(try uint16Length(of: name))
        try output.writeUInt16(0)
        try output.write(name)
    }

    private func writeDataDescriptor(
        checksum: UInt32,
        byteCount: UInt32,
        to output: inout ZIPOutput
    ) throws {
        try output.writeUInt32(0x0807_4B50)
        try output.writeUInt32(checksum)
        try output.writeUInt32(byteCount)
        try output.writeUInt32(byteCount)
    }

    private func writeCentralDirectory(
        _ entries: [ZIPCentralDirectoryEntry],
        to output: inout ZIPOutput
    ) throws {
        guard entries.count <= Int(UInt16.max), output.offset <= UInt64(UInt32.max) else {
            throw ScanInterchangeArchiveError.archiveTooLarge
        }
        let centralDirectoryOffset = UInt32(output.offset)
        for entry in entries {
            try output.writeUInt32(0x0201_4B50)
            try output.writeUInt16(0x0314)
            try output.writeUInt16(20)
            try output.writeUInt16(0x0808)
            try output.writeUInt16(0)
            try output.writeUInt16(0)
            try output.writeUInt16(0x0021)
            try output.writeUInt32(entry.checksum)
            try output.writeUInt32(entry.byteCount)
            try output.writeUInt32(entry.byteCount)
            try output.writeUInt16(try uint16Length(of: entry.name))
            try output.writeUInt16(0)
            try output.writeUInt16(0)
            try output.writeUInt16(0)
            try output.writeUInt16(0)
            try output.writeUInt32(0)
            try output.writeUInt32(entry.localHeaderOffset)
            try output.write(entry.name)
        }

        let centralDirectoryByteCount = output.offset - UInt64(centralDirectoryOffset)
        guard centralDirectoryByteCount <= UInt64(UInt32.max) else {
            throw ScanInterchangeArchiveError.archiveTooLarge
        }
        try output.writeUInt32(0x0605_4B50)
        try output.writeUInt16(0)
        try output.writeUInt16(0)
        try output.writeUInt16(UInt16(entries.count))
        try output.writeUInt16(UInt16(entries.count))
        try output.writeUInt32(UInt32(centralDirectoryByteCount))
        try output.writeUInt32(centralDirectoryOffset)
        try output.writeUInt16(0)
    }

    private func uint16Length(of data: Data) throws -> UInt16 {
        guard data.count <= Int(UInt16.max) else {
            throw ScanInterchangeArchiveError.archiveTooLarge
        }
        return UInt16(data.count)
    }
}

private struct ZIPSourceEntry {
    var url: URL
    var relativePath: String
    var fileSize: UInt64
}

private struct ZIPCentralDirectoryEntry {
    var name: Data
    var checksum: UInt32
    var byteCount: UInt32
    var localHeaderOffset: UInt32
}

private struct ZIPOutput {
    let handle: FileHandle
    private(set) var offset: UInt64 = 0

    mutating func write(_ data: Data) throws {
        let (updatedOffset, overflow) = offset.addingReportingOverflow(UInt64(data.count))
        guard !overflow else {
            throw ScanInterchangeArchiveError.archiveTooLarge
        }
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw ScanInterchangeArchiveError.outputWriteFailed("ZIP")
        }
        offset = updatedOffset
    }

    mutating func writeUInt16(_ value: UInt16) throws {
        var littleEndian = value.littleEndian
        try withUnsafeBytes(of: &littleEndian) { bytes in
            try write(Data(bytes))
        }
    }

    mutating func writeUInt32(_ value: UInt32) throws {
        var littleEndian = value.littleEndian
        try withUnsafeBytes(of: &littleEndian) { bytes in
            try write(Data(bytes))
        }
    }
}

private struct ZIPCRC32 {
    private static let table: [UInt32] = (0..<256).map { value in
        var checksum = UInt32(value)
        for _ in 0..<8 {
            checksum = checksum & 1 == 1
                ? (checksum >> 1) ^ 0xEDB8_8320
                : checksum >> 1
        }
        return checksum
    }

    private var state: UInt32 = 0xFFFF_FFFF

    mutating func update(_ data: Data) {
        for byte in data {
            let tableIndex = Int((state ^ UInt32(byte)) & 0xFF)
            state = ZIPCRC32.table[tableIndex] ^ (state >> 8)
        }
    }

    var checksum: UInt32 {
        state ^ 0xFFFF_FFFF
    }
}
