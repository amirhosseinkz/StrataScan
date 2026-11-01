# Contributing

Generate the Xcode project with `make project`; edit `project.yml` instead of
editing the generated project. Read the [feature guide](docs/FEATURES.md) and
[module overview](docs/ARCHITECTURE.md) before changing behavior.

Keep SwiftUI views focused on state and commands. Inject feature dependencies,
preserve source scan packages, and keep alignment as a separate transform.

Run `make test-core`, `make build`, and `make audit` before handoff. Run
`make test-ios` for interface, navigation, accessibility, or composition changes.
Use `make snapshots` to refresh English screenshots from local sample data.

Never commit signing credentials, private scans, build products, or result
bundles. Real sensor behavior requires compatible physical hardware.
