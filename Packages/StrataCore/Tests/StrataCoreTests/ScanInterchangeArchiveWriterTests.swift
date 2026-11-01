import Foundation
import Testing
@testable import StrataCore

@Suite("Scan interchange archive writer", .serialized)
struct ScanInterchangeArchiveWriterTests {
    @Test("A directory becomes a portable stored ZIP with relative file entries and exact bytes")
    func writesPortableRelativeZIP() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }

        let writtenURL = try ScanInterchangeArchiveWriter().writeDirectory(
            at: fixture.sourceDirectory,
            to: fixture.archiveURL
        )

        #expect(writtenURL == fixture.archiveURL)
        let archive = try ZIPFixture(url: fixture.archiveURL)
        #expect(archive.entryNames == [
            "content/scan.glb",
            "nested/manifest.txt",
            "tileset.json"
        ])
        #expect(archive.entries.map(\.contents) == [
            fixture.contents["content/scan.glb"],
            fixture.contents["nested/manifest.txt"],
            fixture.contents["tileset.json"]
        ])
        #expect(archive.entries.allSatisfy { $0.flags == 0x0808 })
        #expect(archive.entries.allSatisfy { $0.compressionMethod == 0 })
        #expect(archive.entries.allSatisfy { $0.localHeaderTime == 0 && $0.localHeaderDate == 0x0021 })
        #expect(archive.entries.allSatisfy { $0.usesDataDescriptor })
        #expect(archive.entries.allSatisfy { $0.crc32 == crc32($0.contents) })
        #expect(archive.entries.allSatisfy { !$0.name.hasPrefix("three-d-tiles/") && !$0.name.hasSuffix("/") })
        #expect(archive.centralDirectoryEntryCount == 3)
        #expect(archive.endOfCentralDirectoryOffset + 22 == archive.data.count)
    }

    @Test("A symbolic-link entry is rejected instead of being followed into a share archive")
    func rejectsSymbolicLinkEntries() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let outsideFile = fixture.rootDirectory.appending(path: "outside.bin")
        try Data([0xDD]).write(to: outsideFile)
        let linkURL = fixture.sourceDirectory.appending(path: "content/outside-link.bin")
        try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: outsideFile)

        #expect(throws: ScanInterchangeArchiveError.sourceSymbolicLink("content/outside-link.bin")) {
            try ScanInterchangeArchiveWriter().writeDirectory(
                at: fixture.sourceDirectory,
                to: fixture.archiveURL
            )
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.archiveURL.path))
    }

    @Test("The archive destination cannot be written inside its source directory")
    func rejectsArchiveInsideSourceDirectory() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.rootDirectory) }
        let unsafeArchiveURL = fixture.sourceDirectory.appending(path: "shared.zip")

        #expect(throws: ScanInterchangeArchiveError.destinationInsideSourceDirectory) {
            try ScanInterchangeArchiveWriter().writeDirectory(
                at: fixture.sourceDirectory,
                to: unsafeArchiveURL
            )
        }
        #expect(!FileManager.default.fileExists(atPath: unsafeArchiveURL.path))
    }

    private func makeFixture() throws -> ArchiveFixture {
        let rootDirectory = FileManager.default.temporaryDirectory.appending(
            path: "StrataScanInterchangeArchive-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        let sourceDirectory = rootDirectory.appending(path: "three-d-tiles", directoryHint: .isDirectory)
        let archiveURL = rootDirectory.appending(path: "shared.zip")
        try FileManager.default.createDirectory(
            at: sourceDirectory.appending(path: "content", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: sourceDirectory.appending(path: "nested", directoryHint: .isDirectory),
            withIntermediateDirectories: true
        )
        let contents: [String: Data] = [
            "tileset.json": Data("{\"asset\":{\"version\":\"1.1\"}}".utf8),
            "content/scan.glb": Data([0x67, 0x6C, 0x54, 0x46, 0x02, 0x00, 0x00, 0x00]),
            "nested/manifest.txt": Data("local coordinates only".utf8)
        ]
        for (path, data) in contents {
            try data.write(to: sourceDirectory.appending(path: path))
        }
        return ArchiveFixture(
            rootDirectory: rootDirectory,
            sourceDirectory: sourceDirectory,
            archiveURL: archiveURL,
            contents: contents
        )
    }
}

private struct ArchiveFixture {
    var rootDirectory: URL
    var sourceDirectory: URL
    var archiveURL: URL
    var contents: [String: Data]
}

private struct ZIPFixture {
    struct Entry {
        var name: String
        var contents: Data
        var flags: UInt16
        var compressionMethod: UInt16
        var localHeaderTime: UInt16
        var localHeaderDate: UInt16
        var crc32: UInt32
        var usesDataDescriptor: Bool
    }

    var data: Data
    var entries: [Entry]
    var centralDirectoryEntryCount: Int
    var endOfCentralDirectoryOffset: Int

    var entryNames: [String] {
        entries.map(\.name)
    }

    init(url: URL) throws {
        data = try Data(contentsOf: url)
        entries = []
        centralDirectoryEntryCount = 0
        endOfCentralDirectoryOffset = 0
        guard data.count >= 22 else { throw ZIPFixtureError.malformed }
        endOfCentralDirectoryOffset = data.count - 22
        guard uint32(at: endOfCentralDirectoryOffset) == 0x0605_4B50,
              uint16(at: endOfCentralDirectoryOffset + 4) == 0,
              uint16(at: endOfCentralDirectoryOffset + 6) == 0,
              uint16(at: endOfCentralDirectoryOffset + 8) == uint16(at: endOfCentralDirectoryOffset + 10),
              uint16(at: endOfCentralDirectoryOffset + 20) == 0
        else {
            throw ZIPFixtureError.malformed
        }
        centralDirectoryEntryCount = Int(uint16(at: endOfCentralDirectoryOffset + 10))
        let centralDirectoryByteCount = Int(uint32(at: endOfCentralDirectoryOffset + 12))
        let centralDirectoryOffset = Int(uint32(at: endOfCentralDirectoryOffset + 16))
        guard centralDirectoryOffset >= 0,
              centralDirectoryByteCount >= 0,
              centralDirectoryOffset + centralDirectoryByteCount == endOfCentralDirectoryOffset
        else {
            throw ZIPFixtureError.malformed
        }

        var centralOffset = centralDirectoryOffset
        var parsedEntries: [Entry] = []
        parsedEntries.reserveCapacity(centralDirectoryEntryCount)
        for _ in 0..<centralDirectoryEntryCount {
            guard uint32(at: centralOffset) == 0x0201_4B50 else {
                throw ZIPFixtureError.malformed
            }
            let flags = uint16(at: centralOffset + 8)
            let compressionMethod = uint16(at: centralOffset + 10)
            let checksum = uint32(at: centralOffset + 16)
            let compressedSize = Int(uint32(at: centralOffset + 20))
            let uncompressedSize = Int(uint32(at: centralOffset + 24))
            let nameByteCount = Int(uint16(at: centralOffset + 28))
            let extraByteCount = Int(uint16(at: centralOffset + 30))
            let commentByteCount = Int(uint16(at: centralOffset + 32))
            let localHeaderOffset = Int(uint32(at: centralOffset + 42))
            let entryEnd = centralOffset + 46 + nameByteCount + extraByteCount + commentByteCount
            guard compressedSize == uncompressedSize,
                  entryEnd <= data.count,
                  let name = String(data: data[(centralOffset + 46)..<(centralOffset + 46 + nameByteCount)], encoding: .utf8)
            else {
                throw ZIPFixtureError.malformed
            }

            let localEntry = try parseLocalEntry(
                at: localHeaderOffset,
                centralName: name,
                centralFlags: flags,
                centralCompressionMethod: compressionMethod,
                centralChecksum: checksum,
                byteCount: uncompressedSize
            )
            parsedEntries.append(localEntry)
            centralOffset = entryEnd
        }
        guard centralOffset == endOfCentralDirectoryOffset else {
            throw ZIPFixtureError.malformed
        }
        entries = parsedEntries
    }

    private func parseLocalEntry(
        at offset: Int,
        centralName: String,
        centralFlags: UInt16,
        centralCompressionMethod: UInt16,
        centralChecksum: UInt32,
        byteCount: Int
    ) throws -> Entry {
        guard uint32(at: offset) == 0x0403_4B50 else {
            throw ZIPFixtureError.malformed
        }
        let flags = uint16(at: offset + 6)
        let compressionMethod = uint16(at: offset + 8)
        let time = uint16(at: offset + 10)
        let date = uint16(at: offset + 12)
        let localChecksum = uint32(at: offset + 14)
        let localCompressedSize = uint32(at: offset + 18)
        let localUncompressedSize = uint32(at: offset + 22)
        let nameByteCount = Int(uint16(at: offset + 26))
        let extraByteCount = Int(uint16(at: offset + 28))
        let nameStart = offset + 30
        let contentsStart = nameStart + nameByteCount + extraByteCount
        let contentsEnd = contentsStart + byteCount
        let descriptorEnd = contentsEnd + 16
        guard flags == centralFlags,
              compressionMethod == centralCompressionMethod,
              localChecksum == 0,
              localCompressedSize == 0,
              localUncompressedSize == 0,
              contentsEnd <= data.count,
              descriptorEnd <= data.count,
              String(data: data[nameStart..<(nameStart + nameByteCount)], encoding: .utf8) == centralName,
              uint32(at: contentsEnd) == 0x0807_4B50,
              uint32(at: contentsEnd + 4) == centralChecksum,
              uint32(at: contentsEnd + 8) == UInt32(byteCount),
              uint32(at: contentsEnd + 12) == UInt32(byteCount)
        else {
            throw ZIPFixtureError.malformed
        }
        return Entry(
            name: centralName,
            contents: Data(data[contentsStart..<contentsEnd]),
            flags: flags,
            compressionMethod: compressionMethod,
            localHeaderTime: time,
            localHeaderDate: date,
            crc32: centralChecksum,
            usesDataDescriptor: flags & 0x0008 != 0
        )
    }

    private func uint16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
    }

    private func uint32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(data[offset])
            | (UInt32(data[offset + 1]) << 8)
            | (UInt32(data[offset + 2]) << 16)
            | (UInt32(data[offset + 3]) << 24)
    }
}

private enum ZIPFixtureError: Error {
    case malformed
}

private func crc32(_ data: Data) -> UInt32 {
    var state: UInt32 = 0xFFFF_FFFF
    for byte in data {
        state ^= UInt32(byte)
        for _ in 0..<8 {
            state = state & 1 == 1
                ? (state >> 1) ^ 0xEDB8_8320
                : state >> 1
        }
    }
    return state ^ 0xFFFF_FFFF
}
