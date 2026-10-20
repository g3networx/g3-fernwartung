# g3 macOS and Linux FullClients

## Reproducible build

1. Check out the exact source commit with submodules (`git clone --recursive`).
2. Run the **g3 macOS and Linux clients** workflow on that commit; choose `macos`, `linux`, or `all`.
3. Native runner pairs are macOS Intel / Apple Silicon and Ubuntu x86_64 / ARM64. Rust, Flutter, vcpkg and Actions revisions are pinned in the workflow.
4. A completed build triggers **g3 platform package validation**. It downloads only architecture-matching artifacts, verifies their recorded SHA-256 digests and source run, corrects g3 package metadata, and runs native package/launch smoke checks. It does not rebuild the Rust client.
5. Keep the package together with `validation.json`, `SHA256SUMS`, logs and GUI preview. Publish only the packages whose validation job passed. A successful launch is not an end-to-end remote-session acceptance test.

## macOS

`g3Fernwartung.app` uses bundle ID `de.g3networx.fernwartung` and registers the `g3fernwartung:` URI scheme used by the web address book. The Swift runner calls the existing `rustdesk_core_main` entry point through the small native header `g3_bridge.h`; the committed generated Dart/Rust FFI ABI remains unchanged. Validation checks the exported Rust wire symbols and recompiles the menu with the g3 Swift module name.

The configured deployment targets are 10.14 for Intel and 12.3 for Apple Silicon. These build settings are not proof of operation on all older macOS versions. Report actual tested systems separately.

The build uses an ad-hoc integrity signature. It is not an Apple Developer ID signature and is not notarized. Windows SignPath approval does not sign/notarize macOS software. macOS screen-recording and accessibility consent must be granted through the operating system by the device owner; the application does not bypass these controls.

## Linux

The Debian package is named `g3fernwartung`, version `1.5.0-g3.17` for the corrected Linux UI build. The service, launcher, desktop files, protocol handler and application files use a g3 namespace. The existing upstream shared-library filename is retained for the generated FFI loader. Repackaging preserves program binary contents and sets the g3 maintainer, homepage and package version explicitly.

Architectures are `amd64` / x86_64 and `arm64` / aarch64. The validation workflow installs each native package in an isolated Ubuntu 22.04 container, checks the executable version, and starts its GUI in a virtual display. Customer hosts and the runner host package database are not used for installation tests.

## Updates and disclosure

These are FullClients. Non-Windows clients direct the user to the platform download page and never execute the Windows MSI updater. A source/build provenance record accompanies every package. No customer enrollment tokens, credentials or private signing keys belong in the source, artifacts or release manifests.

## Native-library preserving UI rebuild and session acceptance

`g3-linux-ui.yml` rebuilds Flutter/package layers using the verified native library from run 39380639746. It verifies the exact package digest and rejects changes to native source/build inputs before reusing that library. The source record includes the native source separately from the current UI source.

`g3-linux-session.yml` accepts a successful package-validation run as input. Two disposable containers obtain distinct identities, use a random masked password, and establish a real remote session. The viewer must receive two changed target desktop colors, each covering more than 12% of the viewport. Matching package SHA-256, architecture, observed fractions and final result are recorded; no credentials or raw UI screenshots are published. Container cleanup runs even on failure.

The g3.17 correction catches failures of the optional Linux screen-saver/keep-awake integration; a desktop without org.freedesktop.ScreenSaver must not lose its session. Installation/GUI smoke checks alone did not detect that issue, so g3.16 preview downloads were held pending the real-session retest. Promotion must match both package validation and successful session evidence to the exact package SHA-256.
