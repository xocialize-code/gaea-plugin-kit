# GaeaPluginKit

GaeaPluginKit turns MLXEngine model packages into a Gaea plugin worker. The worker is a signed executable in a
`.gaeaplugin` bundle that speaks the Gaea Plugin Protocol v1 on stdin and stdout (xocialize/gaea, `spec/GPP-1.md`).
The kit also writes the bundle's `manifest.json` from the plugin's own code, so the manifest can't drift from the
worker.

Requires macOS 26 and mlx-engine-swift 0.72.0 or later (contract 1.57.0).

| Product | What |
|---|---|
| `GaeaPluginKit` | The worker: GPP's protocol loop over `MLXServeEngine(workerBudget:)`, the plugin declaration, and the manifest generator |
| `GaeaProtocol` | MLX-free: JSON values, the manifest's types, GPP's vocabulary. The Gaea host links no MLX and can share it |
| `gaea-plugin-check` | A tiny MLX-free host. It verifies a built bundle, launches it under `Process.launchRequirement`, and drives a GPP session |

v1 trusts one Developer ID team, CFZS6RXUCP (`GPP.trustedTeam`, G-22). The manifest generator refuses any other team,
and `gaea-plugin-check` has no override. An operator-approved trust list ships in G4.

## A plugin

```swift
import GaeaPluginKit

let plugin = GaeaPluginDefinition(
    id: "com.xocialize.gaea.z-image", version: "0.1.0", team: "CFZS6RXUCP",
    repo: "https://github.com/xocialize/gaea-plugin-z-image", title: "Z-Image", license: "Apache-2.0",
    executable: "gaea-z-image-worker",
    models: [.engine(ZImageTurboT2IPackage.self, id: "z-image-turbo", title: "Z-Image Turbo",
                     lanes: [LaneDefinition(id: "int4", default: true, configuration: ZImageConfiguration.turbo(quant: .int4))],
                     operations: [EngineOperation("image.generate", outputNames: ["image": "images"]) { job in
                         EngineCall(T2IRequest(prompt: try job.text("prompt") ?? "", seed: job.seed))
                     }])],
    offers: [/* PluginManifest.Offer(...) */])

await GaeaPluginMain.run(plugin)
```

- `<worker>` serves GPP: what Gaea launches.
- `<worker> --manifest <file>` writes `manifest.json`. `models[]` is MLXToolKit's own `PackageManifest`, plus one
  `ResolvedLane` per lane, as `tools/manifest-gen` writes them. The plugin build runs `tools/validate.py --manifest`
  on it before signing.

- A text input (an MES `prompt` or `instruction`) arrives as a UTF-8 file: `job.text("prompt")` reads it (GPP-1 §3.3).
- One engine call per result: `EngineOperation(op, calls: { job in [EngineCall] })` runs them in order, for an MES
  `count` on a capability that returns one image per call. Outputs are listed in call order (`image-0`, `image-1`, …),
  `effective` values are merged, and each warning is kept once. Progress spans the whole job.
- A self-running operation, `EngineOperation(op) { job, session in … }`, makes the engine calls it decides on with
  `session.run(request)` and returns its `RunResult` itself. `session.run(request, model: id)` calls another engine
  model of the same plugin, at its default lane, with its weights already on disk: the forge pack's guarded upscale
  runs NERVE under the words the text guard protects in a Nacre job.
- Leave a lane configuration's models root unset. The engine fills it from the root Gaea sends in `configure`.

[gaea-plugin-demo](https://github.com/xocialize/gaea-plugin-demo) is the template: bundle layout, signing, checks,
notarization and release CI. [gaea-plugin-z-image](https://github.com/xocialize/gaea-plugin-z-image) is the first
plugin on an MLXEngine package.

`gaea-plugin-check <bundle> [--operation op] [--model id] [--lane id] [--params json] [--model-params json] [--seed N]
[--text name=text]… [--input name=path]… [--models-root dir] [--budget bytes] [--timeout s] [--session file]` checks a
built bundle: its signature, a launch under the launch requirement, hello, and one run. `--models-root` points it at
weights already on disk, and `--budget` must cover the lane.

## What the worker does

| GPP | The kit |
|---|---|
| `hello` | Plugin, models and engine from the definition. `manifest_sha256` is the digest of the bundle's `manifest.json` |
| `configure` | Builds `MLXServeEngine(workerBudget:)` and points its model store at `models_root`. Settings get their manifest defaults filled in. The plugin's `onConfigure` hook then runs in a task of its own |
| `materialize` | `engine.materialize(package:)`, with `materialize.progress` from the download sink. Byte counts come from `materializationPreview`. A lane the package materializes itself is answered `invalid_request`: send `prepare` |
| `prepare` | Registers the lane under the model's id, replacing another lane of the same model. Then `engine.prepare`; a download on the way is relayed from `PreparationMonitor.events()`. A custom model's lane is charged as an external tenant |
| `run` | The plugin's `EngineOperation` builds the canonical request, and `engine.run` executes it. A `RunProgress` sink feeds `progress`. The response is encoded with `CapabilityWire.encoder(spool:)` into `output_dir`: artifacts become files named after their field, other fields become values. Missing weights are `not_materialized`. A second run gets `busy` |
| `cancel` | Cancels the run's task. The run ends with `cancelled` ("Cancelled at step k of n.") |
| `unload` | `engine.evict(package:)`, or the custom model's `unload()` and the withdrawal of its tenant |
| `memory` | `engine.workerMemoryReport()`, unchanged: on `memory.query`, and unprompted after `prepared`, `unloaded` and a run's end |
| storage | `context.storage.get/put/delete/query`: worker requests matched to the host's replies |
| `shutdown`, end of stdin | Cancels a run in flight, then exits 0 |
| anything else | `protocol` errors for lines that aren't JSON or aren't a host message. `invalid_request` for a missing or unknown field, as the closed schema says |

Per-job progress uses the `RunProgress` sink rather than `RunMonitor.events()`. The engine documents the sink as the
per-job channel, and the monitor's stream is keyed by package. With one run per worker the two carry the same reports.

## Tests

```bash
swift test
```

The tests need a checkout of xocialize/gaea, at `../gaea-mes-media-server` or `GAEA_SPEC_ROOT`. They:

- generate `examples/v1/manifest/{demo,z-image}.json` from code, check the result is the same JSON, and run
  `validate.py --manifest` on it;
- replay every `examples/v1/gpp/*.gpp`: the `H` lines go to a worker over a real `MLXServeEngine` with fake packages,
  and each `W` line is compared field by field. Only pid, timings, measured memory and computed values are masked;
- run each session the worker produced through `validate.py --transcript`;
- cover the paths the examples don't walk: before configure, unknown fields, unknown lanes, unoffered operations,
  `busy`, and `shutdown` during a run.

## Licence

Apache-2.0.
