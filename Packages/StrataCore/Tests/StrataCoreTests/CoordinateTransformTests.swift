import Testing
@testable import StrataCore

@Suite("Coordinate transforms")
struct CoordinateTransformTests {
    @Test("Translation maps a local point into parent coordinates")
    func appliesTranslation() throws {
        let transform = Transform4x4.translation(x: 2, y: -1, z: 4)
        let point = transform.applying(to: Point3D(x: 1, y: 2, z: 3))

        #expect(point.isApproximatelyEqual(to: Point3D(x: 3, y: 1, z: 7)))
    }

    @Test("An inverse round trips a point")
    func inverseRoundTrips() throws {
        let transform = Transform4x4.translation(x: 4, y: -3, z: 2)
            .composed(with: .rotation(radians: .pi / 2, axis: .z))
        let original = Point3D(x: 1.5, y: -2, z: 0.25)

        let recovered = try transform.inverted().applying(to: transform.applying(to: original))
        #expect(recovered.isApproximatelyEqual(to: original, tolerance: 0.0001))
    }

    @Test("Composition observes column-vector application order")
    func compositionUsesDocumentedOrder() {
        let translate = Transform4x4.translation(x: 3, y: 0, z: 0)
        let rotate = Transform4x4.rotation(radians: .pi / 2, axis: .z)
        let combined = translate.composed(with: rotate)

        let point = combined.applying(to: Point3D(x: 1, y: 0, z: 0))
        #expect(point.isApproximatelyEqual(to: Point3D(x: 3, y: 1, z: 0)))
    }
}
