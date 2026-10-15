# iPhone 11: experimental A13 support

**English** | [简体中文](IPHONE11.zh-CN.md)

The `mtl3-fallback` branch adds experimental support for **iPhone 11 (A13, 4 GB), tested on iOS 26.3**. This is a branch-specific result, not a change to upstream main's supported-device guarantees. Other A13 models, A12 devices and other 4 GB devices have not been verified by this work.

Core feature implementation is complete: characters can be created, existing saves loaded and gameplay entered. Current work focuses on stability and performance refinement. This document consolidates implementation, investigation findings and validation scope without development-time estimates.

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

## Implementation and investigation findings

### Classic Metal path

- On A13, `respondsToSelector:` does not reliably establish whether a Metal 4 queue can be created: an exposed method can still throw when called. Queue creation and exception handling select the fallback.
- Classic command buffers are created from the queue. Argument buffers encode objects rather than copying raw Metal 4 resource identifiers. Vertex and index bindings use resolved buffer objects and offsets rather than treating GPU addresses as guest addresses.
- The classic path retains resource-usage declarations, residency sets and drawable residency registration. An earlier experiment removing the classic queue's residency set failed; these mechanisms must not simply be deleted.

### Memory

- In an earlier run, disabling PSO warm-up and Granny predecode still left approximately 1615 MiB footprint, and the system terminated the app with `vm-pageshortage`. Lower quality or disabling warm-up alone was insufficient to resolve device memory pressure.
- The game created seven pools of approximately 512, 10, 400, 1, 710, 2 and 40 MiB, totaling 1675 MiB. During on-demand residency testing, the 512 MiB pool had no first-address-use record; accessed pools were registered normally. Unused pools are not proactively added to the residency set.
- GPU `currentAllocatedSize`, process footprint and system wired memory use different accounting rules and cannot simply be added. On-demand residency does not necessarily lower footprint; assess system termination using actual runs and Jetsam reports.
- Partial mappings for all pools caused GPU address faults and were not made the default. Diagnostic switch `DM_CLASSIC_LARGE_POOL_RANGES=1` maps accessed ranges only for classic-path pools of at least 512 MiB. Desktop tests passed, but A13 gameplay validation remains incomplete; leave it off for normal use.

### Character controls

Some original controls were missing or ineffective in low-memory mode. Native buttons follow the current page state and hand actions to the game thread. Starting an existing save uses `MainMenuHD:Play`; simulated controller A was ineffective on this screen, and tapping an already highlighted save does not replace Play.

## Building and running

Use this branch's normal iOS 26 build path and the repository's setup instructions. Prepare your own game files and [Legacy Device Pack](LEGACY_DEVICES.md); neither is supplied by this branch. The A13 runtime fallback is selected automatically. The separate `DM_IOS_M3=1` build targets older operating systems and is not the configuration used for this iPhone 11 validation.

Build shader libraries from the checked-out source and toolchain. The generated `dmsh_chain.h` version must match the bundled `msl/b-<version>` directory; do not copy another developer's local shader fingerprints or signing configuration. A clean checkout and complete resource-generation build still need independent reproduction before a release.

## Validation and limits

- Before merging main, the tester confirmed character creation, loading an existing save, entering other areas and a short play session estimated at ten minutes. One retrieved session recorded about five minutes in the foreground.
- After merging main, loading an existing save worked. A subsequent idle observation reached about 160 seconds: approximately 30 fps and 1771 MiB footprint, with no sustained growth in that observation.
- iOS Release compilation passed. Default and compile-time older-API NVN tests each passed 75 checks; pacing passed 23 checks; the classic-pool test passed with Metal API Validation on an M4 Max. Desktop tests do not prove A13 scene compatibility.
- GPU presentation timeouts remain unresolved. One post-merge session developed repeated errors / ignored submissions; a later session had one entry-time timeout and then recovered. Thermal state reached 2 (serious), and area transitions can stall during texture upload.

This is not a stability or performance guarantee. Back up saves before testing.

## Refinement and regression work

1. Diagnose entry-time GPU timeouts and repeated submission failures, including command dependencies and presentation timing.
2. Reduce repeated texture uploads and area-transition stalls; check resource retirement and memory peaks when changing scenes.
3. Reduce idle and sustained CPU / GPU work, observing thermal state and frame rate.
4. Validate extended sessions, later acts, higher difficulties, repeated area transitions, save-and-exit followed by re-entry, and a complete clean-checkout build.

This document incorporates the useful conclusions from the former feasibility and memory investigation reports; obsolete proposals and schedule estimates have been removed. Broader device support requires further validation.
