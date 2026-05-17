# copy & past

[![CI](https://github.com/BMTLab/copy-past/actions/workflows/ci-main.yml/badge.svg)](https://github.com/BMTLab/copy-past/actions/workflows/ci-main.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Tiny, display-server-agnostic clipboard helpers for the terminal.
Linux/Unix-friendly alternative to macOS `pbcopy` / `pbpaste`,
with transparent Wayland/X11 support
and smart MIME-type detection out of the box.

```bash
echo 'hello' | copy             # write to clipboard
past                            # read from clipboard
cat data.json | copy            # detected as application/json (jq parses it)
cat picture.png | copy          # detected as image/png (magic bytes)
ls --color=always | copy        # ANSI codes stripped automatically
```

> [!TIP]
> Think of them as `pbcopy` / `pbpaste` for Linux:
> `echo 'hello' | copy` and `echo "$(past)"`.

---

## Features

| | |
|---|---|
| 🖥️ **Wayland & X11** | `wl-clipboard`, `xclip`, or `xsel` (auto-detected) |
| 🎨 **GUI-friendly** | ANSI escape codes stripped before writing |
| 🤖 **Smart MIME detection** | Auto-recognises JSON (via `jq`) and PNG/JPEG/GIF/BMP/WebP |
| 🔒 **Predictable** | Stable exit codes, well-defined error paths |
| 🧪 **Hermetic test suite** | 90+ bats tests, no real clipboard touched in CI |
| 📦 **Zero dependencies** | Plain Bash + your existing clipboard backend |

---

## Requirements

* POSIX-like system (Linux, BSD, WSL with X/Wayland).
* **Bash** 4.3 or newer.
* At least one clipboard backend:
  * Wayland: [`wl-clipboard`](https://github.com/bugaevc/wl-clipboard)
  * X11: `xclip` or `xsel`
* Optional: `jq` (enables automatic JSON detection).

---

## Installation

```bash
make install                       # symlinks into /usr/local/bin (sudo)
make install PREFIX=~/.local       # user-local install
make uninstall                     # remove symlinks
```

Or do it by hand:

```bash
chmod +x copy.sh past.sh
sudo ln -s "$PWD/copy.sh" /usr/local/bin/copy
sudo ln -s "$PWD/past.sh" /usr/local/bin/past
```

You can also `source` them in your `~/.bashrc`
to use `copy` and `past` as shell functions.

---

## Quick start

```bash
# ─── Text ────────────────────────────────────────────
copy 'Hello world'                  # argument mode
pwd | copy                          # pipe mode
ls --color=always | copy            # colors stripped automatically
ls --color=always | copy --raw      # keep ANSI codes
echo '  spaced  ' | copy --trim     # strip surrounding whitespace
date | copy --append                # append to existing clipboard

# ─── JSON ────────────────────────────────────────────
cat data.json | copy                # auto-detected (needs jq)
cat data.json | copy --json         # explicit, skips jq parsing
echo '{"looks": "like JSON"}' \
  | copy --no-auto                  # force text/plain

# ─── Images ──────────────────────────────────────────
cat picture.png | copy              # auto-detected as image/png
grim -g "$(slurp)" - | copy         # screenshot in clipboard
past --image > screenshot.png       # save image from clipboard

# ─── Reading ─────────────────────────────────────────
past                                # print to stdout
cd "$(past)"                        # use clipboard inline
past | jq .                         # pipe to another tool
```

<img width="877" height="388" alt="Screenshot_20251123_175944" src="https://github.com/user-attachments/assets/03ec4386-4a83-42e7-93fe-d4f1f5d0dee6" />

> [!NOTE]
> Both tools use the **CLIPBOARD** selection
> (the one that survives between apps),
> not the X11 PRIMARY selection.

---

## Reference

### `copy`: write to clipboard

```
copy [options] [text...]
echo 'text' | copy
```

When stdin is piped in,
it takes precedence over arguments.

#### Options

| Option              | Description                                              |
| ------------------- | -------------------------------------------------------- |
| `-h`, `--help`      | Show inline help and exit.                               |
| `-r`, `--raw`       | Preserve ANSI escape sequences.                          |
| `-a`, `--append`    | Append to the existing clipboard content (text only).    |
| `--trim`            | Trim leading/trailing whitespace (text only).            |
| `--type MIME`       | Set the clipboard MIME type explicitly.                  |
| `-j`, `--json`      | Shortcut for `--type application/json --raw`.            |
| `--image[=FORMAT]`  | Copy binary image data; default `png`.                   |
| `--no-auto`         | Disable automatic MIME detection.                        |
| `--`                | End of options; remaining arguments are text.            |

#### Automatic MIME detection

`copy` inspects the first bytes of the payload by default:

* **PNG / JPEG / GIF / BMP / WebP** are detected by magic bytes.
  These signatures cannot occur in plain text by design,
  so the detection has no false-positive risk.
* **JSON** is detected when the payload starts with `{` or `[`
  **and** parses cleanly with `jq`.
  Without `jq` the JSON path is skipped silently.
* Anything else is copied as plain text.

An explicit `--type` / `--json` / `--image`
always wins over auto-detection,
and `--no-auto` disables it entirely.

> [!IMPORTANT]
> When copying **secrets** (tokens, passwords),
> prefer pipe mode: `printf '%s' "$TOKEN" | copy`.
> Passing secrets as arguments may leak them
> into shell history and process lists.

#### Exit codes

| Code | Constant                  | Meaning                                          |
| ---- | ------------------------- | ------------------------------------------------ |
| `0`  | (none)                    | Success.                                         |
| `1`  | `COPY_ERR_GENERAL`        | Generic error.                                   |
| `2`  | `COPY_ERR_USAGE`          | Invalid usage or unknown option.                 |
| `3`  | `COPY_ERR_NO_BACKEND`     | No suitable clipboard utility found.             |
| `4`  | `COPY_ERR_BACKEND_FAILED` | Backend tool returned non-zero.                  |
| `5`  | `COPY_ERR_TYPE_MISMATCH`  | Incompatible options or unsupported MIME type.   |

### `past`: read from clipboard

```
past [options]
```

Prints clipboard contents to stdout, without altering them.
Does not append a trailing newline beyond what is already there.

#### Options

| Option              | Description                                       |
| ------------------- | ------------------------------------------------- |
| `-h`, `--help`      | Show inline help and exit.                        |
| `--type MIME`       | Request a specific MIME type from the backend.    |
| `-j`, `--json`      | Shortcut for `--type application/json`.           |
| `--image[=FORMAT]`  | Read binary image data; default `png`.            |

#### Exit codes

| Code | Constant                  | Meaning                                          |
| ---- | ------------------------- | ------------------------------------------------ |
| `0`  | (none)                    | Success.                                         |
| `1`  | `PAST_ERR_GENERAL`        | Generic error.                                   |
| `2`  | `PAST_ERR_USAGE`          | Invalid usage or unknown argument.               |
| `3`  | `PAST_ERR_NO_BACKEND`     | No suitable clipboard utility found.             |
| `4`  | `PAST_ERR_BACKEND_FAILED` | Backend tool returned non-zero.                  |
| `5`  | `PAST_ERR_TYPE_MISMATCH`  | Backend cannot handle the requested MIME type.   |

---

## Backend override

Both scripts honour the `COPY_PAST_BACKEND` environment variable:

```bash
COPY_PAST_BACKEND=xclip ls | copy        # one-shot override
export COPY_PAST_BACKEND=wl-clipboard    # whole shell session
```

Accepted values: `wl-clipboard` (or `wayland`), `xclip`, `xsel`.
Unknown values fail with `COPY_ERR_USAGE` / `PAST_ERR_USAGE`.

> [!NOTE]
> `xsel` does not support MIME types,
> so non-text payloads (`--json`, `--image`)
> need `wl-clipboard` or `xclip`.

---

## Recipes

```bash
# Round-trip transformation
past | tr 'a-z' 'A-Z' | copy

# Yank from fzf, jump to it later
ls | fzf | copy
cd "$(past)"

# Save clipboard image to a file
past --image > clipboard.png

# Append output of multiple commands
grep ERROR app1.log | copy
grep ERROR app2.log | copy --append
past > all-errors.log

# Useful aliases
alias cpath='pwd | copy'
alias cline='copy < /dev/stdin'
```

---

## Troubleshooting

**No clipboard backend found**
Install one of `wl-clipboard`, `xclip`, or `xsel`,
and make sure it is on `$PATH`.

**Pasted text contains garbage like `[31m`**
You are likely passing `--raw` or relying on an older release.
Drop the flag: `copy` strips ANSI codes by default.

**Last line missing from clipboard**
Known bug in `wl-clipboard ≤ 2.2.1` with `--no-newline`.
`past` ships a workaround; no action needed on your side.

**Running over SSH**
Clipboard access targets the remote session by default.
For local clipboard, configure X11 forwarding,
Wayland remoting, or an SSH tunnel
to a local clipboard service.

---

## Development

```bash
make check         # lint + format-check + tests (CI gate)
make test          # bats suite only
make lint          # shellcheck only
make format        # rewrite scripts with shfmt
make check-deps    # show runtime + dev tooling status
```

Test layout:

```
tests/bats/
├── test_helper.bash       # shared fake-backend setup
├── test_copy.bats         # copy options & error paths
├── test_past.bats         # past options & error paths
├── test_features.bats     # append / trim / json / image / auto-detect
├── test_roundtrip.bats    # copy → past byte-fidelity
├── test_robustness.bats   # regression tests
└── test_code_style.bats   # shellcheck / shfmt / header gate
```

See [CONTRIBUTING.md](./CONTRIBUTING.md) for the code style,
commit conventions, and release process.

---

## License

[MIT](./LICENSE).

The scripts are provided **as is**, without warranty of any kind.
Always verify clipboard contents in security-sensitive workflows.
