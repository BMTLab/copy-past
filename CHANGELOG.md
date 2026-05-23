# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0] - 2026-07-03

### Added

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
- `--type MIME` on both `copy` and `past`
  to forward an explicit MIME type to the backend
  (Wayland `wl-copy --type`, X11 `xclip -t`).
- `--json` / `-j` on both `copy` and `past`
  as a shortcut for `--type application/json`
  (implies `--raw` on `copy`).
  The flag is treated as an explicit user statement:
  it forwards `application/json` directly to the backend
  without invoking `jq`, so the `jq`-validated path
  stays reserved for the implicit auto-detection.
- `--image[=FORMAT]` on both `copy` and `past`
  for binary image payloads.
  Accepts `png` (default), `jpg`/`jpeg`, `webp`, `gif`, `bmp`, `tiff`,
  `svg` (mapped to `image/svg+xml`),
  or any other format forwarded as `image/<format>`.
  Implies `--raw` on `copy`.
- `--append` / `-a` on `copy`
  to concatenate new payload onto the existing clipboard content
  (text only).
- `--trim` on `copy`
  to remove leading and trailing whitespace before writing
  (text only).
- `--raw` / `-r` on `copy`
  to preserve ANSI escape sequences verbatim.
- ANSI/VT escape stripping by default,
  to keep GUI paste targets clean.
  Covers CSI (including private-mode sequences such as `ESC[?25h`),
  OSC sequences terminated by `ESC \` (ST),
  and short ESC controls (`ESC c`).
- `COPY_PAST_BACKEND` environment variable
  to force a specific clipboard backend
  (`wl-clipboard`, `xclip`, or `xsel`).
- `COPY_ERR_TYPE_MISMATCH` / `PAST_ERR_TYPE_MISMATCH` (rc=5)
  for incompatible option combinations
  (e.g. `--append --image`)
  and unsupported backend MIME types
  (e.g. `xsel + --json`).
- bats-core test suite covering hermetic and round-trip cases.
- GitHub Actions CI: lint, multi-OS tests, and signed releases.

### Fixed

- `copy` pipelines now run under `set -o pipefail`,
  so `sed` failures propagate
  instead of being hidden by the backend's exit code.
- `copy` correctly propagates pipeline failures from the backend
  even when the payload passes through extra transformation
  stages (`--trim`, `--append`).
- `past` no longer masks `wl-paste` failures
  through the trailing `printf x` sentinel
  (it now encodes the real exit code).
- `past` rejects unknown positional arguments
  with `PAST_ERR_USAGE` (rc=2)
  instead of silently ignoring them.

## [1.0.0] - 2025-11-19

### Added

- Initial public release.
- `copy` and `past` shell helpers
  with Wayland (`wl-clipboard`) and X11 (`xclip`/`xsel`) support.

[2.0.0]: https://github.com/BMTLab/copy-past/releases/tag/v2.0.0
[1.0.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.0.0
