# iPhone 11: experimental A13 support

**English** | [简体中文](IPHONE11.zh-CN.md)

The `mtl3-fallback` branch adds experimental support for **iPhone 11 (A13, 4 GB), tested on iOS 26.3**. This is a branch-specific result, not a change to upstream main's supported-device guarantees. Other A13 models, A12 devices and other 4 GB devices have not been verified by this work.

## What changed

| Area | Implementation |
|---|---|
| Graphics | When Metal 4 queue creation is unavailable, use a classic Metal queue, command buffers and encoders. Bind vertex/index buffers by object and offset; encode indirect argument buffers with `MTLArgumentEncoder` and declare resource usage. |
| Textures | Provide classic upload and auxiliary LUT / ASTC-copy paths. Keep the Legacy Device Pack requirement. Skip Metal-4-only bloom / frame-extrapolation optimizations and use their existing fallback paths. |
| Memory | Preserve complete pool address mappings, but register residency only on first use and retire resources after GPU completion. This optimization also exists in upstream main; this branch integrates it with the A13 path. Experimental partial pool mappings remain off by default. |
| Defaults | On devices with at most 4 GB and without the Apple7 GPU family, enable the low-memory profile: output width capped at 1280, 3D scale 0.5, 30 fps and a 32 MiB Granny predecode cache. Explicit environment overrides remain available. |
| Touch | Add native Create, Standard / Hardcore and Play buttons in low-memory mode. Play sends the original `MainMenuHD:Play` action on the game thread. |
| Tests | Add classic-pool copy, indirect-pointer, bounds and first-residency checks; retain upstream NVN and pacing tests. |

The output cap preserves aspect ratio; the tested iPhone 11 output was 1280×592, with 3D rendering at approximately 640×296. These settings do not reduce every category of memory use.

## Building and running

Use this branch's normal iOS 26 build path and the repository's setup instructions. Prepare your own game files and [Legacy Device Pack](LEGACY_DEVICES.md); neither is supplied by this branch. The A13 runtime fallback is selected automatically. The separate `DM_IOS_M3=1` build targets older operating systems and is not the configuration used for this iPhone 11 validation.

Build shader libraries from the checked-out source and toolchain. The generated `dmsh_chain.h` version must match the bundled `msl/b-<version>` directory; do not copy another developer's local shader fingerprints or signing configuration. A clean checkout and complete resource-generation build still need independent reproduction before a release.

## Validation and limits

- Before merging main, the tester confirmed character creation, loading an existing save, entering other areas and a short play session estimated at ten minutes. One retrieved session recorded about five minutes in the foreground.
- After merging main, loading an existing save worked. A subsequent idle observation reached about 160 seconds: approximately 30 fps and 1771 MiB footprint, with no sustained growth in that observation.
- iOS Release compilation passed. Default and compile-time older-API NVN tests each passed 75 checks; pacing passed 23 checks; the classic-pool test passed with Metal API Validation on an M4 Max. Desktop tests do not prove A13 scene compatibility.
- GPU presentation timeouts remain unresolved. One post-merge session developed repeated errors / ignored submissions; a later session had one entry-time timeout and then recovered. Thermal state reached 2 (serious), and area transitions can stall during texture upload.

This is not a stability or performance guarantee. Extended sessions, later acts, higher difficulties and repeated area transitions still need validation. Back up saves before testing. Earlier investigation notes are in [the memory log](IPHONE11_MEMORY_DEBUG.zh-CN.md) and [the feasibility report](MTL3_FALLBACK_FEASIBILITY.zh-CN.md), both in Chinese; their historical assumptions are not current implementation guidance.
