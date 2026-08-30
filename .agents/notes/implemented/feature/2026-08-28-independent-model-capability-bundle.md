# Agent Note: Independent custom-model capability Bundle

Status: implemented

English | [中文](2026-08-28-independent-model-capability-bundle.zh.md)

## Problem

Portable users can connect OpenAI-compatible endpoints whose model listings omit reasoning and image-input metadata. Editing the official DeepSeek Harness package would make these capabilities dependent on a particular upstream build, while guessing from model names would create false declarations. Unprompted probes of public endpoints can also spend user quota or send data outside the user's network.

## Decision

`@maiziman/dsh-model-capabilities` is an official-format DeepSeek Harness Bundle installed beside the upstream packages. It observes the public `llm-pi-ai` settings and Credentials services without importing or replacing the official adapter. Provider metadata is the preferred evidence; explicit model and provider declarations always win. Bounded active probes are allowed only for exact `localhost` and literal loopback, private-network, link-local, or unique-local addresses by default. Requests reject redirects. Reasoning is saved only when the server rejects an invalid effort canary and a valid request returns a reasoning field. Image input is saved only when the model returns the exact color word for both randomly ordered embedded private PNG challenges; explanatory or ambiguous replies fail.

The plugin reconciles existing local providers at startup, after provider-setting changes, and after a route's credential reference changes. One process attempts each provider/model/credential configuration once unless that credential changes. A settings update invalidates and aborts the active generation synchronously, then starts reconciliation in the next microtask because the official SettingsProvider commits its resolved value immediately after its synchronous update event. Stale responses are discarded, and attempts enter the lifetime cache only after the current revision is accepted. The expected revision of the plugin's own settings notification is suppressed, while a conflicting writer at that revision schedules a retry after the mutation fails. Provider-level `compat` objects are merged base-first and user-second before explicit disable and thinking-format decisions, matching the official recursive merge for plain objects. A credential change that overlaps an accepted asynchronous write marks its plugin-added model fields as tentative. The next generation ignores those exact additions while collecting fresh evidence, then confirms them or removes only additions that remain structurally unchanged. Removing the provider or model clears the tentative entry so a later same-name model is treated as explicit. Writes preserve every unrelated provider and model field. Disposal cancels pending requests, and diagnostics remove URL credentials, queries, and fragments.

The Bundle's seven published files ship only as an npm tarball from a dedicated `plugin-model-capabilities-v*` GitHub Release whose Draft, checksum, and Latest status are verified separately from portable ZIP Releases. DeepSeek Harness Pure Portable contains and auto-installs no plugin; users add this Bundle to the chosen profile through the official `dsh plugin` command. The plugin remains outside every upstream package, so the upstream dsh source and adapter stay unchanged.

## Alternatives considered

- Patching the upstream adapter ties the behavior to a vendored build and risks losing it during upgrades.
- Replacing or wrapping the official provider row duplicates adapter ownership and increases compatibility risk.
- Inferring capabilities from provider or model names is not reliable evidence.
- Probing every endpoint by default can spend quota and transmit synthetic prompts to public services.
- Metadata-only discovery cannot classify sparse local OpenAI-compatible servers.

## Consequences

Official application upgrades can replace all upstream packages without overwriting an independently installed Bundle. Existing local profiles are reconciled when that profile next loads the plugin. Public endpoints remain metadata-only unless the user explicitly selects the `always` policy. Saved capability fields remain ordinary user settings if the Bundle is removed. A new pure portable folder does not gain the behavior until the user installs the plugin into its profile.

A sparse local endpoint that never returns positive evidence can be probed again after a later application restart. Requests remain background, bounded, configurable, and restricted to local endpoints by default. The final plugin tarball installs, expands its complete layer, and boots the Web profile through the official command at exact upstream tag `dsh-v0.1.2-alpha.1` (`cd5ef814`). The independent plugin Release gate repeats that installation against the pinned upstream tag and commit before publication. Later pre-release changes to the settings service or `llm-pi-ai` schema may require another plugin update.
