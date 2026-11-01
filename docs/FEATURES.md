# Features

StrataScan brings spatial capture and saved-scan review into a native iOS app.
It keeps the capture workflow, local library, 3D workspace, and export tools in
one place.

## Spatial capture

Choose raw LiDAR capture for scene depth and mesh, or RoomPlan for a semantic
room model. The scanner checks device support, camera access, and storage before
starting. During raw capture, tracking and movement guidance help the operator
keep a useful view of the surface. Pause, resume, finish, review, and save are
explicit actions.

## Local library

Saved scans have names, dates, state badges, and storage sizes. Capture is staged
until the user saves it. Packages and metadata remain on the device; opening the
library does not require an account or internet connection.

## 3D workspace

Inspect available processed surfaces, diagnostic raw meshes, point clouds,
captured images, and saved video. Orbit and zoom with standard gestures, reset
the camera, and choose visible layers. The viewer uses the assets actually
present in each scan. Rename changes local metadata; deletion removes the scan
and its managed local files.

## Before and after comparison

Choose two saved scans, define a work area on the before mesh, and select
matching landmarks to save a separate rigid alignment. Review baseline,
comparison, or overlay geometry and preview observed surface correspondences.
Source scans remain unchanged. These tools do not provide a certified survey or
volume calculation.

## Interchange

Export available data as PLY, GLB, local-coordinate Cesium 3D Tiles, or point-cloud
OPF. The app checks package integrity and required source assets before offering
a format. A system share sheet hands the generated file to the user's chosen
recipient. Local-coordinate exports do not infer geographic placement.

## Native interface

SwiftUI navigation, system controls, full-screen capture, English copy, Dynamic
Type, and accessibility labels support iPhone and iPad layouts. Local demo
services make the screens reproducible without camera or LiDAR hardware.

See the [screenshots](screenshots/README.md) and [module overview](ARCHITECTURE.md).
