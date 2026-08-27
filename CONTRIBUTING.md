# Contributing

Thanks for helping make DeepSeek Harness easier to run on Windows. This repository owns the portable packaging, Electron shell, build scripts, and clean-machine verification; product behavior inside DeepSeek Harness belongs in the [upstream repository](https://github.com/deepseek-ai/deepseek-harness).

## Report a problem

Use the issue templates and include:

- Windows edition, version, and x64 architecture confirmation;
- the complete ZIP filename and `dshVersion` from `manifest.json`;
- exact steps to reproduce the problem and the observed result;
- whether the problem reproduces after extracting to a short local path;
- relevant output from `verify-package.ps1` or `dsh-home\logs\server.log`.

Remove API keys, credentials, workspace content, usernames, and private paths from every log or screenshot before posting it.

## Develop locally

```powershell
.\build-portable.ps1
.\verify-package.ps1
```

Keep changes focused. User-visible behavior updates must update both `README.md` and `README.zh.md` when the instructions or guarantees change. Build-pipeline changes must update both files under `docs/BUILDING*`.

## Pull request checklist

- Explain the user problem and the resulting behavior.
- Add or update the smallest verification that covers the change.
- Run the build or verification path affected by the change.
- Check `git diff --check` before submitting.
- Never commit ZIPs, build caches, logs, API keys, or extracted profiles.

By contributing, you agree that your contribution is licensed under this repository's [MIT License](LICENSE).
