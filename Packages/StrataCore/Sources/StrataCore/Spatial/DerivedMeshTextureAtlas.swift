import Foundation

/// One UV coordinate in the derived, display-only texture atlas.
public struct MeshTextureCoordinate: Codable, Equatable, Sendable {
    public var u: Float
    public var v: Float

    public init(u: Float, v: Float) {
        self.u = u
        self.v = v
    }
}

/// A colored raw-mesh triangle selected for a derived display texture.
///
/// `sourceVertexIndices` always contains exactly three anchor-local vertex
/// indices. The representative color is an average of three real camera
/// projections; the tile itself preserves the three observed vertex colours
/// as a barycentric gradient. An unprojected source vertex never participates
/// in this derived preview.
public struct DerivedMeshTextureFace: Equatable, Sendable {
    public let sourceVertexIndices: [Int]
    public let textureCoordinates: [MeshTextureCoordinate]
    public let color: MeshVertexColor

    public init(
        sourceVertexIndices: [Int],
        textureCoordinates: [MeshTextureCoordinate],
        color: MeshVertexColor
    ) {
        self.sourceVertexIndices = sourceVertexIndices
        self.textureCoordinates = textureCoordinates
        self.color = color
    }
}

/// A bounded in-memory RGBA atlas derived from verified mesh vertex colours.
///
/// This is intentionally a presentation artifact: it does not write UVs,
/// pixels, or a transformed mesh into the immutable scan package. Every tile
/// interpolates its three verified vertex colours, providing a more legible
/// surface preview without claiming an occlusion-aware photo texture today.
public struct DerivedMeshTextureAtlas: Equatable, Sendable {
    public let width: Int
    public let height: Int
    public let rgbaBytes: [UInt8]
    public let faces: [DerivedMeshTextureFace]

    public init(
        width: Int,
        height: Int,
        rgbaBytes: [UInt8],
        faces: [DerivedMeshTextureFace]
    ) {
        self.width = width
        self.height = height
        self.rgbaBytes = rgbaBytes
        self.faces = faces
    }

    public func color(atX x: Int, y: Int) -> MeshVertexColor? {
        guard x >= 0, x < width, y >= 0, y < height else {
            return nil
        }
        let offset = (y * width + x) * 4
        guard rgbaBytes.indices.contains(offset + 3), rgbaBytes[offset + 3] > 0 else {
            return nil
        }
        return MeshVertexColor(
            red: rgbaBytes[offset],
            green: rgbaBytes[offset + 1],
            blue: rgbaBytes[offset + 2],
            alpha: rgbaBytes[offset + 3]
        )
    }
}

/// Builds a compact per-face colour-gradient atlas from display-only camera
/// projections. The fixed bounds prevent a large saved scan from allocating a
/// photo atlas while still giving the SceneKit viewer a real UV/textured
/// surface path.
public struct DerivedMeshTextureAtlasBuilder: Sendable {
    public let maximumFaceCount: Int
    public let texelsPerTile: Int

    public init(maximumFaceCount: Int = 1_024, texelsPerTile: Int = 8) {
        self.maximumFaceCount = max(1, maximumFaceCount)
        self.texelsPerTile = max(1, texelsPerTile)
    }

    public func build(
        snapshot: MeshSnapshot,
        vertexColors: [MeshVertexColor?]
    ) -> DerivedMeshTextureAtlas? {
        guard snapshot.vertices.count == vertexColors.count else {
            return nil
        }

        let candidateCount = snapshot.faces.reduce(into: 0) { count, face in
            guard isValid(face: face, vertexCount: snapshot.vertices.count),
                  face.indices.allSatisfy({ vertexColors[$0] != nil })
            else {
                return
            }
            count += 1
        }
        guard candidateCount > 0 else {
            return nil
        }

        let selectedCount = min(maximumFaceCount, candidateCount)
        let selectedOrdinals = evenlyDistributedOrdinals(
            totalCount: candidateCount,
            selectedCount: selectedCount
        )
        let columns = Int(Double(selectedCount).squareRoot().rounded(.up))
        let rows = (selectedCount + columns - 1) / columns
        let width = columns * texelsPerTile
        let height = rows * texelsPerTile
        var rgbaBytes = Array(repeating: UInt8(0), count: width * height * 4)
        var faces: [DerivedMeshTextureFace] = []
        faces.reserveCapacity(selectedCount)

        var candidateOrdinal = 0
        var selectionCursor = 0
        for face in snapshot.faces {
            guard isValid(face: face, vertexCount: snapshot.vertices.count),
                  let colors = colors(for: face, vertexColors: vertexColors)
            else {
                continue
            }
            defer { candidateOrdinal += 1 }
            guard selectionCursor < selectedOrdinals.count,
                  candidateOrdinal == selectedOrdinals[selectionCursor]
            else {
                continue
            }

            let tileIndex = faces.count
            let column = tileIndex % columns
            let row = tileIndex / columns
            fillTriangleTile(
                in: &rgbaBytes,
                textureWidth: width,
                column: column,
                row: row,
                colors: colors
            )
            faces.append(
                DerivedMeshTextureFace(
                    sourceVertexIndices: face.indices,
                    textureCoordinates: triangleTextureCoordinates(
                        column: column,
                        row: row,
                        textureWidth: width,
                        textureHeight: height
                    ),
                    color: averageColor(colors)
                )
            )
            selectionCursor += 1
        }

        guard faces.count == selectedCount else {
            return nil
        }
        return DerivedMeshTextureAtlas(
            width: width,
            height: height,
            rgbaBytes: rgbaBytes,
            faces: faces
        )
    }

