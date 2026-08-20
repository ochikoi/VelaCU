# Release checklist

VelaCU v0.4.1 release preparation:

- [x] Remove developer-specific absolute paths.
- [x] Remove runtime screenshots, sockets, logs, caches, and local archives from the source tree.
- [x] Keep the public MIT license and third-party notices current.
- [x] Replace the Cua click runtime with standalone VelaClick v0.3.0 SkyLight.
- [x] Keep the installer/CLI and source/release packaging workflow.
- [x] Add the eighth MCP tool, `velacu_scroll`, with post-scroll capture.
- [x] Keep the System Settings RemoteView compatibility path.
- [x] Include the verified pointer flicker, minimize, idle hover, and contrast fixes.
- [x] Validate the source install path without Rust/cargo.
- [x] Run build and compatible Python regression/contract tests.
- [ ] Test/build an Intel/x86_64 package before claiming Intel support.
- [ ] Publish a GitHub release explicitly after the commit is pushed.

Do not publish a GitHub release or tag automatically from this directory.
