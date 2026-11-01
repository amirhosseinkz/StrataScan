# Interface screenshots

English screenshots from the running app in iOS Simulator. All sample scans,
metadata, and geometry come from the existing deterministic UI-test services.
No private room, camera image, or real scan package is included.

| Library | Workspace | Scanner |
| --- | --- | --- |
| ![Library](01-library.png) | ![Workspace with synthetic geometry](02-workspace.png) | ![Scanner setup](06-scanner.png) |

| Comparison setup | Settings | Empty library |
| --- | --- | --- |
| ![Comparison](03-comparison.png) | ![Settings](04-settings.png) | ![Empty library](05-empty-library.png) |

Regenerate from the repository root with `make snapshots`. The capture test is
`PortfolioSnapshotTests.testEnglishPortfolioSnapshots`; the script exports its
native screenshot attachments without compositing or repainting the interface.
[Provenance and image checksums](provenance.json) record the toolchain and content
boundary. The images show interface states with sample data.
