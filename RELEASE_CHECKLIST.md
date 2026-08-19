# Release checklist

This working copy is prepared as the first public VelaCU release candidate.

Before the first public release:

- [x] Remove developer-specific absolute paths.
- [x] Remove runtime screenshots, sockets, logs, and caches from the source package.
- [x] Add project MIT license.
- [x] Preserve Cua's MIT attribution and license text.
- [x] Pin the Cua source revision used to build the modified driver.
- [x] Make the modified Cua driver reproducible from a pinned upstream source revision.
- [x] Rebuild the modified Cua driver from a clean upstream snapshot successfully.
- [x] Add a one-command local installer and `velacu doctor`.
- [x] Test the packaged macOS arm64 archive by installing it into a fresh temporary prefix.
- [x] Add automatic Codex MCP configuration with config backup and rollback on setup failure.
- [x] Keep generic MCP configuration available.
- [x] Keep model-facing capture width fixed at 640px.
- [x] Verify a fresh Codex session can use VelaCU without separate coordinate coaching.
- [x] Verify pointer position does not shift between menu-bar animation and resting state.
- [x] Use `ochikoi/VelaCU` as the GitHub owner/repository.
- [x] Ship both the source archive and the prebuilt macOS arm64 archive for the first release.
- [ ] Test/build an Intel/x86_64 package before claiming Intel support.
- [ ] Record the short VelaCU dogfooding demo for the repository page.
- [ ] Publish the repository.
- [ ] Create the first GitHub release and attach the packaged archive + SHA-256 file.

Do not publish automatically from this directory; final publication should be an explicit user action.
