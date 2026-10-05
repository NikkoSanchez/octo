# Ghostty provenance and notices

Octo compiles the official [Ghostty repository](https://github.com/ghostty-org/ghostty/tree/332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28) **1.3.1** at `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`. The MIT notice is preserved in [Ghostty-LICENSE.txt](Ghostty-LICENSE.txt) and the app resource bundle. `Ghostty.lock.json` records the source, header/module-map digests, official Zig compiler archive digests, flags and empty patch list.

`Sources/OctoGhostty` is Octo's native host implementation. Its C contract and native input behavior were developed against official `include/ghostty.h`, `src/apprt/embedded.zig` and `macos/Sources/Ghostty` at this pin. The MIT notice above also accompanies that upstream reference material. The retired community wrapper's Swift implementation, prebuilt framework, mobile backends, display-link library and patches are not included in the active build.

`Scripts/ghostty/build.py` bundles the corresponding `ghostty` and `terminfo` resource trees and collects component LICENSE/COPYING/NOTICE files from upstream's vendor directory and fetched Zig packages. The generated `Runtime/Notices/inventory.json` records paths and hashes. Fonts and shell-integration files retain their own notices. This is a build inventory, not a completed redistribution license review; Octo still has no distribution license, signing/notarization or release workflow.

See [the integration record](../docs/GHOSTTY.md) for the patch disposition, build instructions, tested behavior and remaining validation.
