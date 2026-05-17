# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.4.0] - 2026-05-17

### Added

- `-j` short form on `copy` and `past`
  as an alias for `--json`.
- **Automatic MIME detection** on `copy`, always on by default:
    * Image magic bytes (PNG / JPEG / GIF / BMP / WebP)
      promote the MIME to `image/<format>`.
      These signatures cannot occur in plain text by design,
      so the detection is false-positive-free.
    * Payloads that begin with `{` or `[`
      and parse cleanly with `jq`
      promote the MIME to `application/json`.
      The JSON path is skipped silently when `jq` is not installed,
      because we cannot tell valid JSON
      from a similar-looking string without a real parser.
    * Auto-detection is suppressed when `--append` is in effect,
      because mixing the existing clipboard content
      with a new MIME would be misleading.
- `--no-auto` on `copy`
  to force `text/plain` regardless of the payload's shape.

### Changed

- `--json` / `-j` on `copy` no longer invokes `jq` for validation.
  The flag is treated as an explicit user statement
  and forwards `application/json` directly to the backend.
  The `jq`-validated path is reserved for the implicit auto-detection.

## [1.3.0] - 2026-05-17

### Added

- `--append` / `-a` on `copy`
  to concatenate new payload onto the existing clipboard content
  (text only).
- `--trim` on `copy`
  to remove leading and trailing whitespace before writing
  (text only).
- `--type MIME` on both `copy` and `past`
  to forward an explicit MIME type to the backend
  (Wayland `wl-copy --type`, X11 `xclip -t`).
- `--json` on both `copy` and `past`
  as a shortcut for `--type application/json`
  (implies `--raw` on `copy`).
- `--image[=FORMAT]` on both `copy` and `past`
  for binary image payloads.
  Accepts `png` (default), `jpg`/`jpeg`, `webp`, `gif`, `bmp`, `tiff`,
  `svg` (mapped to `image/svg+xml`),
  or any other format forwarded as `image/<format>`.
  Implies `--raw` on `copy`.
- `COPY_ERR_TYPE_MISMATCH` / `PAST_ERR_TYPE_MISMATCH` (rc=5)
  for incompatible option combinations
  (e.g. `--append --image`)
  and unsupported backend MIME types
  (e.g. `xsel + --json`).
- 22 new bats tests covering the additions.

### Fixed

- `copy` correctly propagates pipeline failures from the backend
  even when the prelude/payload pass through extra transformation
  stages (`--trim`, `--append`).

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

[1.4.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.4.0
[1.3.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.3.0
[1.2.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.2.0
[1.1.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.1.0
[1.0.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.0.0
