# DeepSeek Harness Model Capabilities

[中文](README.zh.md)

`@maiziman/dsh-model-capabilities` is an independent DeepSeek Harness Bundle that discovers reasoning controls and image input for custom `llm-pi-ai` providers. It uses public Harness services and leaves the official adapter unchanged, so an upstream dsh replacement cannot overwrite the plugin's implementation.

## What it changes

The plugin observes the official `llm-pi-ai` settings namespace after an OpenAI Completions-compatible provider is saved. Other provider protocols are ignored. It reads declared capability metadata first, then applies revision-checked path mutations to that provider's `models` array. It only fills an absent `input` or `reasoningEfforts` field; an explicit model value, including `reasoningEfforts: false` or `input: [text]`, always wins.

Supported metadata includes OpenRouter `architecture.input_modalities`, `supported_parameters`, and `reasoning.supported_efforts`; OpenAI-compatible `supported_parameters: [reasoning_effort]`; and Ollama `/api/show` `vision` and `thinking` capabilities. Model names are never used as evidence.

For a literal local or private-network endpoint whose metadata is incomplete, the default Bundle may make small background Chat Completions requests at plugin startup, after the settings document changes, and after the route's credential reference changes. A reasoning level is added only when the server rejects an invalid canary value and the valid request returns a reasoning field. Image input is added only when the model returns the exact color word for both randomly ordered private inline PNGs; explanatory or ambiguous answers fail the check. These probes do not block application startup and are attempted once per provider/model/credential configuration during a process lifetime.

Public endpoints receive metadata requests only by default. This avoids silent billable inference calls. Set `activeProbePolicy: always` only for endpoints where the extra requests and their token cost are acceptable.

## Install

The portable ZIP already includes this Bundle. For an official npm installation of DeepSeek Harness, download the versioned plugin tarball and checksum from the [v0.1.0 plugin Release](https://github.com/maiziman/deepseek-harness-portable/releases/tag/plugin-model-capabilities-v0.1.0), then verify and install it with the official Bundle workflow:

```powershell
$version = '0.1.0'
$package = "maiziman-dsh-model-capabilities-$version.tgz"
$release = "https://github.com/maiziman/deepseek-harness-portable/releases/download/plugin-model-capabilities-v$version"
Invoke-WebRequest "$release/$package" -OutFile $package
Invoke-WebRequest "$release/SHA256SUMS.txt" -OutFile SHA256SUMS.txt
$expected = ((Get-Content SHA256SUMS.txt -Raw).Trim() -split '\s+')[0].ToLowerInvariant()
$actual = (Get-FileHash $package -Algorithm SHA256).Hash.ToLowerInvariant()
if ($actual -ne $expected) { throw 'plugin checksum mismatch' }
dsh plugin --profile web add ".\$package"
dsh --profile web --dump-config
dsh --profile web
```

Repeat the same command with a newer plugin Release to upgrade. The plugin Release is intentionally separate from portable ZIP Releases, so its version can advance without changing the packaged dsh version.

During local development, install this directory instead:

```sh
dsh plugin --profile web add ./plugins/dsh-model-capabilities
dsh --profile web --dump-config
```

The portable desktop ships this directory and stages its seven published files under the Web profile. It performs the same official local-package registration when the profile is first created, and refreshes the staged files when the plugin version changes. If the portable directory moves, the launcher repairs pnpm's generated link from the profile's relative dependency declaration before starting Harness.

The package manifest declares `dsh.bundle.patch`, and `cordis.patch.yml` inserts the plugin as a later composition row. Removal does not alter model settings that were already confirmed and saved:

```sh
dsh plugin --profile web remove @maiziman/dsh-model-capabilities
```

## Configuration

The shipped Bundle uses:

```yaml
- insert:
    - id: model-capabilities
      name: '@maiziman/dsh-model-capabilities'
      config:
        metadataDiscovery: true
        activeProbePolicy: local-only
        reasoningProbe: true
        visionProbe: true
        reasoningProbeEfforts: [low, high, max]
        probeConcurrency: 1
        requestTimeoutMs: 10000
        probeMaxTokens: 128
```

| Field | Meaning |
|---|---|
| `metadataDiscovery` | Read non-generating model metadata. |
| `activeProbePolicy` | `never`, `local-only`, or `always`; `local-only` recognizes exact `localhost` plus literal loopback, link-local, RFC 1918, and unique-local IPv6 addresses. DNS names require `always`. |
| `reasoningProbe` | Allow reasoning requests when the active-probe policy permits them. |
| `visionProbe` | Allow the inline image request when the active-probe policy permits it. |
| `reasoningProbeEfforts` | Effort spellings tested independently; only positively observed levels are saved. |
| `probeConcurrency` | Maximum simultaneous reasoning probes for one model. |
| `requestTimeoutMs` | Bound for each metadata or active request. |
| `probeMaxTokens` | Maximum output tokens requested by a probe. |

To override the defaults, target the `model-capabilities` row in the profile's own `cordis.patch.yml`. A later row configuration replaces the complete earlier configuration, so restate every field you want to keep.

## Security and privacy

API keys are resolved through `ctx.credentials` and used only in request headers. They are not written to model settings or logs. Requests reject redirects, responses are capped at 2 MiB, request time is bounded, and plugin disposal aborts in-flight requests. A relevant settings or credential change cancels the old discovery generation; stale responses are discarded, and a failed revision-checked write remains eligible for retry. The plugin recognizes its own settings notification, so a successful write does not repeat the probe. If a credential changes while an accepted write is still being persisted, its plugin-added fields remain tentative: the next generation revalidates them and removes only unchanged additions that no longer have positive evidence. Removing the provider or model clears that tentative ownership. Endpoint errors otherwise leave the current model settings untouched.

The vision probe sends two generated 32 × 32 solid-color PNGs embedded in separate requests. It does not read or upload a user file. The reasoning probe sends a fixed arithmetic prompt plus one invalid-value canary. Set `activeProbePolicy: never` to disable all generating requests.

## Test

```sh
npm test
npm pack --dry-run
```

The test suite covers metadata formats, local-network classification, positive-evidence probes, explicit-setting preservation, credential resolution, and revision-checked writes.

## Compatibility

| DeepSeek Harness | Verification |
|---|---|
| `0.1.1-rc.2` | Portable registration, profile boot, settings mutation, and packaged runtime tests. |
| `0.1.2-alpha.1` (`cd5ef814`) | Clean install of this final `.tgz` through the exact tagged source's official `dsh plugin` command, complete `--dump-config`, profile boot, Settings/Credentials API review, update-event timing regression, and layered `compat` regression. |

Every plugin Release tag repeats the clean official-source install, expanded-config check, and Web-profile boot against the exact tag, commit, and pnpm version in [`.github/plugin-compatibility.json`](../../.github/plugin-compatibility.json). The Release is not published if that gate fails.

When an official Git tag precedes its exact npm package, the portable updater waits for that package rather than building a different version. Harness is still pre-release, so a future upstream settings schema may require a plugin update. A failed validation or concurrent edit is contained and leaves the last valid provider configuration serving requests.
