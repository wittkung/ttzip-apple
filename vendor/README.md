# Vendored first-party modules

These modules are first-party MetastudyLine code that has no public repository of its own.
They are vendored verbatim (modulo the `SPDX-License-Identifier` header normalization
applied to the whole export) so that this repository stays self-contained and buildable
without any private dependency.

| Path | Swift package | Why it is vendored |
| --- | --- | --- |
| `vendor/ttkit` | `TTKit` | Design-system Swift package (TTKitCore/Design/Fluid/UI) consumed by the app. No public repository exists, so it is vendored. |
| `vendor/tti18n` | `TTI18n` | Localization Swift package (TTI18nCore/UI/AppKit/IPC) consumed by the app. No public repository exists, so it is vendored; its Swift package stays at vendor/tti18n/apple/TTI18n so sibling path references keep resolving. |
| `vendor/ttmedia` | `TTMediaKit` | Media/preview Swift package (TTMediaKit) consumed by the app. No public repository exists, so it is vendored; it stays at vendor/ttmedia so the ../ttkit and ../tti18n sibling references keep resolving. |

Each vendored package keeps its own `Package.swift` unchanged except for the
`.product(package:)` arguments, which are rewritten to the dependency identity SwiftPM
computes for the vendored paths. `vendor/ttmedia` additionally declares its
`TTMediaDemux` C module map as a SwiftPM system library, because Bazel injects that
module map through `swift_interop_hint` and SwiftPM has no equivalent otherwise.

The vendored packages ship under the same dual MIT / Apache-2.0 license as the rest of this
repository; see the root `LICENSE` file.

Only the subsets required to build the application are vendored: the Rust crates,
TypeScript workspaces, design-token tooling, internal specification documents and (for
`vendor/ttmedia`) the binary media test fixtures are omitted. The fixtures are Git LFS
backed and are not used by this repository's build or test suites.