    private func evenlyDistributedOrdinals(totalCount: Int, selectedCount: Int) -> [Int] {
        guard selectedCount > 1 else {
            return [0]
        }
        return (0..<selectedCount).map { index in
            index * (totalCount - 1) / (selectedCount - 1)
        }
    }

    private func isValid(face: MeshFace, vertexCount: Int) -> Bool {
        face.indices.allSatisfy { $0 >= 0 && $0 < vertexCount }
    }

    private func colors(
        for face: MeshFace,
        vertexColors: [MeshVertexColor?]
    ) -> [MeshVertexColor]? {
        let colors = face.indices.compactMap { vertexColors[$0] }
        guard colors.count == 3 else {
            return nil
        }
        return colors
    }

    private func averageColor(_ colors: [MeshVertexColor]) -> MeshVertexColor {
        return MeshVertexColor(
            red: componentAverage(colors.map(\.red)),
            green: componentAverage(colors.map(\.green)),
            blue: componentAverage(colors.map(\.blue)),
            alpha: componentAverage(colors.map(\.alpha))
        )
    }

    private func componentAverage(_ components: [UInt8]) -> UInt8 {
        UInt8(components.reduce(0) { $0 + Int($1) } / components.count)
    }

    private func triangleTextureCoordinates(
        column: Int,
        row: Int,
        textureWidth: Int,
        textureHeight: Int
    ) -> [MeshTextureCoordinate] {
        let originX = column * texelsPerTile
        let originY = row * texelsPerTile
        let endOffset = Float(max(0, texelsPerTile - 1)) + 0.5
        return [
            MeshTextureCoordinate(
                u: (Float(originX) + 0.5) / Float(textureWidth),
                v: (Float(originY) + 0.5) / Float(textureHeight)
            ),
            MeshTextureCoordinate(
                u: (Float(originX) + endOffset) / Float(textureWidth),
                v: (Float(originY) + 0.5) / Float(textureHeight)
            ),
            MeshTextureCoordinate(
                u: (Float(originX) + 0.5) / Float(textureWidth),
                v: (Float(originY) + endOffset) / Float(textureHeight)
            )
        ]
    }

    private func fillTriangleTile(
        in rgbaBytes: inout [UInt8],
        textureWidth: Int,
        column: Int,
        row: Int,
        colors: [MeshVertexColor]
    ) {
        guard colors.count == 3 else {
            return
        }
        let originX = column * texelsPerTile
        let originY = row * texelsPerTile
        guard texelsPerTile > 1 else {
            write(
                averageColor(colors),
                into: &rgbaBytes,
                atX: originX,
                y: originY,
                textureWidth: textureWidth
            )
            return
        }

        let denominator = Float(texelsPerTile - 1)
        for localY in 0..<texelsPerTile {
            for localX in 0..<texelsPerTile {
                let secondWeight = Float(localX) / denominator
                let thirdWeight = Float(localY) / denominator
                let firstWeight = 1 - secondWeight - thirdWeight
                guard firstWeight >= 0 else {
                    continue
                }
                let color = interpolatedColor(
                    first: colors[0],
                    second: colors[1],
                    third: colors[2],
                    firstWeight: firstWeight,
                    secondWeight: secondWeight,
                    thirdWeight: thirdWeight
                )
                let x = originX + localX
                let y = originY + localY
                write(
                    color,
                    into: &rgbaBytes,
                    atX: x,
                    y: y,
                    textureWidth: textureWidth
                )
            }
        }
    }

    private func interpolatedColor(
        first: MeshVertexColor,
        second: MeshVertexColor,
        third: MeshVertexColor,
        firstWeight: Float,
        secondWeight: Float,
        thirdWeight: Float
    ) -> MeshVertexColor {
        MeshVertexColor(
            red: blended(first.red, second.red, third.red, firstWeight, secondWeight, thirdWeight),
            green: blended(first.green, second.green, third.green, firstWeight, secondWeight, thirdWeight),
            blue: blended(first.blue, second.blue, third.blue, firstWeight, secondWeight, thirdWeight),
            alpha: blended(first.alpha, second.alpha, third.alpha, firstWeight, secondWeight, thirdWeight)
        )
    }

    private func blended(
        _ first: UInt8,
        _ second: UInt8,
        _ third: UInt8,
        _ firstWeight: Float,
        _ secondWeight: Float,
        _ thirdWeight: Float
    ) -> UInt8 {
        let value = Float(first) * firstWeight
            + Float(second) * secondWeight
            + Float(third) * thirdWeight
        return UInt8(clamping: Int(value.rounded()))
    }

    private func write(
        _ color: MeshVertexColor,
        into rgbaBytes: inout [UInt8],
        atX x: Int,
        y: Int,
        textureWidth: Int
    ) {
        let offset = (y * textureWidth + x) * 4
        rgbaBytes[offset] = color.red
        rgbaBytes[offset + 1] = color.green
        rgbaBytes[offset + 2] = color.blue
        rgbaBytes[offset + 3] = color.alpha
    }
}
