# copy & past

[![CI](https://github.com/BMTLab/copy-past/actions/workflows/ci-main.yml/badge.svg)](https://github.com/BMTLab/copy-past/actions/workflows/ci-main.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)

Tiny, display-server‑agnostic clipboard helpers for the terminal.

> `copy` writes text to the system clipboard,
> and `past` prints the clipboard back to stdout.
> Together they form a Linux/Unix‑friendly alternative
> to macOS `pbcopy` / `pbpaste`,
> with transparent Wayland/X11 support.

---

## Features

* **Wayland & X11 support**

  * Wayland: uses `wl-copy` / `wl-paste` (from `wl-clipboard`).
  * X11: falls back to `xclip` or `xsel`.
* **GUI‑friendly by default**

  * ANSI escape sequences (colors, bold, etc.)
    are automatically stripped before writing to the clipboard.
  * Pasted text works correctly in any application:
    terminal, browser, editor, or messenger.
  * Use `--raw` (`-r`) to preserve escape codes
    for terminal‑to‑terminal workflows.
* **Stream‑friendly**

  * `copy` reads from stdin or command‑line arguments.
  * `past` writes directly to stdout with no extra newline.
* **Shell‑friendly API**

  * Designed to be called as plain executables
    **or** sourced as shell functions.
  * Exit codes are predictable and stable for scripting.
* **Zero Python/GUI dependencies**

  * Plain Bash + standard clipboard tools.
* **Works well in both desktop sessions and TTYs**

  * As long as a clipboard backend is available.
* **Backend override**

  * Set `COPY_PAST_BACKEND={wl-clipboard|xclip|xsel}`
    to force a specific backend.

> [!TIP]
> Think of them as `pbcopy` / `pbpaste` for Linux:
> `echo 'hello' | copy` and `echo "$(past)"`.

---

## Requirements

* POSIX‑like system (Linux, BSD, WSL with X/Wayland, etc.).
* **Bash** (the scripts rely on Bash features).
* At least one clipboard backend installed:

  * Wayland: [`wl-clipboard`](https://github.com/bugaevc/wl-clipboard) (`wl-copy`, `wl-paste`).
  * X11: `xclip` or `xsel`.

`copy` and `past` automatically detect the session type
via `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE`,
and pick the best available backend.

---

## Installation

Assuming you have cloned or downloaded the repository
that contains `copy.sh` and `past.sh`.

### Quick install (Makefile)

```bash
make install              # symlinks copy/past into /usr/local/bin (sudo)
make uninstall            # removes the symlinks
make install PREFIX=~/.local  # custom prefix
```

### Manual install

#### 1. Make the scripts executable

```bash
chmod +x copy.sh past.sh
```

#### 2. Install on your `$PATH`

You can either **rename** the scripts
or create **symlinks**
to expose short command names (`copy` and `past`).

##### Option A: rename and move

```bash
mv copy.sh copy
mv past.sh past
chmod +x copy past
sudo mv copy past /usr/local/bin/
```

##### Option B: symlink from your project directory

```bash
chmod +x /path/to/copy.sh /path/to/past.sh
ln -s /path/to/copy.sh /usr/local/bin/copy
ln -s /path/to/past.sh /usr/local/bin/past
```

Make sure `/usr/local/bin` is listed in your `$PATH`.

> [!TIP]
> You can also `source` the scripts in your `~/.bashrc`
> and use the functions directly:
>
> ```bash
> source /path/to/copy.sh
> source /path/to/past.sh
> ```

---

## Quick start

With the commands available as `copy` and `past`:

```bash
# Copy literal text
copy 'Hello from the terminal!'

# Copy current working directory path
pwd | copy

# Copy colored command output (colors are stripped automatically)
ls --color=always | copy

# Paste clipboard content into the terminal
past

# Use clipboard content inside another command
cd "$(past)"
```

<img width="877" height="388" alt="Screenshot_20251123_175944" src="https://github.com/user-attachments/assets/03ec4386-4a83-42e7-93fe-d4f1f5d0dee6" />

> [!NOTE]
> Both tools operate on the **CLIPBOARD** selection
> (the one that survives between apps),
> not the primary X11 selection.

---

## `copy` — write to clipboard

`copy` takes text from **stdin** or from **arguments**,
and writes it to the system clipboard.

### Syntax

```bash
copy [options] [text...]

# or

echo 'text' | copy
```

If data is piped in via stdin,
that stream **takes precedence** over any arguments.

### Options

| Option         | Description                                              |
| -------------- | -------------------------------------------------------- |
| `-h`, `--help` | Show inline help and exit.                               |
| `-r`, `--raw`  | Preserve ANSI escape sequences (do not strip colors).    |
| `--`           | End of options; treat remaining arguments as text input. |

### Behaviour

* **ANSI stripping (default)**

  By default, `copy` removes ANSI escape sequences
  (colors, bold, underline, cursor movement)
  before writing to the clipboard.
  This ensures that Ctrl+V in GUI applications
  (browsers, editors, messengers)
  produces clean, readable text.

  ```bash
  # Colored ls output → clean file list in clipboard
  ls --color=always /etc | copy

  # cdl output → clean listing in clipboard
  cdl ~/projects | copy
  ```

  To preserve escape codes
  (e.g. for pasting back into a terminal),
  use `--raw`:

  ```bash
  ls --color=always | copy --raw
  ```

* **Pipe mode (recommended for scripts)**

  ```bash
  echo 'some text' | copy
  journalctl -n 100 | copy
  ```

  `copy` reads stdin until EOF,
  and passes it (after ANSI stripping) to the backend tool.
  It does **not** append a newline on its own.

* **Argument mode (interactive convenience)**

  ```bash
  copy Hello world
  copy 'line 1' 'line 2'
  ```

  Arguments are joined with single spaces (similar to `echo "$*"`).
  The result is then sent to the backend.

### Exit codes

| Code | Constant                  | Meaning                                                |
| ---- | ------------------------- | ------------------------------------------------------ |
| `0`  | -                         | Success.                                               |
| `1`  | `COPY_ERR_GENERAL`        | Generic error.                                         |
| `2`  | `COPY_ERR_USAGE`          | Invalid usage, unknown option, or unknown backend.     |
| `3`  | `COPY_ERR_NO_BACKEND`     | No suitable clipboard utility found.                   |
| `4`  | `COPY_ERR_BACKEND_FAILED` | Backend tool (or ANSI-strip stage) returned non‑zero.  |

> [!IMPORTANT]
> When copying **secrets** (tokens, passwords),
> prefer **pipe mode**: `printf '%s' "$TOKEN" | copy`.
> Passing secrets as arguments (e.g. `copy my-secret`)
> may leak them into shell history and process lists.

---

## `past` — read from clipboard

`past` prints the current clipboard contents to stdout,
without altering it.

### Syntax

```bash
past
past --help
```

Typical patterns:

```bash
# Save clipboard to a file
past > clipboard.txt

# Use clipboard in a command substitution
echo "Clipboard: $(past)"

# Pipe clipboard through another tool
past | jq .
```

### Options

| Option         | Description                |
| -------------- | -------------------------- |
| `-h`, `--help` | Show inline help and exit. |

### Behaviour

* Uses the same backend selection logic as `copy`:

  * `wl-paste` on Wayland
    (with a workaround for the `--no-newline` bug in wl-clipboard ≤ 2.2.1).
  * `xclip -selection clipboard -out`
    or `xsel --clipboard --output` on X11.
* Does **not** append any trailing newline
  beyond what is already in the clipboard.

### Exit codes

| Code | Constant                  | Meaning                              |
| ---- | ------------------------- | ------------------------------------ |
| `0`  | -                         | Success.                             |
| `1`  | `PAST_ERR_GENERAL`        | Generic error.                       |
| `2`  | `PAST_ERR_USAGE`          | Invalid usage or unknown backend.    |
| `3`  | `PAST_ERR_NO_BACKEND`     | No suitable clipboard utility found. |
| `4`  | `PAST_ERR_BACKEND_FAILED` | Backend tool returned non‑zero.      |

---

## Backend override

Both scripts honour the `COPY_PAST_BACKEND` environment variable.
Set it to `wl-clipboard`, `xclip`, or `xsel`
to bypass auto-detection
and force a specific backend.

```bash
# Force xclip even on a Wayland session
COPY_PAST_BACKEND=xclip ls | copy

# Persistent override for a shell session
export COPY_PAST_BACKEND=wl-clipboard
```

Unknown values are rejected
with `COPY_ERR_USAGE` / `PAST_ERR_USAGE` (exit code 2).

---

## Using `copy` and `past` together

Because both tools talk to the same clipboard,
they combine well:

```bash
# Copy some text
printf 'some text' | copy

# Paste it back into another command
printf 'You copied: %s\n' "$(past)"

# Round-trip through a transformation
past | tr 'a-z' 'A-Z' | copy

# Yank a path once and reuse it many times
ls | fzf | copy     # choose a path
cd "$(past)"        # jump there later

# Copy colored output, paste clean text in GUI
cdl ~/projects | copy
# Now Ctrl+V in any app gives you a clean directory listing
```

You can also integrate them into aliases or shell functions,
for example:

```bash
alias cpath='pwd | copy'
alias pp='echo "$(past)"'
```

---

## Troubleshooting

* **"No clipboard backend found"**

  * Install one of:

    * Wayland: `wl-clipboard` (`wl-copy`, `wl-paste`).
    * X11: `xclip` or `xsel`.
  * Make sure the tools are in your `$PATH`.

* **Pasted text contains garbage characters (e.g. `[31m`)**

  * You are likely using `copy --raw`,
    or an older version without ANSI stripping.
  * Run `copy` without `--raw`
    to strip escape sequences automatically.

* **Last line missing from clipboard**

  * This is a known bug in `wl-clipboard ≤ 2.2.1` with `--no-newline`.
  * `past` includes a workaround,
    so no action is needed on your part.

* **Running over SSH**

  * Clipboard access usually targets the **remote** display/session.
    You may need extra configuration
    (X11 forwarding, Wayland remoting,
    or an SSH tunnel to a local clipboard service).

* **Clipboard managers (KDE Klipper, GNOME, etc.)**

  * These tools work fine alongside clipboard managers:
    they simply populate the CLIPBOARD selection,
    which managers then track.

---

## Development & testing

The project ships a [bats-core](https://bats-core.readthedocs.io/) test suite
that exercises both scripts
against a hermetic fake clipboard backend
(no real clipboard is touched).

```bash
make test             # run the full bats suite
make lint             # shellcheck on copy.sh / past.sh
make format           # apply shfmt formatting in-place
make check            # lint + test (CI gate)
```

Required dev tools:

* `bats` (≥ 1.5.0)
* `shellcheck`
* `shfmt`
* `xxd` (used by tests for byte-level fidelity checks)

Test layout:

```
tests/bats/
├── test_helper.bash       # shared fake-backend setup
├── test_copy.bats         # copy.sh behaviour, options, errors
├── test_past.bats         # past.sh behaviour, errors
├── test_roundtrip.bats    # copy → past byte-fidelity
├── test_robustness.bats   # regression tests for v1.2.0 fixes
└── test_code_style.bats   # shellcheck / shfmt / header checks
```

---

## License & disclaimer

This project is licensed under the [MIT License](./LICENSE).

> [!NOTE]
> The scripts are provided **as is**,
> without any warranty of correctness
> or fitness for a particular purpose.
> Always verify clipboard contents in security‑sensitive workflows.

---

## Contributing

Issues and pull requests are welcome.
If you propose enhancements (new flags, additional backends, etc.),
please include concrete examples and a short rationale,
so the tools stay small, focused,
and easy to reason about :innocent:

### Commit message format

This project uses
[Conventional Commits](https://www.conventionalcommits.org/)
together with
[release-please](https://github.com/googleapis/release-please)
to automate versioning and changelog generation.Common prefixes:

- `feat: …` — new user-visible behaviour (minor bump)
- `fix: …` — bug fix (patch bump)
- `feat!: …` or `BREAKING CHANGE:` in body — major bump
- `chore: …`, `docs: …`, `refactor: …` — no version bump

When commits with `feat:` / `fix:` reach `main`,
release-please opens a PR with an updated `CHANGELOG.md`
and bumped `Version:` headers in `copy.sh` / `past.sh` / `Makefile`.
Merging that PR creates a `vX.Y.Z` git tag,
which triggers the release workflow:
the tarball is built, signed via sigstore,
and attached to the auto-generated GitHub Release.

#### Repo setup checklist (one-time)

For the release automation to work end-to-end,
the following has to be configured in the GitHub UI:

* **Settings → Actions → General → Workflow permissions:**
  enable **"Allow GitHub Actions to create and approve pull requests"**.
  Without this flag,
  release-please cannot open the release PR
  even though the workflow YAML grants `pull-requests: write`.
* **Settings → Secrets and variables → Actions:**
  add `RELEASE_PLEASE_TOKEN`
  (a fine-grained PAT or a GitHub App installation token
  with `Contents: write` + `Pull requests: write` on this repo).
  Without this secret the action falls back to `GITHUB_TOKEN`,
  which can still open the PR and create the tag,
  but the tag push will not trigger the build pipeline
  (GitHub deliberately blocks recursion for default-token tags).
