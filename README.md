# copy & past

Tiny, display-server‑agnostic clipboard helpers for the terminal.

> `copy` writes text to the system clipboard, and `past` prints the clipboard back to stdout. 
> Together they form a Linux/Unix‑friendly alternative to macOS `pbcopy` / `pbpaste`, with transparent Wayland/X11 support.

---

## Features

* **Wayland & X11 support**

  * Wayland: uses `wl-copy` / `wl-paste` (from `wl-clipboard`).
  * X11: falls back to `xclip` or `xsel`.
* **Stream‑friendly**

  * `copy` reads from stdin or command‑line arguments.
  * `past` writes directly to stdout with no extra newline.
* **Shell‑friendly API**

  * Designed to be called as plain executables **or** sourced as shell functions.
  * Exit codes are predictable and stable for scripting.
* **Zero Python/GUI dependencies**

  * Plain Bash + standard clipboard tools.
* **Works well in both desktop sessions and TTYs**

  * As long as a clipboard backend is available.

> [!TIP]
> Think of them as `pbcopy` / `pbpaste` for Linux: `echo 'hello' | copy` and `echo "$(past)"`.

---

## Requirements

* POSIX‑like system (Linux, BSD, WSL with X/Wayland, etc.).
* **Bash** (the scripts rely on Bash features).
* At least one clipboard backend installed:

  * Wayland: [`wl-clipboard`](https://github.com/bugaevc/wl-clipboard) (`wl-copy`, `wl-paste`).
  * X11: `xclip` or `xsel`.

`copy` and `past` automatically detect the session type via `WAYLAND_DISPLAY` / `XDG_SESSION_TYPE` and pick the best available backend.

---

## Installation

Assuming you have cloned or downloaded the repository containing `copy.sh` and `past.sh`.

### 1. Make the scripts executable

```bash
chmod +x copy.sh past.sh
```

### 2. Install on your `$PATH`

You can either **rename** the scripts or create **symlinks** to expose short command names (`copy` and `past`).

#### Option A: rename and move

```bash
mv copy.sh copy
mv past.sh past
chmod +x copy past
sudo mv copy past /usr/local/bin/
```

#### Option B: symlink from your project directory

```bash
chmod +x /path/to/copy.sh /path/to/past.sh
ln -s /path/to/copy.sh /usr/local/bin/copy
ln -s /path/to/past.sh /usr/local/bin/past
```

Make sure `/usr/local/bin` is listed in your `$PATH`.

> [!TIP]
> You can also `source` the scripts in your `~/.bashrc` and use the functions directly:
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

# Paste clipboard content into the terminal
past

# Use clipboard content inside another command
cd "$(past)"
```

<img width="877" height="388" alt="Screenshot_20251123_175944" src="https://github.com/user-attachments/assets/03ec4386-4a83-42e7-93fe-d4f1f5d0dee6" />


> [!NOTE]
> Both tools operate on the **CLIPBOARD** selection (the one that survives between apps), not the primary X11 selection.

---

## `copy` - write to clipboard

`copy` takes text from **stdin** or from **arguments** and writes it to the system clipboard.

### Syntax

```bash
copy [text...]

# or

echo 'text' | copy
```

If data is piped in via stdin, that stream **takes precedence** over any arguments.

### Options

| Option         | Description                |
| -------------- | -------------------------- |
| `-h`, `--help` | Show inline help and exit. |

### Behaviour

* **Pipe mode (recommended for scripts)**

  ```bash
  echo 'some text' | copy
  journalctl -n 100 | copy
  ```

  `copy` reads stdin until EOF and passes it verbatim to the backend tool. It does **not** append a newline on its own.

* **Argument mode (interactive convenience)**

  ```bash
  copy Hello world
  copy 'line 1' 'line 2'
  ```

  Arguments are joined with single spaces (similar to `echo "$*"`). The result is then sent to the backend.

### Exit codes

* `0` - success.
* `1` - `COPY_ERR_GENERAL` - generic error.
* `2` - `COPY_ERR_USAGE` - invalid usage / no input provided.
* `3` - `COPY_ERR_NO_BACKEND` - no suitable clipboard utility found.
* `4` - `COPY_ERR_BACKEND_FAILED` - backend tool returned non‑zero.

> [!IMPORTANT]
> When copying **secrets** (tokens, passwords), prefer **pipe mode**: `printf '%s' "$TOKEN" | copy`.
> Passing secrets as arguments (e.g. `copy my-secret`) may leak them into shell history and process lists.

---

## `past` - read from clipboard

`past` prints the current clipboard contents to stdout, without altering it.

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

### Behaviour

* Uses the same backend selection logic as `copy`:

  * `wl-paste --no-newline` on Wayland.
  * `xclip -selection clipboard -out` or `xsel --clipboard --output` on X11.
* Does **not** append any trailing newline beyond what is already in the clipboard.

### Exit codes

* `0` - success.
* `1` - `PAST_ERR_GENERAL` - generic error.
* `3` - `PAST_ERR_NO_BACKEND` - no suitable clipboard utility found.
* `4` - `PAST_ERR_BACKEND_FAILED` - backend tool returned non‑zero.

---

## Using `copy` and `past` together

Because both tools talk to the same clipboard, they combine well:

```bash
# Copy some text
printf 'some text' | copy

# Paste it back into another command
printf 'You copied: %s\n' "$(past)"

# Round-trip through a transformation
past | tr 'a-z' 'A-Z' | copy

# Yank a path once and reuse it many times
ls | fzf | copy     # choose a path
cd "$(past)"       # jump there later
```

You can also integrate them into aliases or shell functions, for example:

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

* **Running over SSH**

  * Clipboard access usually targets the **remote** display/session. You may need extra configuration 
    (X11 forwarding, Wayland remoting, or an SSH tunnel to a local clipboard service).

* **Clipboard managers (KDE Klipper, GNOME, etc.)**

  * These tools work fine alongside clipboard managers - they simply populate the CLIPBOARD selection, which managers then track.

---

## License & disclaimer

This project is licensed under the [MIT License](./LICENSE).

> [!NOTE]
> The scripts are provided **as is**, without any warranty of correctness or fitness for a particular purpose.
> Always verify clipboard contents in security‑sensitive workflows.

---

## Contributing

Issues and pull requests are welcome.
If you propose enhancements (new flags, additional backends, etc.),
please include concrete examples and a short rationale so the tools stay small, focused, and easy to reason about :innocent:
