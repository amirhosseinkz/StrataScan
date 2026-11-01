import CryptoKit
import Foundation

/// Owns the only filesystem layout for large scan assets. All paths are relative
/// to this root, so presentation and domain code never carry arbitrary paths.
public actor FileAssetStore {
    private let fileManager: FileManager
    public let rootURL: URL
    private let stagingURL: URL
    private let packagesURL: URL

    public init(rootURL: URL, fileManager: FileManager = .default) throws {
        self.rootURL = rootURL
        self.fileManager = fileManager
        stagingURL = rootURL.appending(path: "staging", directoryHint: .isDirectory)
        packagesURL = rootURL.appending(path: "packages", directoryHint: .isDirectory)

        do {
            try fileManager.createDirectory(at: stagingURL, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: packagesURL, withIntermediateDirectories: true)
        } catch {
            throw AssetStoreError.ioFailure(error.localizedDescription)
        }
    }

    @discardableResult
    public func finalize(manifest: ScanPackageManifest, assets: [AssetInput]) throws -> ScanPackageManifest {
        let destinationURL = packageURLUnchecked(for: manifest.localScanID)
        guard !fileManager.fileExists(atPath: destinationURL.path) else {
            throw AssetStoreError.packageAlreadyExists(manifest.localScanID)
        }

        let sortedAssets = assets.sorted { $0.relativePath < $1.relativePath }
        var paths = Set<String>()
        for asset in sortedAssets {
            guard isSafe(relativePath: asset.relativePath) else {
                throw AssetStoreError.unsafeRelativePath(asset.relativePath)
            }
            guard paths.insert(asset.relativePath).inserted else {
                throw AssetStoreError.duplicateRelativePath(asset.relativePath)
            }
        }

        let stageURL = stagingURL.appending(path: "\(manifest.localScanID.uuidString).\(UUID().uuidString).partial", directoryHint: .isDirectory)
        do {
            try fileManager.createDirectory(at: stageURL, withIntermediateDirectories: true)
        } catch {
            throw AssetStoreError.ioFailure(error.localizedDescription)
        }
        defer {
            if fileManager.fileExists(atPath: stageURL.path) {
                try? fileManager.removeItem(at: stageURL)
            }
        }

        do {
            var references: [ScanAssetReference] = []
            for input in sortedAssets {
                let destination = stageURL.appending(path: input.relativePath)
                try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch input.source {
                case let .data(data):
                    try data.write(to: destination, options: .atomic)
                case let .file(sourceURL):
                    guard fileManager.fileExists(atPath: sourceURL.path) else {
                        throw AssetStoreError.invalidAssetSource(sourceURL)
                    }
                    try fileManager.copyItem(at: sourceURL, to: destination)
                }

                references.append(
                    ScanAssetReference(
                        kind: input.kind,
                        relativePath: input.relativePath,
                        byteCount: try fileByteCount(at: destination),
                        sha256: try sha256(for: destination),
                        spatialReference: input.spatialReference,
                        createdAt: manifest.updatedAt
                    )
                )
            }

            var finalizedManifest = manifest
            finalizedManifest.assets = references
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            let manifestData = try encoder.encode(finalizedManifest)
            try manifestData.write(to: stageURL.appending(path: "manifest.json"), options: .atomic)
            try fileManager.moveItem(at: stageURL, to: destinationURL)
            return finalizedManifest
        } catch let error as AssetStoreError {
            throw error
        } catch {
            throw AssetStoreError.ioFailure(error.localizedDescription)
        }
    }

    public func packageURL(for id: UUID) throws -> URL {
        let url = packageURLUnchecked(for: id)
        guard fileManager.fileExists(atPath: url.path) else {
            throw AssetStoreError.packageNotFound(id)
        }
        return url
    }

    public func packageExists(id: UUID) -> Bool {
        fileManager.fileExists(atPath: packageURLUnchecked(for: id).path)
    }

    public func packageByteCount(id: UUID) throws -> Int64 {
        try byteCountRecursively(at: packageURL(for: id))
    }

    public func loadManifest(id: UUID) throws -> ScanPackageManifest {
        let packageURL = try packageURL(for: id)
        let manifestURL = packageURL.appending(path: "manifest.json")
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let manifest = try decoder.decode(ScanPackageManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.localScanID == id else {
                throw AssetStoreError.manifestScanIDMismatch
            }
            return manifest
        } catch let error as AssetStoreError {
            throw error
        } catch {
            throw AssetStoreError.ioFailure(error.localizedDescription)
        }
    }

    public func validatePackage(id: UUID) throws -> PackageIntegrityReport {
        let packageURL = try packageURL(for: id)
        let manifestURL = packageURL.appending(path: "manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return PackageIntegrityReport(scanID: id, failures: [.manifestMissing])
        }

        let manifest: ScanPackageManifest
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            manifest = try decoder.decode(ScanPackageManifest.self, from: Data(contentsOf: manifestURL))
        } catch {
            return PackageIntegrityReport(scanID: id, failures: [.manifestUnreadable])
        }

        var failures: [PackageIntegrityFailure] = []
        if manifest.localScanID != id {
            failures.append(.manifestIDMismatch)
        }

        var seenPaths = Set<String>()
        for asset in manifest.assets {
            guard isSafe(relativePath: asset.relativePath) else {
                failures.append(.unsafePath(path: asset.relativePath))
                continue
            }
            guard seenPaths.insert(asset.relativePath).inserted else {
                failures.append(.duplicatePath(path: asset.relativePath))
                continue
            }

            let assetURL = packageURL.appending(path: asset.relativePath)
            guard fileManager.fileExists(atPath: assetURL.path) else {
                failures.append(.assetMissing(path: asset.relativePath))
                continue
            }
            if try fileByteCount(at: assetURL) != asset.byteCount {
                failures.append(.byteCountMismatch(path: asset.relativePath))
            }
            if try sha256(for: assetURL) != asset.sha256 {
                failures.append(.checksumMismatch(path: asset.relativePath))
            }
        }
        return PackageIntegrityReport(scanID: id, failures: failures)
    }

    public func removePackage(id: UUID) throws {
        let packageURL = try packageURL(for: id)
        do {
            try fileManager.removeItem(at: packageURL)
        } catch {
            throw AssetStoreError.ioFailure(error.localizedDescription)
        }
    }

    /// Removes abandoned staging directories and reports finalized packages that
    /// do not have a manifest, which a repository can reconcile against SQLite.
    public func recoverInterruptedWork() throws -> [UUID] {
        do {
            let stagingContents = try fileManager.contentsOfDirectory(at: stagingURL, includingPropertiesForKeys: nil)
            for url in stagingContents {
                try fileManager.removeItem(at: url)
            }

            let packageContents = try fileManager.contentsOfDirectory(at: packagesURL, includingPropertiesForKeys: nil)
            return packageContents.compactMap { url in
                guard UUID(uuidString: url.lastPathComponent) != nil else { return nil }
                return fileManager.fileExists(atPath: url.appending(path: "manifest.json").path) ? nil : UUID(uuidString: url.lastPathComponent)
            }
        } catch {
            throw AssetStoreError.ioFailure(error.localizedDescription)
        }
    }

    private func packageURLUnchecked(for id: UUID) -> URL {
        packagesURL.appending(path: id.uuidString, directoryHint: .isDirectory)
    }

    private func isSafe(relativePath: String) -> Bool {
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.contains("\\") else {
            return false
        }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        return !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    private func fileByteCount(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func byteCountRecursively(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else { return try fileByteCount(at: url) }
        let children = try fileManager.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey])
        return try children.reduce(Int64.zero) { partial, child in
            partial + (try byteCountRecursively(at: child))
        }
    }

    private func sha256(for url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
