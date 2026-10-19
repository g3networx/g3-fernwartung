# g3 Fernwartung 1.5.0-g3.5

Modified RustDesk Windows x64 client, based on tag 1.5.0, commit fada664df7a294d1d1a9ca3e7cd3637069122f17.
Copyright RustDesk contributors; g3 branding and integration changes 2026 g3 NetworX. Distributed under GNU AGPL v3; see LICENCE and upstream copyright notices. This is an independent build, not an official RustDesk release.

Changes: company artwork/title/icon and dark default; fixed ID/relay/key settings; account/address-book/network/printer settings hidden; optional scoped device enrollment; one-use HTTPS credential handoff without passwords in browser links or process arguments; launch arguments removed from logging. Existing session consent and security controls remain available. No shared unattended password is embedded.

## Rebuild

Use Windows x64 with Visual Studio C++ tools and Windows SDK. The reference environment used Visual Studio Community 2026 18.9, MSVC 14.51.36231 and Windows SDK 10.0.26100.0. Use a short source path and Git core.longpaths=true. Do not use runtime server secrets; the embedded server key is public.

Tools: Rust 1.75.0 (rustfmt component), Flutter 3.24.5, LLVM 15.0.6, vcpkg commit 9e593bb18ea69cc5095e012465dcd675a822ed0d, Python 3.12 with Brotli 1.2.0. Cargo.lock and flutter/pubspec.lock pin application dependencies. Set private build directories for CARGO_HOME, RUSTUP_HOME, PUB_CACHE and VCPKG_ROOT; do not change the user's home directory.

1. Open a VS x64 developer shell. Set VCPKG_ROOT AFTER entering that shell, since VS can replace it with its bundled vcpkg. Add Rust, Flutter, LLVM and CMake to that process's PATH. Set LIBCLANG_PATH to LLVM/bin and CARGO_BUILD_JOBS=4.
2. Bootstrap pinned vcpkg and run from this source root: `vcpkg install --triplet x64-windows-static --host-triplet x64-windows-static --x-install-root=%VCPKG_ROOT%/installed`. The included FFmpeg overlay requests release-only production libraries to avoid the incompatible VS2026 debug configuration. AOM, libvpx, JPEG, libyuv, Opus and media headers are described by vcpkg.json and res/vcpkg.
3. In flutter/, run `flutter pub get`. Install flutter_rust_bridge_codegen 1.80.1 with feature uuid and --locked, and cargo-expand 1.0.95 --locked. Generated bridge sources are included, so regeneration is optional. To regenerate, use `flutter_rust_bridge_codegen --rust-input ./src/flutter_ffi.rs --dart-output ./flutter/lib/generated_bridge.dart --c-output ./flutter/macos/Runner/bridge_generated.h --llvm-path PATH_TO_LLVM`. On VS2026 add `--llvm-compiler-opts` with `-isystem PATH_TO_MSVC/include -isystem "PATH_TO_WINDOWS_SDK/ucrt"`; otherwise libclang can silently generate wrong bool/int64 bindings. Confirm the generated Dart uses ffi.Bool and ffi.Int64, never a typedef called bool.
4. On Flutter 3.24.5 with VS2026, add the Visual Studio 18 2026 case to the cmakeGenerator switch in flutter_tools/lib/src/windows/visual_studio.dart, then rebuild the Flutter tool snapshot. Apply the included upstream .github/patches/flutter_3.24.4_dropdown_menu_enableFilter.diff to the Flutter SDK.
5. Follow upstream's x64 engine replacement: https://github.com/rustdesk/engine/releases/download/main/windows-x64-release.zip replaces the SDK's bin/cache/artifacts/engine/windows-x64-release files after `flutter precache --windows`. engine-provenance.json records the exact downloaded artifact SHA256. The engine source is https://github.com/rustdesk/engine. Flutter framework source is pinned at dec2ee5c1f98f8e84a7d5380c05eb8a3d0a81668.
6. From the source root run `python build.py --portable --flutter --skip-portable-pack --hwcodec --vram`. The unsigned application bundle is flutter/build/windows/x64/runner/Release. This is a native modified client; an upstream exe is not being relabeled.
7. Copy the Release bundle into a separate package directory, omit PDB debug symbols, and rename the payload rustdesk.exe to g3fernwartung.exe. Keep all DLLs and data files, and add LICENCE and a SOURCE.txt pointing to the source download. Package using libs/portable/generate.py with `-f PATH_TO_PACKAGE -o libs/portable -e PATH_TO_PACKAGE/g3fernwartung.exe -l 5`. The executable must be inside the folder. Copy the resulting portable packer as g3-Fernwartung-1.5.0-g3.1-install.exe. A filename ending in install.exe opens the installer. Ship LICENSE and the generated Flutter NOTICES with the bundle. This build has no publisher signature.

The public device enrollment and handoff endpoints require the separate address-book service. An enrollment invitation allows exactly one registration into its assigned address book, expires after 20 minutes and exposes no other tenants. The handoff grant expires after 60 seconds, is redeemed once over certificate-validated HTTPS, and is bound to an authenticated, permitted web session. Passwords are not part of enrollment. Configure each device's permitted permanent access separately and store it encrypted in the web vault when automatic login is desired.

## Corresponding dependency sources

The adjacent g3-fernwartung-dependencies.zip contains the Rust registry/git and Dart dependency source used in this build, plus patched FFmpeg and overlay sources. Documentation videos, examples and test fixtures not needed to build the shipped binary are omitted. Additional library source archives are under third-party-library-sources/ in this archive; res/vcpkg contains their build patches. All original license/copyright notices are retained. No server private keys, portal service secret, customer data or passwords are included.


Release g3.4 (2026-10-19):
- Full, incoming-only installed Host, and portable incoming-only Soforthilfe variants.
- Permanent password provisioning requires native daemon ACK before server vault confirmation.
- Automatic authorized connection journal, heartbeat, immediate durable disconnect flush before closing the last CM tab. Interrupted reports require billing review.
- Signed Windows payload EXE/DLL and outer portable installer: internal self-issued g3 NetworX code-signing certificate, SHA256 and RFC3161 timestamp. This is NOT public publisher trust. No trust store changes are performed.
- Private signing key stays non-exportable in the build user's Windows certificate store; not distributed. The public certificate is downloadable separately.
- Build, sign payload, pack each variant, sign outer wrapper, then compute release SHA256. A public CA certificate can replace the internal certificate in this pipeline.

Release g3.5: sidebar actions reordered; uniform one-line buttons and spacing; wider FullClient sidebar and visible revision label.
