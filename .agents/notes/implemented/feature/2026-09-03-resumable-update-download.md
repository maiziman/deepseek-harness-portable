# Agent Note: Resumable update downloads

Status: implemented

English | [中文](2026-09-03-resumable-update-download.zh.md)

## Problem

The desktop updater always started the release ZIP download from byte zero. Closing the progress window, quitting the app, or a transient network failure threw away everything downloaded so far, and every retry began again — expensive for a multi-hundred-megabyte package on a slow connection.

## Decision

The updater keeps the download at a stable per-version path under `.cedardsh-update/<version>/work`, so a partial file survives app restarts, and stages attempts in one reusable directory instead of a new `run-*` temp directory each time. Downloads write to `<asset>.partial`; a kept partial resumes with an HTTP `Range: bytes=<offset>-` request that is reapplied across GitHub redirects. A resumed response must be a `206` whose `Content-Range` starts exactly at the offset and totals the published asset size; a `200` means the server ignored the Range and the transfer restarts from zero. The SHA-256 covers the whole file: on resume the existing prefix is hashed before appending, so the final digest still verifies the complete asset. Interrupted transfers keep the partial for the next attempt; only transfers that fail size or digest verification discard it. The progress window is now closable; closing it aborts the in-flight request, keeps the partial, and suppresses the failure dialog, and the next update shows and continues from the saved progress. A complete archive is reused across attempts with a digest sidecar guarding against re-published assets, and obsolete staging directories from other versions or older builds are removed when a new update starts.

## Alternatives considered

- Continuing the download in the background after the window closes hides failures and can restart the app without warning.
- Deleting the partial on interruption preserves the previous simplicity but repeats the full download cost.
- Storing a serialized hash state sidecar would avoid re-reading the prefix but depends on an unstable runtime format.
- Restarting the whole download whenever the server ignores the Range keeps the code smallest but misses the resume benefit on non-Range intermediaries.

## Consequences

Closing the progress window pauses rather than abandons the download; reopening the update resumes from the same byte offset, and the completed portion survives app restarts. GitHub redirects and CDN responses are validated per response, so resume cannot silently splice bytes from a different asset or size. Interrupted attempts leave bounded residue only under `.cedardsh-update`, which is removed on the next update or by the independent installer handoff.
