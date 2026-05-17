# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-05-17

### Added

- `COPY_PAST_BACKEND` environment variable
  to force a specific clipboard backend
  (`wl-clipboard`, `xclip`, or `xsel`).
- `--raw` / `-r` flag on `copy`
  to preserve ANSI escape sequences verbatim.
- ANSI/VT escape stripping by default,
  covering CSI, OSC, and short ESC controls.
- bats-core test suite (59 tests across hermetic and round-trip cases).
- GitHub Actions CI: lint, multi-OS tests, and signed releases.

### Fixed

- `past` no longer masks `wl-paste` failures
  through the trailing `printf x` sentinel
  (now encodes the real exit code).
- `copy` pipelines now run under `set -o pipefail`,
  so `sed` failures propagate
  instead of being hidden by the backend's exit code.
- ANSI stripping handles private-mode CSI (`ESC[?25h`),
  short ESC controls (`ESC c`),
  and OSC sequences terminated by `ESC \` (ST).
- `past` rejects unknown positional arguments
  with `PAST_ERR_USAGE` (rc=2)
  instead of silently ignoring them.

## [1.1.0] - 2026-05-17

### Added

- Default ANSI escape stripping
  to keep GUI paste targets clean.

## [1.0.0] - 2025-11-19

### Added

- Initial public release.
- `copy` and `past` shell helpers
  with Wayland (`wl-clipboard`) and X11 (`xclip`/`xsel`) support.

[1.2.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.2.0
[1.1.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.1.0
[1.0.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.0.0
