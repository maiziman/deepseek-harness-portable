# Agent Note: Exact-ID publication for upstream and plugin Releases

Status: implemented

English | [中文](2026-08-30-exact-id-release-publication.zh.md)

## Problem

The portable build depends on an installable `@deepseek-ai/dsh` package, while the official project announces source versions with `dsh-v*` Git tags and may publish the matching npm package later. Tracking an npm dist-tag alone can therefore miss an official prerelease. GitHub Release staging also requires a strict private-to-public transition: a tag-based upload helper may select an existing public Release before a later validator can reject that state. PowerShell GitHub API collection responses must be normalized after assignment because wrapping `Invoke-RestMethod` directly in `@(...)` can retain the JSON array as one nested element.

## Decision

The upstream watcher selects the highest Semantic Version among official `deepseek-ai/deepseek-harness` `dsh-v*` tags and records its commit SHA. The run remains successful and performs no build while the exact npm version is absent. Once installable, the version enters the two-runner Windows build and real-startup verification. The portable Release policy allocates the next patch after the highest complete public strict `v<SemVer>` Release. The historical `v1.0.0` through `v1.2.0` tag/ZIP mismatch is an explicit migration floor; every later Release requires its tag, ZIP, and `portable-version` marker to agree. Exact `dsh-version` markers make repeated packaging idempotent and allow several portable patches to carry one dsh version. Immediately before publication, the workflow confirms the official tag still resolves to the recorded commit, remains the highest version for automatic runs, still has an exact npm package, and still owns the same portable allocation under the shared portable-publication lock.

Release staging uses a repository-owned script and an exact GitHub Release ID. Every run creates a private Draft with an isolated temporary tag and an exact source commit, uploads only the expected assets, and checks their size and GitHub SHA256 digest. The staging step records the resolved body SHA256; finalization re-reads the exact ID, body, source commit, and public tag immediately before one API mutation assigns that tag and changes `draft` to `false`. The resulting tag and the Release's recorded target must resolve to the same exact commit. Generated notes follow a fixed identity prefix and an explicitly selected previous portable tag; public reruns validate that stable prefix without requiring GitHub to regenerate identical prose. This design never deletes or replaces a Release asset: an interrupted run can leave a private orphan Draft, while the next run starts independently. A complete public Release is validated without a write.

Portable packages and the model-capabilities plugin use independent Release lifecycles. Manual `v*` portable tags use the tag version for `portableVersion` and read their exact dsh package version from a file committed with the tag, while branch verification resolves npm `latest` once per run. Automatic upstream packages join the same monotonic `v*` stream. Generated portable notes explicitly select the previous complete public portable Release with a strict `v<SemVer>` tag, so failed tags plus legacy upstream and plugin tag families cannot change the comparison range. Portable Releases contain one ZIP and `SHA256SUMS.txt`; GitHub prerelease state also signals a preview dsh dependency. Plugin tags follow `plugin-model-capabilities-v<version>`, contain one npm tarball and `SHA256SUMS.txt`, and publish with GitHub's Latest status disabled so the main download remains the portable application.

## Alternatives considered

- Following npm `latest` or `next` cannot represent an official Git tag whose package is pending or deliberately has no dist-tag.
- Building directly from every source tag requires reproducing the upstream monorepo release pack and dependency set; waiting for the exact official npm package preserves the portable project's published-package boundary.
- A tag-based third-party upload action cannot prove it will operate on a Draft before it mutates assets.
- Adding the plugin tarball to each portable Release couples unrelated versions and weakens both two-asset validators.

## Consequences

An official source tag can be visible in the watcher before a portable package is possible. The Actions summary reports that waiting state, and the six-hour schedule makes the exact npm package eligible without a dist-tag change. Shell and bundled-plugin fixes can publish a higher portable patch without changing dsh, and installed applications compare that portable version. The publication stage treats an already complete public Release as read-only and never replaces its assets. Keyless policy fixtures cover the historical floor, multiple patches for one dsh version, incomplete future Releases, identity disagreement, and moved source provenance. A failed staging run can leave an isolated private Draft, which is safe to remove manually and does not block a later run.

The plugin can publish fixes independently and its Release does not appear as a desktop update because it has no portable ZIP asset. Before publication, its workflow repeats a clean installation through the exact compatible upstream source tag and commit. Release scripts contain the shared asset and identity checks; each workflow still supplies its own tag, name, body, prerelease policy, and Latest policy.
