# Contributing

Contributions are welcome—bug reports, documentation improvements, tests and code changes all help.

## Issues, forks and pull requests

Open an issue in this repository to describe a bug or discuss an idea. Include reproducible steps and the relevant versions, using synthetic examples. For a larger change, discussing the scope first can avoid unnecessary work.

Fork the project and send a focused pull request when you would like to contribute upstream. Explain what changed, why, how you checked it and any remaining limitations. Forking or modifying the project does not require submitting a pull request; follow the license's applicable conditions.

## Development checks

Read [AGENTS.md](AGENTS.md) and the [architecture](docs/architecture.md), especially before changing tool contracts, consent, recovery, audit or trust boundaries. Update the relevant documentation with the change.

```sh
./scripts/test-native
python3 -m unittest discover -s Tests -v
```

The native runner defaults to eight workers and full stress coverage. See [test options and compatibility fixtures](docs/setup.md#2-build-sign-and-test-a-fresh-installation) for focused development and strict release checks.

Use synthetic providers and private temporary state. Do not include credentials, environment files, private logs, account/event identifiers or personal Calendar data in issues, commits or pull requests. Tests and builds do not authorize real Calendar access or permission prompts. Live writes need a separately scoped request, an exact identified change and the normal host/native consent checks.

Do not run `scripts/build-helper.sh` unless you intentionally need packaging: it replaces the local app bundle, and a changed signature can reset an existing Calendar grant. Preserve a settled installation during ordinary development.

## Contribution license

By submitting a contribution, you confirm that you have the right to contribute it and agree to license it under the project's [GNU AGPL version 3 only](LICENSE) (`AGPL-3.0-only`). You retain copyright in your work; no copyright assignment or separate contributor license agreement is required. Preserve existing notices and identify the origin and license of any third-party material.
