# Contributing to copy-past

Thanks for your interest in improving `copy` and `past`.
This document covers everything maintainers and contributors need:
local development, code style, commit conventions,
and how releases are cut.

## Quick links

* [Code style](#code-style)
* [Local workflow](#local-workflow)
* [Tests](#tests)
* [Commit conventions](#commit-conventions)
* [Pull requests](#pull-requests)
* [Release process](#release-process)
* [Repository setup checklist](#repository-setup-checklist)
* [Reporting bugs](#reporting-bugs)

---

## Code style

The shared code style for the whole BMTLab `ScriptsLib` workspace
lives at [`.kiro/steering/code-style.md`](../.kiro/steering/code-style.md).
It is the single source of truth.

The most load-bearing rules:

* **English (en-US) only** in code, comments, docstrings, and log messages.
* **Single quotes by default**. Double quotes only when interpolation is needed.
* **No em-dash** (`—`, U+2014) anywhere. Use a colon followed by a space.
* `local -r` for read-only strings, `local -i` for integers, `local -ir` for both.
* Functions are declared as `function name() { ... }`, never bare `name() { ... }`.
* Errors go through the project helpers (`__cp_error`, `__ps_error`),
  return named exit-code constants, and never use magic numbers.
* Strict mode: every script and every CI run-block starts with
  `set -o errexit -o nounset -o pipefail`.
* Tests follow the **Arrange / Act / Assert** pattern
  with explicit `# Arrange`, `# Act`, `# Assert` comments.
* Long files use `# region Name` / `# endregion` markers for IDE folding
  (the `Makefile` keeps `# ─── ───` ASCII rules instead).

Mechanical formatting (line endings, indent, charset) lives in `.editorconfig`.

---

## Local workflow

Clone, install dependencies, and verify the suite:

```bash
git clone https://github.com/BMTLab/copy-past.git
cd copy-past
make check-deps       # show runtime + dev tooling status
make check            # lint + format-check + bats tests (CI gate)
```

Useful targets:

| Target              | What it does                                            |
| ------------------- | ------------------------------------------------------- |
| `make test`         | bats suite only.                                        |
| `make lint`         | shellcheck on `*.sh` and `tests/bats/*.bats`.           |
| `make format`       | rewrite scripts in place via `shfmt -i 2 -ci -bn`.      |
| `make format-check` | same as above, but fails on diffs (used in CI).         |
| `make install`      | symlink `copy.sh` and `past.sh` into `$(PREFIX)/bin`.   |
| `make uninstall`    | remove the symlinks.                                    |
| `make info`         | print resolved variables (PREFIX, INSTALL_MODE, etc.).  |

Required tools for a clean local run:
`bash 4.3+`, `bats-core`, `shellcheck`, `shfmt`.
`make check-deps` reports each one's status.

### Workflow linting

Workflow files are checked with [`actionlint`](https://github.com/rhysd/actionlint).
The CI runs it via `reviewdog`, but locally Docker is the easiest path:

```bash
docker run --rm -v "$PWD:/repo" -w /repo rhysd/actionlint:latest
```

---

## Tests

The bats suite is hermetic by default:
no real clipboard backend is touched.
`tests/bats/test_helper.bash` injects fake `wl-copy` / `wl-paste` /
`xclip` / `xsel` binaries on `PATH`,
so tests can run on any CI runner without GUI.

Layout:

```
tests/bats/
├── test_helper.bash       # shared fake-backend setup
├── test_copy.bats         # copy options & error paths
├── test_past.bats         # past options & error paths
├── test_features.bats     # append / trim / json / image / auto-detect
├── test_roundtrip.bats    # copy → past byte fidelity
├── test_robustness.bats   # regression tests
└── test_code_style.bats   # shellcheck / shfmt / header gate
```

When you fix a bug, add a regression test in `test_robustness.bats`.
When you add a feature, extend `test_features.bats`
and update the existing `test_copy.bats` / `test_past.bats`
to cover the new option.

> [!IMPORTANT]
> Always `unset COPY_PAST_BACKEND` before running the suite.
> If it leaks from your shell, hermetic tests can pick the wrong backend.

---

## Commit conventions

This project uses [Conventional Commits](https://www.conventionalcommits.org/).
`release-please` parses the commit history
to compute the next semver bump and regenerate the changelog,
so the prefixes are load-bearing:

| Prefix              | Bump  | Use when                                     |
| ------------------- | ----- | -------------------------------------------- |
| `feat: ...`         | minor | a user-visible feature is added.             |
| `fix: ...`          | patch | a user-visible bug is fixed.                 |
| `feat!: ...`        | major | the change breaks compatibility.             |
| `BREAKING CHANGE:`  | major | footer marking a breaking change.            |
| `docs: ...`         | none  | docs-only changes.                           |
| `chore: ...`        | none  | tooling, build, or repo housekeeping.        |
| `refactor: ...`     | none  | internal refactoring with no behavior change.|
| `test: ...`         | none  | test-only changes.                           |
| `ci: ...`           | none  | CI configuration changes.                    |

Examples:

```
feat(copy): add --trim and --append flags
fix(past): propagate wl-paste exit code through the sentinel trick
docs: clarify automatic MIME detection in README
```

Keep the subject under 72 characters and write it in the imperative mood.

---

## Pull requests

1. Branch off `main` (`git switch -c feat/your-change`).
2. Add tests when changing behavior.
3. Run `make check`. CI mirrors the same gate, so a green local run
   should land green upstream.
4. Open the PR against `main` and fill in the template.
5. Keep the title in Conventional Commits style:
   it becomes the squash-merge commit subject and feeds release-please.

Reviewers will look at:

* tests covering the change,
* docs (`README.md`, `CHANGELOG.md` is automated),
* code style adherence,
* CI workflow status.

---

## Release process

Releases are fully automated by
[`release-please`](https://github.com/googleapis/release-please)
and a follow-up signed-tarball job.

1. Land Conventional Commits on `main` through PRs.
2. The `ci-release-please.yml` workflow opens (or refreshes)
   a "Release PR" that bumps the version
   in `copy.sh`, `past.sh`, `Makefile`,
   and `.release-please-manifest.json`
   (the version markers are
   `# x-release-please-version` and `# x-release-please-major`),
   and updates `CHANGELOG.md`.
3. Reviewers approve and merge the Release PR.
4. release-please tags `vX.Y.Z` and creates a GitHub Release.
5. The `ci-release.yml` workflow is triggered by the tag,
   builds a tarball, computes the SHA-256,
   attaches a SLSA build provenance attestation
   via `actions/attest-build-provenance@v4`,
   and uploads everything to the GitHub Release.

You never edit `CHANGELOG.md` or bump versions by hand.
If something looks off, fix the offending commit message
or open a `chore: release vX.Y.Z` PR with manual edits.

---

## Repository setup checklist

A maintainer setting up a fresh fork or mirror needs to enable a few
GitHub features so the automation can do its job:

1. **Workflow permissions**
   `Settings → Actions → General → Workflow permissions`:
   * Select **Read and write permissions**.
   * Enable **Allow GitHub Actions to create and approve pull requests**.

2. **Release-please token (optional but recommended)**
   The default `GITHUB_TOKEN` works,
   but its commits do not retrigger downstream workflows.
   To make the Release PR retrigger CI on push:
   * Create a fine-grained PAT with `contents: write` and `pull-requests: write`.
   * Add it as the `RELEASE_PLEASE_TOKEN` repository secret.
   * The `ci-release-please.yml` workflow already prefers it
     when present and falls back to `GITHUB_TOKEN` otherwise.

3. **Branch protection on `main`**
   Require the `CI / lint`, `CI / test`, and `CI / workflow-lint` checks
   to pass before merge.

4. **Dependabot**
   `dependabot.yml` is committed and bumps GitHub Actions weekly.
   No extra setup is required.

5. **Attestations**
   Build provenance attestations are produced automatically by
   `ci-release.yml` using
   [`actions/attest-build-provenance`](https://github.com/actions/attest-build-provenance).
   They are visible on the GitHub Release page
   and verifiable with `gh attestation verify`.

---

## Reporting bugs

Use the [issue tracker](https://github.com/BMTLab/copy-past/issues).
Great bug reports include:

* a one-line summary,
* steps to reproduce (with sample input/output),
* expected vs. actual behavior,
* OS, display server (Wayland/X11), and clipboard backend,
* output of `bash --version` and the relevant tool's `--version`.

For security-sensitive reports, please follow [`SECURITY.md`](./SECURITY.md)
instead of opening a public issue.

---

## License

By contributing, you agree that your contributions will be licensed
under the project's [MIT License](./LICENSE).
