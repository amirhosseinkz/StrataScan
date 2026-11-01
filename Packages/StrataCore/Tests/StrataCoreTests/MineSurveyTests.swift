import Foundation
import Testing
@testable import StrataCore

@Suite("Mine survey control foundation", .serialized)
struct MineSurveyTests {
    @Test("Surveyed controls estimate a rigid mineFromARWorld transform")
    func estimatesRigidRegistration() throws {
        let projectID = UUID()
        let scanID = UUID()
        let controls = [
            MineControlPoint(projectID: projectID, code: "CP-01", minePosition: Point3D(x: 10, y: 20, z: 30)),
            MineControlPoint(projectID: projectID, code: "CP-02", minePosition: Point3D(x: 11, y: 20, z: 30)),
            MineControlPoint(projectID: projectID, code: "CP-03", minePosition: Point3D(x: 10, y: 21, z: 30))
        ]
        let observations = [
            MineControlObservation(controlPointID: controls[0].id, arWorldPosition: Point3D(x: 0, y: 0, z: 0)),
            MineControlObservation(controlPointID: controls[1].id, arWorldPosition: Point3D(x: 1, y: 0, z: 0)),
            MineControlObservation(controlPointID: controls[2].id, arWorldPosition: Point3D(x: 0, y: 1, z: 0))
        ]

        let registration = try MineSurveyRegistrationEngine().estimate(
            projectID: projectID,
            scanID: scanID,
            observations: observations,
            controlPoints: controls,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(registration.method == .surveyedControl)
        #expect(registration.controlPointIDs == observations.map(\.controlPointID))
        #expect(registration.rmsResidualMeters < 0.000_1)
        #expect(registration.mineFromARWorld.applying(to: Point3D(x: 0, y: 0, z: 0)).isApproximatelyEqual(to: Point3D(x: 10, y: 20, z: 30)))
    }

    @Test("Collinear or duplicate observations are rejected")
    func rejectsDegenerateControlEvidence() throws {
        let projectID = UUID()
        let scanID = UUID()
        let controls = [
            MineControlPoint(projectID: projectID, code: "CP-01", minePosition: Point3D(x: 0, y: 0, z: 0)),
            MineControlPoint(projectID: projectID, code: "CP-02", minePosition: Point3D(x: 1, y: 0, z: 0)),
            MineControlPoint(projectID: projectID, code: "CP-03", minePosition: Point3D(x: 2, y: 0, z: 0))
        ]
        let collinear = [
            MineControlObservation(controlPointID: controls[0].id, arWorldPosition: Point3D(x: 0, y: 0, z: 0)),
            MineControlObservation(controlPointID: controls[1].id, arWorldPosition: Point3D(x: 1, y: 0, z: 0)),
            MineControlObservation(controlPointID: controls[2].id, arWorldPosition: Point3D(x: 2, y: 0, z: 0))
        ]

        #expect(throws: MineSurveyError.degenerateControlGeometry) {
            try MineSurveyRegistrationEngine().estimate(
                projectID: projectID,
                scanID: scanID,
                observations: collinear,
                controlPoints: controls
            )
        }

        let duplicate = [
            MineControlObservation(controlPointID: controls[0].id, arWorldPosition: Point3D(x: 0, y: 0, z: 0)),
            MineControlObservation(controlPointID: controls[0].id, arWorldPosition: Point3D(x: 1, y: 0, z: 0)),
            MineControlObservation(controlPointID: controls[1].id, arWorldPosition: Point3D(x: 0, y: 1, z: 0))
        ]
        #expect(throws: MineSurveyError.duplicateControlPointObservation(controls[0].id)) {
            try MineSurveyRegistrationEngine().estimate(
                projectID: projectID,
                scanID: scanID,
                observations: duplicate,
                controlPoints: controls
            )
        }
    }

    @Test("Mine project controls and scan registration persist without changing scan assets")
    func persistsMineSurveyMetadata() async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try SQLiteMetadataStore(databaseURL: root.appending(path: "metadata.sqlite"))
        let project = MineProject(
            name: "North Decline",
            coordinateReference: MineCoordinateReference(
                name: "North Decline Mine Grid",
                horizontalDatum: "Mine survey control",
                verticalDatum: "Level datum"
            ),
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            updatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        try await store.save(mineProject: project)
        let controlTimestamp = Date(timeIntervalSince1970: 1_700_000_001)

        let scan = ScanMetadata(
            id: UUID(),
            displayName: "Station 12",
            status: .completed,
            createdAt: project.createdAt,
            updatedAt: project.updatedAt
        )
        try await store.save(scan: scan, assets: [])
        let controls = [
            MineControlPoint(projectID: project.id, code: "CP-01", minePosition: Point3D(x: 10, y: 20, z: 30), createdAt: controlTimestamp, updatedAt: controlTimestamp),
            MineControlPoint(projectID: project.id, code: "CP-02", minePosition: Point3D(x: 11, y: 20, z: 30), createdAt: controlTimestamp, updatedAt: controlTimestamp),
            MineControlPoint(projectID: project.id, code: "CP-03", minePosition: Point3D(x: 10, y: 21, z: 30), createdAt: controlTimestamp, updatedAt: controlTimestamp)
        ]
        for control in controls {
            try await store.save(mineControlPoint: control)
        }
        let registration = try MineSurveyRegistrationEngine().estimate(
            projectID: project.id,
            scanID: scan.id,
            observations: [
                MineControlObservation(controlPointID: controls[0].id, arWorldPosition: Point3D(x: 0, y: 0, z: 0)),
                MineControlObservation(controlPointID: controls[1].id, arWorldPosition: Point3D(x: 1, y: 0, z: 0)),
                MineControlObservation(controlPointID: controls[2].id, arWorldPosition: Point3D(x: 0, y: 1, z: 0))
            ],
            controlPoints: controls,
            createdAt: project.createdAt
        )
        try await store.save(mineScanRegistration: registration)

        #expect(try await store.mineProject(id: project.id) == project)
        #expect(try await store.mineControlPoints(projectID: project.id) == controls)
        #expect(try await store.mineScanRegistration(projectID: project.id, scanID: scan.id) == registration)
        #expect(try await store.scan(id: scan.id) == scan)

        let secondScan = ScanMetadata(
            id: UUID(), displayName: "Station 13", status: .completed,
            createdAt: project.createdAt, updatedAt: project.updatedAt
        )
        try await store.save(scan: secondScan, assets: [])
        let secondRegistration = try MineSurveyRegistrationEngine().estimate(
            projectID: project.id,
            scanID: secondScan.id,
            observations: [
                MineControlObservation(controlPointID: controls[0].id, arWorldPosition: Point3D(x: 2, y: 0, z: 0)),
                MineControlObservation(controlPointID: controls[1].id, arWorldPosition: Point3D(x: 3, y: 0, z: 0)),
                MineControlObservation(controlPointID: controls[2].id, arWorldPosition: Point3D(x: 2, y: 1, z: 0))
            ],
            controlPoints: controls,
            createdAt: project.createdAt
        )
        try await store.save(mineScanRegistration: secondRegistration)
        let firstStation = MineScanStation(
            projectID: project.id, scanID: scan.id, registrationID: registration.id,
            code: "ST-12", createdAt: controlTimestamp, updatedAt: controlTimestamp
        )
        let secondStation = MineScanStation(
            projectID: project.id, scanID: secondScan.id, registrationID: secondRegistration.id,
            code: "ST-13", sessionContext: .relocalized(fromStationID: firstStation.id),
            createdAt: controlTimestamp, updatedAt: controlTimestamp
        )
        try await store.save(mineStation: firstStation)
        try await store.save(mineStation: secondStation)
        let traverse = MineTraverseLink(
            projectID: project.id, fromStationID: firstStation.id, toStationID: secondStation.id,
            checkpointControlPointIDs: controls.map(\.id),
            createdAt: controlTimestamp, updatedAt: controlTimestamp
        )
        try await store.save(mineTraverseLink: traverse)

        #expect(try await store.mineStations(projectID: project.id) == [firstStation, secondStation])

        let unrelatedCheckpointIDs = [UUID(), UUID(), UUID()]
        let unsupportedTraverse = MineTraverseLink(
            projectID: project.id, fromStationID: firstStation.id, toStationID: secondStation.id,
            checkpointControlPointIDs: unrelatedCheckpointIDs,
            createdAt: controlTimestamp, updatedAt: controlTimestamp
        )
        await #expect(throws: MineTraverseError.checkpointNotSharedByStations(unrelatedCheckpointIDs[0])) {
            try await store.save(mineTraverseLink: unsupportedTraverse)
        }

        let baseline = SurveyEpoch(projectID: project.id, name: "Before", kind: .baseline, stationIDs: [firstStation.id], capturedAt: controlTimestamp)
        let comparison = SurveyEpoch(projectID: project.id, name: "After", kind: .comparison, stationIDs: [secondStation.id], capturedAt: controlTimestamp)
        let boundary = SurveyChangeBoundary(projectID: project.id, name: "Wall", minimum: Point3D(x: 9, y: 19, z: 29), maximum: Point3D(x: 12, y: 22, z: 32), createdAt: controlTimestamp)
        try await store.save(surveyEpoch: baseline)
        try await store.save(surveyEpoch: comparison)
        try await store.save(surveyChangeBoundary: boundary)
        try await store.save(surveyChangeComparison: SurveyChangeComparison(projectID: project.id, baselineEpochID: baseline.id, comparisonEpochID: comparison.id, boundaryID: boundary.id, createdAt: controlTimestamp))
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(
            path: "MineSurveyTests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
