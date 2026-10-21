# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- `make test` runs the test files at the same time
  where GNU parallel is installed,
  and with 16 CPUs or more the tests of each file too;
  CI runs its test files at the same time.
  It used to run the tests one by one,
  as `make test BATS_JOBS='--jobs 1'` still does.

## [3.0.0] - 2026-10-21

copy and past now follow the shell style of BMTLab,
and the move found five bugs, which this release fixes.
Before you upgrade, note three changes:
copy takes its arguments over stdin,
each message starts with `copy:` or `past:`,
and bash 4.4 or newer is needed.

### Added

- Exit code 70, `COPY_ERR_INTERNAL` and `PAST_ERR_INTERNAL`, for a bug.
  Run as programs, copy and past now stop at a failure
  that no exit code plans for,
  print its line and command on stderr, and exit 70.
  Before, they went on after such a failure.
- `copy --help` and `past --help` list the exit codes.

### Changed

- The arguments of copy win over stdin: copy reads stdin
  only when no text comes as arguments, as wl-copy does.
  stdin came first whenever it was no terminal,
  so in a script, in cron or in the shell of an AI agent,
  `copy 'text'` hung while stdin stayed open,
  or wrote an empty clipboard from /dev/null.
- Each message starts with the name of the tool, `copy:` or `past:`,
  no longer with `ERROR:`, and a second line says what to do next,
  such as `copy: unknown option: --bogus`, then `copy: see: copy --help`.
- copy and past need bash 4.4 or newer, no longer 4.3:
  run as programs, they turn on `shopt -s inherit_errexit`.
- `--help` names `COPY_PAST_BACKEND` under Settings,
  no longer under Environment.

### Fixed

- Sourced into an interactive shell, `copy TEXT` no longer ends the shell.
  copy handed the payload to its pipeline with `exec`,
  which took the stdin of the shell itself:
  the shell read the end of the file and quit right after copy.
- `copy TEXT` writes the words exactly, joined by spaces.
  With auto-detection, the default, it added a newline at the end,
  and `copy --no-auto TEXT` removed the newlines that the text ended with.
- `copy -- -n` writes `-n`, and so do `-e` and `-E`.
  copy wrote an empty clipboard, since `echo` took them for its own options.
- `copy --append` works through the links that `make install` makes.
  copy looked only for a `past.sh` beside the link,
  found none, and failed with exit 4.
- With the xsel backend, copy refuses an image that it detects
  with exit 5, `COPY_ERR_TYPE_MISMATCH`, and leaves the clipboard alone.
  It printed the error, then wrote an empty clipboard and exited 0.
- copy and past run with the first bash on PATH
  (`#!/usr/bin/env bash`), no longer with `/bin/bash`.
  On macOS, a bash from Homebrew now runs them,
  not the bash 3.2 of the system, which cannot run them.
- Sourced into a shell, copy and past no longer run
  a shell function or alias that has the name of a program they use,
  such as `cat`, `rm`, `sed` or `jq`, or of a backend.

## [2.0.1] - 2026-10-09

### Fixed

- `copy` no longer keeps its caller waiting.
  wl-copy and xclip leave a process behind
  that serves the clipboard until another program takes it,
  and that process held the output of `copy`,
  so `$(printf x | copy)`, a pipe into another command,
  or the shell tool of an AI agent waited
  for as long as the clipboard held the data.
  The backend now writes to output of its own,
  and its error messages still reach stderr.

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

[3.0.0]: https://github.com/BMTLab/copy-past/releases/tag/v3.0.0
[2.0.1]: https://github.com/BMTLab/copy-past/releases/tag/v2.0.1
[2.0.0]: https://github.com/BMTLab/copy-past/releases/tag/v2.0.0
[1.0.0]: https://github.com/BMTLab/copy-past/releases/tag/v1.0.0
