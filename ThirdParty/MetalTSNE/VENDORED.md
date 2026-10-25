# MetalTSNE (vendored)

- Upstream: https://github.com/vals/mac-tsne, commit `45d5c918848f12fba1414265ed5b1c0b00170bbc` (2026-08-27)
- Licence: MIT, see `LICENSE` in this folder (copyright Valentine Svensson).
- Copied: `Sources/MetalTSNE` and `Tests/MetalTSNETests`. Not copied: the demo apps, the benchmark and the demo data.
- Why vendored: `TSNEModel` could not be rebuilt from stored data, and we need that to place new samples after a restart.

## Changes against upstream

Keep this list complete, so a later upstream update can be merged by hand.

- `Sources/MetalTSNE/TSNE.swift`: `TSNE.context` is no longer `private` (one word), so the new file can build a model.
- `Sources/MetalTSNE/ModelState.swift` (new): `TSNEModelState`, `TSNEModel.state` and `TSNE.restoreModel(_:parameters:)`.
- `Tests/MetalTSNETests/ModelStateTests.swift` (new): tests for the above.
