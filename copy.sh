#!/bin/bash

# Name: copy.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.4.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   Writes text or binary data to the system clipboard (CLIPBOARD)
#   regardless of the display server (Wayland or X11).
#   It automatically selects the best available backend:
#     - Wayland: wl-copy (wl-clipboard)
#     - X11:     xclip or xsel
#
#   Behavior:
#     - With arguments:
#         copy word1 word2
#         -> Joins arguments with spaces and copies 'word1 word2'.
#     - With stdin (Pipe):
#         echo 'hello' | copy
#         -> Streams input directly to clipboard.
#     - Priority:
#         If stdin is piped, it takes precedence over arguments
#         (streaming mode).
#         No trailing newline is appended by the script itself.
#
#   ANSI handling:
#     - By default, ANSI/VT escape sequences
#       (CSI colors, OSC links, short ESC controls)
#       are stripped before writing to the clipboard,
#       so pasting in GUI applications produces clean text.
#     - Use --raw / -r to preserve escape sequences verbatim.
#
#   Append mode:
#     - --append / -a appends to the existing clipboard content
#       instead of replacing it.
#       Only valid for text payloads.
#
#   Whitespace trimming:
#     - --trim removes leading and trailing whitespace
#       (spaces, tabs, newlines) before writing to the clipboard.
#       Only valid for text payloads.
#
#   Automatic MIME detection (always on by default):
#     - When the payload looks like JSON
#       (first non-whitespace byte is `{` or `[`)
#       AND `jq` is installed AND `jq` parses it cleanly,
#       the MIME type is set to `application/json` automatically.
#       Without `jq`, the JSON path is skipped silently
#       (we cannot tell valid JSON from a similar-looking string
#       without a real parser).
#     - When the payload's leading bytes match a binary magic
#       signature, the MIME is set accordingly:
#         PNG, JPEG, GIF, BMP, WebP -> image/<format>
#       These signatures cannot occur in plain text by design,
#       so the detection has no false-positive risk.
#     - Auto-detection is skipped when --append is in effect:
#       the prelude (existing clipboard content) is already mixed
#       in downstream, so classifying half a payload would lie.
#     - Disable the heuristic with --no-auto if you specifically
#       want to copy invalid-but-similar text verbatim.
#
#   MIME type support:
#     - --type MIME forwards a custom MIME type to the backend
#       (Wayland: wl-copy --type;  X11: xclip -t).
#       An explicit --type always wins over auto-detection.
#     - --json (shorthand -j) is a shortcut
#       for --type application/json --raw,
#       and trusts the user without invoking `jq`.
#     - --image[=FORMAT] copies binary image data with the
#       matching image/<format> MIME type (default png).
#       Implies --raw.
#
#   Backend override:
#     - Set COPY_PAST_BACKEND={wl-clipboard|xclip|xsel}
#       to force a specific backend, bypassing the auto-detection.
#       Useful when multiple backends are installed,
#       or when debugging X11 vs Wayland behaviour.
#       xsel does not support MIME types,
#       so non-text payloads fall back to an error there.
#
#   Debug logging:
#     - --debug (alias -d / --verbose) emits structured event lines
#       on stderr, prefixed with '[copy debug]'.
#       Format: '[copy debug] event=<name> key=value key=value'.
#       The flag is silent by default, so existing pipelines
#       are not disturbed.
#
# Usage:
#   # As a standalone script (must be in $PATH):
#   echo 'hello' | copy.sh
#
#   # Sourced in .bashrc:
#   source /path/to/copy.sh
#   copy 'text'
#
# Exit Codes:
#   0: Success.
#   1: COPY_ERR_GENERAL
#      Generic error.
#   2: COPY_ERR_USAGE
#      Invalid usage, unknown option, or unknown backend override.
#   3: COPY_ERR_NO_BACKEND
#      No suitable clipboard utility found (wl-copy, xclip, xsel).
#   4: COPY_ERR_BACKEND_FAILED
#      The clipboard utility (or the ANSI-stripping stage)
#      returned a non-zero exit code.
#   5: COPY_ERR_TYPE_MISMATCH
#      Incompatible combination of options
#      (e.g. --append with --image),
#      or the active backend cannot handle the requested MIME type
#      (e.g. xsel + --json).
#
# Disclaimer:
#   This script is provided 'as is', without any warranty.
#   Ensure required dependencies (wl-clipboard, xclip, or xsel)
#   are installed on your system.

# region Error codes
#
# These constants are guarded against re-declaration,
# so the script can be sourced repeatedly in the same shell
# (for example, when reloading .bashrc) without tripping `readonly`.
# bashsupport disable=BP5001

if [[ -z ${COPY_ERR_GENERAL+x} ]]; then
  readonly COPY_ERR_GENERAL=1
fi

if [[ -z ${COPY_ERR_USAGE+x} ]]; then
  readonly COPY_ERR_USAGE=2
fi

if [[ -z ${COPY_ERR_NO_BACKEND+x} ]]; then
  readonly COPY_ERR_NO_BACKEND=3
fi

if [[ -z ${COPY_ERR_BACKEND_FAILED+x} ]]; then
  readonly COPY_ERR_BACKEND_FAILED=4
fi

if [[ -z ${COPY_ERR_TYPE_MISMATCH+x} ]]; then
  readonly COPY_ERR_TYPE_MISMATCH=5
fi

# endregion

# region Internal helpers

#######################################
# Print usage information.
#
# Outputs:
#   Usage text to stdout.
#######################################
function __cp_usage() {
  cat <<'EOF'
copy - write text or binary data to system clipboard

Description:
  Detects the display server (Wayland/X11) and uses the appropriate tool
  (wl-copy, xclip, or xsel) to copy data to the clipboard.

  By default, ANSI escape sequences (colors, bold, hyperlinks, etc.)
  are stripped so that pasted text works correctly in GUI applications.
  Use --raw (-r) to preserve escape sequences for terminal-to-terminal use.

Usage:
  copy [options] [text...]
  echo 'text' | copy
  cat image.png | copy --image
  copy --help

Options:
  -h, --help            Show this help message.
  -r, --raw             Preserve ANSI escape sequences (do not strip colors).
  -a, --append          Append to the existing clipboard content
                        instead of replacing it (text only).
      --trim            Trim leading and trailing whitespace before writing
                        (text only).
      --type MIME       Set the clipboard MIME type explicitly
                        (e.g. application/json, image/png, text/html).
                        Implies --raw for non-text types.
                        Always wins over auto-detection.
  -j, --json            Shortcut for --type application/json --raw;
                        trusts the user without parsing the payload.
      --image[=FORMAT]  Copy binary image data; FORMAT defaults to png
                        (jpg, jpeg, webp, gif, svg are also accepted).
                        Implies --raw.
      --no-auto         Disable the always-on auto-detection
                        and copy the payload as text/plain.
  -d, --debug, --verbose
                        Print structured debug events on stderr
                        (lines prefixed with '[copy debug]').
                        Has no effect on stdout or the payload.
  --                    End of options; remaining arguments are treated as text.

Environment:
  COPY_PAST_BACKEND     Force a specific backend
                        (wl-clipboard | xclip | xsel).

Examples:
  copy 'Hello World'                  # Copies: Hello World
  pwd | copy                          # Copies current path
  ls --color | copy -r                # Preserves color codes
  date | copy --append                # Appends date to current clipboard
  echo '  spaced  ' | copy --trim     # Copies: spaced
  cat data.json | copy                # Auto-detected as application/json
  cat data.json | copy -j             # Same, explicit (no jq parse)
  cat data.json | copy --no-auto      # Force text/plain
  cat picture.png | copy              # Auto-detected as image/png
  grim -g "$(slurp)" - | copy --image # Screenshot in clipboard (explicit)
EOF
}

#######################################
# Print error message and return with code.
#
# Arguments:
#   1: Message text.
#   2: Return code (optional, default: COPY_ERR_GENERAL).
#
# Outputs:
#   Error message to stderr.
#######################################
function __cp_error() {
  local -r message="$1"
  local -ir code="${2:-$COPY_ERR_GENERAL}"

  printf 'ERROR: %s\n' "$message" >&2

  return "$code"
}

#######################################
# Emit a structured debug log line on stderr.
#
# The format is intentionally machine-friendly so that tests
# (and humans grepping logs) can match individual events:
#
#   [copy debug] event=<name> key=value key2='value with spaces'
#
# Values that contain whitespace are wrapped in single quotes;
# everything else is printed verbatim.
# When the user has not enabled --debug the helper is a no-op,
# so default-mode invocations stay completely silent on stderr
# and existing user pipelines are unaffected.
#
# Arguments:
#   1:        debug_mode flag (0 = silent, 1 = active).
#   2:        event name (free-form, alpha-numeric + dashes).
#   3..N:     key=value pairs, in order.
#
# Outputs:
#   One line on stderr when debug_mode is non-zero.
#######################################
function __cp_debug() {
  local -ir debug_mode=$1
  if ((!debug_mode)); then
    return 0
  fi

  local -r event="$2"
  shift 2

  # Build the trailing 'key=value key=value' suffix.
  # Quote any value that contains whitespace,
  # so a downstream `read`-based parser stays unambiguous.
  local kv pair key value suffix=''
  for kv in "$@"; do
    key="${kv%%=*}"
    value="${kv#*=}"
    if [[ "$value" == *[[:space:]]* ]]; then
      pair="${key}='${value}'"
    else
      pair="${kv}"
    fi
    if [[ -z $suffix ]]; then
      suffix="$pair"
    else
      suffix+=" $pair"
    fi
  done

  if [[ -z $suffix ]]; then
    printf '[copy debug] event=%s\n' "$event" >&2
  else
    printf '[copy debug] event=%s %s\n' "$event" "$suffix" >&2
  fi
}

#######################################
# Check if a command exists in the system.
#
# Arguments:
#   1: Command name.
#
# Returns:
#   0: If exists.
#   1: Otherwise.
#######################################
function __cp_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# endregion

# region Backend detection

#######################################
# Detect the best available clipboard backend command.
#
# When COPY_PAST_BACKEND is set, that backend is used
# (and its absence is a hard error).
# Otherwise we prefer Wayland's wl-copy
# when a Wayland session is detected,
# then fall back to xclip, and finally to xsel.
#
# The returned command is the BASE invocation only;
# extra flags such as `--type MIME` are appended later
# by __cp_apply_mime, after option parsing.
#
# Arguments:
#   1: Name of the array variable (nameref) to store the command.
#
# Returns:
#   0: On success (backend found).
#   COPY_ERR_NO_BACKEND: If no backend is available.
#   COPY_ERR_USAGE: If COPY_PAST_BACKEND has an unknown value.
#######################################
function __cp_detect_backend() {
  # Bash nameref: writes inside the function reach the caller's
  # variable named in $1. Lets us return an array without resorting
  # to global state or stdout-based serialisation.
  local -n _backend_command="$1"

  # Step 1: honour an explicit override from the environment.
  # An unknown value is treated as a usage error (rc=2),
  # not as 'no backend found' (rc=3),
  # because the user clearly expressed a preference.
  case "${COPY_PAST_BACKEND-}" in
    '') ;; # No override; fall through to auto-detection below.

    wl-clipboard | wayland | wl-copy)
      if __cp_have_cmd wl-copy; then
        _backend_command=(wl-copy)
        return 0
      fi
      return "$COPY_ERR_NO_BACKEND"
      ;;

    xclip)
      if __cp_have_cmd xclip; then
        _backend_command=(xclip -selection clipboard -in)
        return 0
      fi
      return "$COPY_ERR_NO_BACKEND"
      ;;

    xsel)
      if __cp_have_cmd xsel; then
        _backend_command=(xsel --clipboard --input)
        return 0
      fi
      return "$COPY_ERR_NO_BACKEND"
      ;;

    *)
      __cp_error \
        "Unknown COPY_PAST_BACKEND value: '${COPY_PAST_BACKEND}' (use wl-clipboard, xclip, or xsel)" \
        "$COPY_ERR_USAGE" \
        || return "$?"
      ;;
  esac

  # Step 2: auto-detection.
  # Wayland is checked first because a Wayland session
  # may also have xclip available via XWayland,
  # but the native wl-clipboard avoids round-tripping through Xwayland.
  if { [[ -n ${WAYLAND_DISPLAY-} ]] \
    || [[ ${XDG_SESSION_TYPE-} == 'wayland' ]]; } \
    && __cp_have_cmd wl-copy; then
    _backend_command=(wl-copy)
    return 0
  fi

  if __cp_have_cmd xclip; then
    _backend_command=(xclip -selection clipboard -in)
    return 0
  fi

  if __cp_have_cmd xsel; then
    _backend_command=(xsel --clipboard --input)
    return 0
  fi

  return "$COPY_ERR_NO_BACKEND"
}

#######################################
# Append the backend-specific MIME-type flag
# to a backend command array.
#
# Each backend uses a different flag name for MIME type:
#   - wl-copy:  --type MIME
#   - xclip:    -t MIME
#   - xsel:     unsupported (text/plain only)
#
# Arguments:
#   1: Name of the backend command array (nameref).
#   2: MIME type string (e.g. 'application/json').
#
# Returns:
#   0: On success.
#   COPY_ERR_TYPE_MISMATCH: If the backend does not support MIME types.
#######################################
function __cp_apply_mime() {
  local -n _cmd="$1"
  local -r mime="$2"

  case "${_cmd[0]}" in
    wl-copy)
      _cmd+=(--type "$mime")
      return 0
      ;;
    xclip)
      _cmd+=(-t "$mime")
      return 0
      ;;
    xsel)
      __cp_error \
        "xsel does not support MIME types; use wl-clipboard or xclip for '${mime}'" \
        "$COPY_ERR_TYPE_MISMATCH" \
        || return "$?"
      ;;
    *)
      __cp_error \
        "Internal error: unknown backend '${_cmd[0]}' for MIME type" \
        "$COPY_ERR_GENERAL" \
        || return "$?"
      ;;
  esac
}

# endregion

# region MIME sniffing

#######################################
# Inspect the leading bytes of a file
# and emit a best-guess MIME type to stdout.
#
# Detection strategy, in order of confidence:
#   1. Binary magic bytes for common image formats:
#        89 50 4E 47           PNG
#        FF D8 FF              JPEG
#        47 49 46 38           GIF
#        42 4D                 BMP
#        52 49 46 46 .. WEBP   WebP (RIFF container)
#      These signatures cannot occur in plain text by design,
#      so this part of the detection has no false-positive risk.
#   2. JSON heuristic:
#      first non-whitespace byte is `{` or `[`,
#      `jq -e .` parses the whole payload.
#      We REQUIRE `jq` to be installed:
#      without a real parser,
#      structural matching like `{ ... }`
#      produces too many false positives
#      (shell snippets, code samples, log lines, set literals)
#      to flip the MIME silently.
#   3. Fallback: text/plain.
#
# We never short-circuit on extension or filename:
# the script never sees a filename in pipe mode,
# and trusting one in argument mode would be insecure.
#
# Arguments:
#   1: Path to the buffered payload file.
#
# Outputs:
#   The detected MIME type on stdout
#   (e.g. 'image/png', 'application/json', 'text/plain').
#######################################
function __cp_sniff_mime() {
  local -r path="$1"

  # Binary magic-byte detection.
  # Read the first 16 bytes as hex,
  # uppercase, no separators, no addresses.
  # Enough to distinguish every image format we recognise.
  local head_hex
  head_hex=$(head -c 16 "$path" \
    | LC_ALL=C od -An -tx1 \
    | tr -d ' \n' \
    | tr 'a-f' 'A-F')

  case "$head_hex" in
    89504E47*)
      printf 'image/png'
      return 0
      ;;
    FFD8FF*)
      printf 'image/jpeg'
      return 0
      ;;
    47494638*)
      printf 'image/gif'
      return 0
      ;;
    424D*)
      printf 'image/bmp'
      return 0
      ;;
    52494646*)
      # RIFF container: WebP has 'WEBP' at byte offset 8.
      local marker_hex
      marker_hex=$(dd if="$path" bs=1 skip=8 count=4 2>/dev/null \
        | LC_ALL=C od -An -tx1 \
        | tr -d ' \n' \
        | tr 'a-f' 'A-F')
      if [[ "$marker_hex" == '57454250' ]]; then
        printf 'image/webp'
        return 0
      fi
      ;;
  esac

  # JSON heuristic.
  # Cheap rejection first:
  # only when the first non-whitespace byte is `{` or `[`
  # do we run the (more expensive) jq parse.
  local first_char
  first_char=$(LC_ALL=C tr -d '[:space:]' <"$path" | head -c 1)
  case "$first_char" in
    '{' | '[')
      if __cp_have_cmd jq && jq -e '.' <"$path" >/dev/null 2>&1; then
        printf 'application/json'
        return 0
      fi
      ;;
  esac

  printf 'text/plain'
}

# endregion

# region ANSI stripping

#######################################
# Strip ANSI/VT escape sequences from stdin.
#
# Implements the ECMA-48 grammar so that all standard escape forms
# are recognised, not just basic SGR colors:
#
#   - OSC sequences:
#       ESC ] <any chars except ESC/BEL> (BEL | ESC \)
#       Covers e.g. window titles (ESC]0;...) and OSC 8 hyperlinks.
#   - CSI sequences:
#       ESC [ <params 0x30-0x3F> <intermediates 0x20-0x2F> <final 0x40-0x7E>
#       The parameter range includes private markers (?, <, =, >),
#       so cursor-mode toggles like ESC[?25h are stripped too.
#   - Short escapes:
#       ESC <single byte not [ or ]>
#       e.g. ESC c (full reset), ESC 7 (save cursor).
#
#   The patterns are applied in order, longer forms first,
#   so the short-escape catch-all does not consume
#   the leading ESC of a CSI/OSC sequence.
#
#   Uses bash $'...' to inject the literal escape character;
#   this keeps the substitution portable
#   between GNU sed and BSD/macOS sed
#   (the \xNN notation is a GNU extension).
#   LC_ALL=C ensures byte-level matching
#   regardless of the user's locale.
#
# Outputs:
#   Cleaned text to stdout.
#######################################
function __cp_strip_ansi() {
  # Inject literal ESC (0x1B) and BEL (0x07) bytes via $'...'.
  # Doing it this way makes the regex readable (no \x1b clutter)
  # and works the same on GNU sed and BSD sed.
  local -r esc=$'\033'
  local -r bel=$'\007'

  # The triple sed pipeline applies the longest-match patterns first:
  #   1. OSC sequences (terminated by either BEL or ESC \)
  #   2. CSI sequences (parameters, intermediates, final byte)
  #   3. Short ESC <single byte> sequences (must run last,
  #      otherwise it would consume the leading ESC of CSI/OSC).
  LC_ALL=C sed -E \
    -e "s#${esc}\\][^${esc}${bel}]*(${bel}|${esc}\\\\)##g" \
    -e "s#${esc}\\[[0-9:;<=>?]*[ -/]*[@-~]##g" \
    -e "s#${esc}[^][]##g"
}

#######################################
# Trim leading and trailing whitespace from stdin.
#
# Buffers the whole input and uses bash parameter expansion
# (no fork/exec) to remove runs of whitespace from both ends.
# Whitespace classes follow [[:space:]]:
# space, tab, newline, carriage return, form feed, vertical tab.
#
# Designed for text payloads only;
# binary inputs will be silently corrupted
# because the read step strips trailing newlines.
# Validation lives at the option-parsing layer,
# which forbids --trim with --image / non-text --type.
#
# Outputs:
#   Trimmed text to stdout.
#######################################
function __cp_trim_whitespace() {
  local content
  # `read -r -d ''` reads up to NUL, i.e. the whole stdin in one go.
  # || true keeps us going on the inevitable EOF return code (>0).
  IFS= read -r -d '' content || true

  # ${var#"${var%%[![:space:]]*}"} strips the leading whitespace run;
  # ${var%"${var##*[![:space:]]}"} strips the trailing whitespace run.
  content="${content#"${content%%[![:space:]]*}"}"
  content="${content%"${content##*[![:space:]]}"}"

  printf '%s' "$content"
}

#######################################
# Internal pipeline runner.
#
# Reads stdin, optionally pipes it through __cp_strip_ansi
# and/or __cp_trim_whitespace,
# and writes the result to the chosen backend.
#
# Pulled into its own function so the caller
# can wrap the whole thing in `(set -o pipefail; ...)`
# and have any stage's failure (sed, trim, backend)
# propagate as the subshell's exit code.
#
# Arguments:
#   1:    raw_mode flag (0 = strip ANSI, 1 = preserve verbatim).
#   2:    trim_mode flag (0 = no trim, 1 = trim whitespace).
#   3..N: backend command and its arguments.
#######################################
function __cp_emit() {
  local -ir raw_mode=$1
  local -ir trim_mode=$2
  shift 2

  # Short-circuit: no transformations at all.
  if ((raw_mode && !trim_mode)); then
    "$@"
    return "$?"
  fi

  # Build the transformation chain dynamically.
  # The leftmost stage is stdin into our pipeline,
  # the rightmost stage is the backend.
  if ((raw_mode)); then
    __cp_trim_whitespace | "$@"
  elif ((trim_mode)); then
    __cp_strip_ansi | __cp_trim_whitespace | "$@"
  else
    __cp_strip_ansi | "$@"
  fi
}

# endregion

# region Append helpers

#######################################
# Resolve the matching `past` invocation for an append operation.
#
# We re-use past.sh when it is sourced into the current shell
# (typical for users who add `source copy.sh; source past.sh`
# to their .bashrc).
# Otherwise we fall back to the same shell that runs us
# and execute past.sh by absolute path next to copy.sh.
#
# Arguments:
#   1: Name of the array variable (nameref) to store the command.
#######################################
function __cp_resolve_past() {
  local -n _past_cmd="$1"

  if declare -F past >/dev/null 2>&1; then
    _past_cmd=(past)
    return 0
  fi

  local self_dir
  self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if [[ -r "${self_dir}/past.sh" ]]; then
    _past_cmd=(bash "${self_dir}/past.sh")
    return 0
  fi

  return "$COPY_ERR_GENERAL"
}

#######################################
# Read the current clipboard content
# without mutating it.
#
# Used by the --append branch
# to compose old + new before writing back.
# Errors propagate verbatim
# so the caller can surface them as backend failures.
#
# Outputs:
#   Current clipboard text to stdout.
#######################################
function __cp_read_clipboard() {
  local -a past_cmd
  if ! __cp_resolve_past past_cmd; then
    __cp_error \
      'Cannot resolve past.sh for --append; install past alongside copy' \
      "$COPY_ERR_GENERAL" \
      || return "$?"
  fi

  "${past_cmd[@]}"
}

# endregion

# region Option model

#######################################
# Initialise the options struct to its defaults.
#
# The 'struct' is a set of caller-owned scalars, passed in by name
# via Bash namerefs. Keeping the state on the caller's stack
# (instead of using globals) means each `copy` invocation gets
# its own clean slate, even when callers source the script
# and call the function in a long-lived shell.
#
# Arguments:
#   1: nameref to raw_mode    (int, 0 default).
#   2: nameref to trim_mode   (int, 0 default).
#   3: nameref to append_mode (int, 0 default).
#   4: nameref to auto_mode   (int, 1 default; auto-detection on).
#   5: nameref to debug_mode  (int, 0 default).
#   6: nameref to mime_type   (string, '' default).
#######################################
function __cp_init_options() {
  local -n _raw_mode="$1"
  local -n _trim_mode="$2"
  local -n _append_mode="$3"
  local -n _auto_mode="$4"
  local -n _debug_mode="$5"
  local -n _mime_type="$6"

  _raw_mode=0
  _trim_mode=0
  _append_mode=0
  _auto_mode=1
  _debug_mode=0
  _mime_type=''
}

#######################################
# Map a bare image format identifier (e.g. 'jpg', 'svg', 'webp')
# to a canonical IANA `image/<...>` MIME type.
#
# Unknown formats are forwarded as `image/<format>` verbatim,
# which lets the backend reject them with its own error
# instead of failing here.
#
# Arguments:
#   1: nameref to the destination string variable.
#   2: format identifier string (already validated as non-empty).
#######################################
function __cp_image_format_to_mime() {
  # Use a private nameref name that no caller is allowed to use
  # for its own state, so we never end up with a self-referencing
  # nameref (which Bash silently downgrades to a plain string).
  local -n _mime_dst="$1"
  local -r format="$2"

  case "$format" in
    jpg | jpeg) _mime_dst='image/jpeg' ;;
    png | webp | gif | bmp | tiff)
      _mime_dst="image/${format}"
      ;;
    svg) _mime_dst='image/svg+xml' ;;
    *) _mime_dst="image/${format}" ;;
  esac
}

# endregion

# region Argument parsing
#
# Each flag handler is split into its own tiny function that takes
# namerefs into the option struct (and to `_consumed`, the number
# of argv slots the handler ate). Splitting the handlers this way
# means each one fits on a screen and is independently testable,
# while keeping the dispatch loop free of inline option bodies.

#######################################
# Parse the value of a `--type[=]MIME` flag.
#
# Handles both the `--type MIME` and `--type=MIME` forms.
# Empty values are rejected with COPY_ERR_USAGE.
#
# Arguments:
#   1:    nameref to mime_type slot.
#   2:    nameref to consumed-arg counter.
#   3..N: remaining argv (only $3 and $4 are inspected).
#
# Returns:
#   0: on success.
#   COPY_ERR_USAGE: when the value is missing or empty.
#######################################
function __cp_parse_type_flag() {
  local -n _mime_out="$1"
  local -n _consumed="$2"
  local -r flag="$3"

  if [[ "$flag" == --type=* ]]; then
    _mime_out="${flag#*=}"
    _consumed=1
  else
    if [[ -z ${4-} ]]; then
      __cp_error '--type requires a MIME argument' \
        "$COPY_ERR_USAGE" \
        || return "$?"
    fi
    _mime_out="$4"
    _consumed=2
  fi

  if [[ -z $_mime_out ]]; then
    __cp_error '--type requires a MIME argument' \
      "$COPY_ERR_USAGE" \
      || return "$?"
  fi
}

#######################################
# Parse the value of a `--image[=FORMAT]` flag.
#
# `--image` alone is treated as `--image=png`.
# Both forms set `raw_mode=1`, because binary payloads must not
# go through the ANSI-stripping pipeline.
#
# Arguments:
#   1:    nameref to mime_type slot.
#   2:    nameref to raw_mode slot.
#   3:    nameref to consumed-arg counter.
#   4:    the original flag (`--image` or `--image=FOO`).
#
# Returns:
#   0: on success.
#   COPY_ERR_USAGE: when an empty format is supplied.
#######################################
function __cp_parse_image_flag() {
  local -n _mime_out="$1"
  local -n _raw_out="$2"
  local -n _consumed="$3"
  local -r flag="$4"

  if [[ "$flag" == '--image' ]]; then
    _mime_out='image/png'
  else
    local -r format="${flag#*=}"
    if [[ -z $format ]]; then
      __cp_error '--image=FORMAT requires a non-empty format' \
        "$COPY_ERR_USAGE" \
        || return "$?"
    fi
    __cp_image_format_to_mime _mime_out "$format"
  fi

  _raw_out=1
  _consumed=1
}

#######################################
# Parse the full argv into the option struct.
#
# All flags are consumed left-to-right; the first plain word
# (or `--`) ends option parsing and the remaining argv is left
# for the caller to treat as the positional payload.
#
# Arguments:
#   1:    nameref to raw_mode    (int).
#   2:    nameref to trim_mode   (int).
#   3:    nameref to append_mode (int).
#   4:    nameref to auto_mode   (int).
#   5:    nameref to debug_mode  (int).
#   6:    nameref to mime_type   (string).
#   7:    nameref to a string array that will receive the leftover
#         positional arguments (post-flags) in order.
#   8..N: the original argv to parse.
#
# Returns:
#   0:               on success or when --help was handled.
#   1 (sentinel)     when --help was consumed
#                    and the caller should exit with code 0.
#   COPY_ERR_USAGE:  on unknown flags or malformed values.
#######################################
function __cp_parse_args() {
  local -n _raw="$1"
  local -n _trim="$2"
  local -n _append="$3"
  local -n _auto="$4"
  local -n _debug="$5"
  local -n _mime="$6"
  local -n _rest="$7"
  shift 7

  local -i consumed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        __cp_usage
        # Magic return code: copy() interprets 200 as 'help shown,
        # exit 0'. We avoid 0 here because 0 is reserved for
        # 'parsing succeeded, continue to the next phase'.
        return 200
        ;;
      -r | --raw)
        _raw=1
        shift
        ;;
      -a | --append)
        _append=1
        shift
        ;;
      --trim)
        _trim=1
        shift
        ;;
      --type | --type=*)
        __cp_parse_type_flag _mime consumed "$@" || return "$?"
        shift "$consumed"
        ;;
      -j | --json)
        _mime='application/json'
        _raw=1
        shift
        ;;
      --image | --image=*)
        __cp_parse_image_flag _mime _raw consumed "$1" \
          || return "$?"
        shift "$consumed"
        ;;
      --no-auto)
        _auto=0
        shift
        ;;
      -d | --debug | --verbose)
        _debug=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        __cp_error "Unknown option: $1" "$COPY_ERR_USAGE" \
          || return "$?"
        ;;
      *)
        # Plain word: stop consuming options.
        break
        ;;
    esac
  done

  # Whatever is left becomes the positional payload.
  _rest=("$@")
  return 0
}

# endregion

# region Option validation

#######################################
# Classify a MIME string as binary or text-ish.
#
# Binary classes (image/*, application/octet-stream)
# bypass the ANSI/trim pipeline and forbid --append / --trim.
# Everything else (including application/json and text/*)
# is treated as text-ish for transformation purposes.
#
# Arguments:
#   1: nameref to a 0/1 sink (set to 1 for binary, 0 for text).
#   2: MIME type string (may be empty).
#######################################
function __cp_classify_mime() {
  local -n _is_binary="$1"
  local -r mime="$2"

  case "$mime" in
    image/* | application/octet-stream) _is_binary=1 ;;
    *) _is_binary=0 ;;
  esac
}

#######################################
# Cross-flag compatibility checks for option combinations
# that would silently corrupt data.
#
# Also reconciles auto-detection with user choices:
#   * an explicit MIME pin always wins over auto-detection;
#   * --append disables auto-detection because the prelude
#     (existing clipboard text) is already mixed in downstream,
#     so classifying half a payload would lie.
#
# Arguments:
#   1: nameref to auto_mode (read+write).
#   2: append_mode (int).
#   3: trim_mode   (int).
#   4: mime_type   (string).
#
# Returns:
#   0: on success.
#   COPY_ERR_TYPE_MISMATCH: on incompatible combos.
#######################################
function __cp_validate_options() {
  local -n _auto="$1"
  local -ir append_mode=$2
  local -ir trim_mode=$3
  local -r mime="$4"

  local -i is_binary=0
  __cp_classify_mime is_binary "$mime"

  if ((append_mode && is_binary)); then
    __cp_error \
      '--append is only valid for text payloads, not for binary MIME types' \
      "$COPY_ERR_TYPE_MISMATCH" \
      || return "$?"
  fi

  if ((trim_mode && is_binary)); then
    __cp_error \
      '--trim is only valid for text payloads, not for binary MIME types' \
      "$COPY_ERR_TYPE_MISMATCH" \
      || return "$?"
  fi

  # An explicit MIME pin always wins over auto-detection.
  if ((_auto)) && [[ -n $mime ]]; then
    _auto=0
  fi

  # --append is text-only by design,
  # and auto-detection might pick a binary type (e.g. image/png).
  # Silently disable the heuristic
  # rather than failing,
  # because 'append text to whatever is in the clipboard'
  # is the conservative, intuitive behaviour.
  if ((_auto && append_mode)); then
    _auto=0
  fi
}

# endregion

# region Backend wiring

#######################################
# Resolve the clipboard backend command and apply an explicit MIME.
#
# Wraps __cp_detect_backend + __cp_apply_mime
# with proper error reporting,
# so the orchestrator stays free of duplicated rc-handling.
#
# Arguments:
#   1: nameref to a string array that receives the backend argv.
#   2: explicit MIME type (may be empty; skips __cp_apply_mime).
#
# Returns:
#   0: on success.
#   COPY_ERR_USAGE: on unknown COPY_PAST_BACKEND override.
#   COPY_ERR_NO_BACKEND: when no backend is installed.
#   COPY_ERR_TYPE_MISMATCH: when the MIME flag is incompatible
#                           with the chosen backend (e.g. xsel).
#######################################
function __cp_resolve_backend() {
  local -n _backend="$1"
  local -r mime="$2"

  local -i detect_rc=0
  __cp_detect_backend _backend || detect_rc=$?

  if ((detect_rc != 0)); then
    if ((detect_rc == COPY_ERR_USAGE)); then
      # __cp_detect_backend already emitted its own message.
      return "$detect_rc"
    fi

    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'
    __cp_error "$error_msg" \
      "$COPY_ERR_NO_BACKEND" \
      || return "$?"
  fi

  if [[ -n $mime ]]; then
    __cp_apply_mime _backend "$mime" || return "$?"
  fi
}

# endregion

# region Input buffering

#######################################
# Capture the payload (stdin or argv) into a temp file
# so we can sniff its leading bytes and replay it later.
#
# When stdin is piped in, we cat it verbatim.
# Otherwise we join the positional args with single spaces
# (the same `echo "$*"` convention used by the regular
# argument-mode branch downstream).
# An empty argv with a tty stdin is a usage error.
#
# Arguments:
#   1:    nameref to a string sink that receives the file path.
#   2..N: the positional payload (post-flags).
#
# Outputs:
#   No stdout. The buffered file lives at the path stored in $1.
#
# Returns:
#   0: on success.
#   COPY_ERR_USAGE: on no input at all.
#######################################
function __cp_buffer_input() {
  local -n _buffer_path="$1"
  shift

  _buffer_path="$(mktemp -t copy-auto.XXXXXX)"

  if [[ ! -t 0 ]]; then
    cat >"$_buffer_path"
    return 0
  fi

  if [[ $# -gt 0 ]]; then
    # Argument mode: same join-with-spaces convention as the
    # argument-mode branch in copy() so the sniffer sees exactly
    # the bytes that would otherwise reach the backend.
    (
      IFS=' '
      echo "$*"
    ) >"$_buffer_path"
    return 0
  fi

  rm -f -- "$_buffer_path"
  _buffer_path=''

  local error_msg='No input provided. '
  error_msg+='Pass text as arguments or pipe via stdin.'
  __cp_usage >&2
  __cp_error "$error_msg" \
    "$COPY_ERR_USAGE" \
    || return "$?"
}

#######################################
# Stream a buffered file straight to the backend, no transforms.
#
# Used for binary auto-detected payloads (PNG/JPEG/...) that
# must not pass through the ANSI/trim pipeline.
# The buffer is removed on every exit path before returning.
#
# Arguments:
#   1:    path to the buffered file.
#   2..N: backend argv to invoke.
#
# Returns:
#   0: on success.
#   COPY_ERR_BACKEND_FAILED: if the backend exits non-zero.
#######################################
function __cp_emit_buffer_raw() {
  local -r buffer_path="$1"
  shift

  local -i emit_rc=0
  "$@" <"$buffer_path" || emit_rc=$?
  rm -f -- "$buffer_path"

  if ((emit_rc != 0)); then
    __cp_error 'Clipboard backend failed.' \
      "$COPY_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
}

# endregion

# region Auto-detection orchestration

#######################################
# Run MIME sniffing on the buffered payload and dispatch.
#
# Side effects, depending on the sniffer's verdict:
#   - Binary MIME (image/*, ...):
#     applies the MIME to the backend, streams the buffer,
#     and signals 'done' to the caller via rc=200.
#   - text/plain:
#     consumes the buffer by re-binding it as the function's stdin
#     (`exec < "$buffer"`),
#     so the regular pipe path downstream sees the same bytes.
#
# Arguments:
#   1: nameref to the backend command array.
#   2: path to the buffered payload.
#   3: debug_mode flag (int; 0 = silent, 1 = log auto-detect events).
#
# Returns:
#   0:   text path was selected; caller continues to the prelude
#        and pipe-mode pipeline.
#   200: binary path was selected and the write completed;
#        caller should return 0 to its own caller.
#   COPY_ERR_TYPE_MISMATCH:  binary MIME but xsel backend.
#   COPY_ERR_BACKEND_FAILED: backend write failed.
#######################################
function __cp_run_auto_detect() {
  local -n _backend="$1"
  local -r buffer_path="$2"
  local -ir debug_mode=$3

  local sniffed_mime
  sniffed_mime="$(__cp_sniff_mime "$buffer_path")"

  __cp_debug "$debug_mode" 'auto-detect' "mime=${sniffed_mime}"

  if [[ "$sniffed_mime" == 'text/plain' ]]; then
    # Text path: hand the bytes back to the regular pipeline
    # by replacing this function's stdin with the buffered file.
    __cp_debug "$debug_mode" 'auto-detect-text' \
      'action=fall-through-to-pipeline'
    exec <"$buffer_path"
    rm -f -- "$buffer_path"
    return 0
  fi

  # Binary path.
  if ! __cp_apply_mime _backend "$sniffed_mime"; then
    local -ir mime_rc=$?
    rm -f -- "$buffer_path"
    return "$mime_rc"
  fi

  __cp_debug "$debug_mode" 'auto-detect-binary' \
    "mime=${sniffed_mime}" 'action=stream-buffer'

  __cp_emit_buffer_raw "$buffer_path" "${_backend[@]}" \
    || return "$?"

  # Sentinel: 'binary path completed, copy() should return 0'.
  return 200
}

# endregion

# region Append prelude

#######################################
# Snapshot the current clipboard content into a temp file
# so that --append can prefix it before writing back.
#
# Arguments:
#   1: nameref to a string sink that receives the file path
#      (empty string when --append was not requested).
#   2: append_mode flag (int).
#
# Returns:
#   0: on success or when --append was not requested.
#   COPY_ERR_BACKEND_FAILED: when reading the clipboard fails.
#######################################
function __cp_capture_prelude() {
  local -n _prelude_path="$1"
  local -ir append_mode=$2

  _prelude_path=''
  if ((!append_mode)); then
    return 0
  fi

  _prelude_path="$(mktemp -t copy-append.XXXXXX)"
  if ! __cp_read_clipboard >"$_prelude_path"; then
    rm -f -- "$_prelude_path"
    _prelude_path=''
    __cp_error \
      'Failed to read existing clipboard for --append' \
      "$COPY_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
}

#######################################
# Stream prelude (if any) followed by stdin.
#
# Defined as a function so that the surrounding `set -o pipefail`
# subshell can chain it into __cp_emit cleanly.
# The prelude itself is NEVER passed through ANSI stripping
# or trimming, because it represents the existing clipboard text
# we already trust; only the new payload is transformed downstream.
#
# Arguments:
#   1: path to the prelude file (may be empty for no prelude).
#######################################
function __cp_stream_with_prelude() {
  local -r prelude_path="$1"

  if [[ -n $prelude_path ]]; then
    cat -- "$prelude_path"
  fi
  cat
}

# endregion

# region Pipeline runners

#######################################
# Run the transformation+write pipeline under pipefail.
#
# The pipeline is:
#
#     <stdin> | __cp_stream_with_prelude
#             | __cp_emit raw trim -- backend...
#
# `set -o pipefail` is scoped to the subshell so it does not leak
# into the caller's shell. We use the `cmd || rc=$?` pattern instead
# of `if ! ( ... )` because the latter clobbers `$?` with the
# inversion result and we lose the subshell's true exit code.
#
# Arguments:
#   1:    raw_mode flag.
#   2:    trim_mode flag.
#   3:    prelude path (may be empty).
#   4..N: backend argv.
#
# Returns:
#   0: on success.
#   COPY_ERR_BACKEND_FAILED: if any pipeline stage failed.
#######################################
function __cp_run_pipeline() {
  local -ir raw_mode=$1
  local -ir trim_mode=$2
  local -r prelude_path="$3"
  shift 3

  local -i emit_rc=0
  (
    set -o pipefail
    __cp_stream_with_prelude "$prelude_path" \
      | __cp_emit "$raw_mode" "$trim_mode" "$@"
  ) || emit_rc=$?

  if ((emit_rc != 0)); then
    __cp_error 'Clipboard backend failed during pipe operation.' \
      "$COPY_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
}

#######################################
# Argument-mode wrapper around __cp_run_pipeline.
#
# Joins the leftover positional args with single spaces
# (`echo "$*"` semantics)
# and feeds the joined string to the same pipeline used by pipe mode.
# The temporary `IFS=' '` lives in a subshell to avoid disturbing
# the caller's IFS.
#
# Arguments:
#   1:    raw_mode flag.
#   2:    trim_mode flag.
#   3:    prelude path (may be empty).
#   4:    nameref to the backend command array.
#   5..N: positional words to copy.
#
# Returns:
#   0: on success.
#   COPY_ERR_USAGE: on no positional words at all.
#   COPY_ERR_BACKEND_FAILED: pipeline failures bubble up.
#######################################
function __cp_run_argument_mode() {
  local -ir raw_mode=$1
  local -ir trim_mode=$2
  local -r prelude_path="$3"
  local -n _backend="$4"
  shift 4

  if [[ $# -eq 0 ]]; then
    local error_msg='No input provided. '
    error_msg+='Pass text as arguments or pipe via stdin.'
    __cp_usage >&2
    __cp_error "$error_msg" \
      "$COPY_ERR_USAGE" \
      || return "$?"
  fi

  local input_text
  input_text="$(
    IFS=' '
    echo "$*"
  )"

  local -i emit_rc=0
  (
    set -o pipefail
    printf '%s' "$input_text" \
      | __cp_stream_with_prelude "$prelude_path" \
      | __cp_emit "$raw_mode" "$trim_mode" "${_backend[@]}"
  ) || emit_rc=$?

  if ((emit_rc != 0)); then
    __cp_error 'Clipboard backend failed.' \
      "$COPY_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
}

# endregion

# region Public API

#######################################
# Main function to write to clipboard.
#
# Thin orchestrator: every step lives in its own helper above,
# so this body reads as a sequence of named phases.
# State is kept on the local stack and threaded through helpers
# via Bash namerefs (parameters whose names start with `_`).
# No global state is used; each invocation gets a fresh slate.
#
# Arguments:
#   [options] [text...] or read from stdin.
#
# Options:
#   See __cp_usage for the authoritative list.
#
# Returns:
#   0: on success.
#   Non-zero: on error (see header for code list).
#######################################
function copy() {
  # Restrict word splitting to newline/tab inside this function.
  # Stops accidental space-splitting on user input, while still
  # allowing arrays-from-newlines patterns where they are intended.
  # Helpers that need space-joining (echo "$*") override IFS locally.
  local IFS=$'\n\t'

  # Phase 1: option struct.
  local -i raw_mode trim_mode append_mode auto_mode debug_mode
  local mime_type
  __cp_init_options \
    raw_mode trim_mode append_mode auto_mode debug_mode mime_type

  # Phase 2: parse argv.
  local -a positional=()
  local -i parse_rc=0
  __cp_parse_args \
    raw_mode trim_mode append_mode auto_mode debug_mode \
    mime_type positional \
    "$@" \
    || parse_rc=$?

  if ((parse_rc == 200)); then
    # --help was consumed; usage already printed.
    return 0
  fi
  if ((parse_rc != 0)); then
    return "$parse_rc"
  fi

  __cp_debug "$debug_mode" 'options-parsed' \
    "raw=${raw_mode}" "trim=${trim_mode}" \
    "append=${append_mode}" "auto=${auto_mode}" \
    "mime=${mime_type:-<none>}" \
    "positional-count=${#positional[@]}"

  # Phase 3: cross-option compatibility + auto-mode reconciliation.
  __cp_validate_options auto_mode \
    "$append_mode" "$trim_mode" "$mime_type" \
    || return "$?"

  __cp_debug "$debug_mode" 'options-validated' \
    "auto=${auto_mode}"

  # Phase 4: backend resolution (+ explicit --type application).
  local -a backend_cmd
  __cp_resolve_backend backend_cmd "$mime_type" || return "$?"

  __cp_debug "$debug_mode" 'backend-resolved' \
    "backend=${backend_cmd[0]}"

  # Phase 5: optional auto-detection, which can short-circuit
  # on a binary verdict and complete the write itself.
  if ((auto_mode)); then
    local sniff_buffer=''
    __cp_buffer_input sniff_buffer "${positional[@]}" \
      || return "$?"

    __cp_debug "$debug_mode" 'auto-detect-start' \
      "buffer=${sniff_buffer}"

    local -i auto_rc=0
    __cp_run_auto_detect backend_cmd "$sniff_buffer" "$debug_mode" \
      || auto_rc=$?

    if ((auto_rc == 200)); then
      # Binary path completed the write inside the helper.
      __cp_debug "$debug_mode" 'done' 'mode=auto-binary'
      return 0
    fi
    if ((auto_rc != 0)); then
      return "$auto_rc"
    fi
    # Text path: stdin now points at the buffered file,
    # the original argv-based payload is therefore gone,
    # so we fall through to pipe mode below regardless of how
    # the user originally supplied the input.
    positional=()
  fi

  # Phase 6: optional --append prelude.
  local prelude_file=''
  __cp_capture_prelude prelude_file "$append_mode" || return "$?"

  if ((append_mode)); then
    __cp_debug "$debug_mode" 'prelude-captured' \
      "path=${prelude_file}"
  fi

  # Phase 7: dispatch to pipe mode or argument mode.
  # The trap-style cleanup below ensures the prelude file
  # is removed on every exit path of the function.
  local -i write_rc=0
  if [[ ! -t 0 ]] || ((auto_mode)); then
    # auto_mode flips us to pipe mode because Phase 5 already
    # bound the buffered file to stdin via `exec < "$buffer"`.
    __cp_debug "$debug_mode" 'pipeline-start' 'mode=pipe'
    __cp_run_pipeline \
      "$raw_mode" "$trim_mode" "$prelude_file" \
      "${backend_cmd[@]}" \
      || write_rc=$?
  else
    __cp_debug "$debug_mode" 'pipeline-start' 'mode=argument'
    __cp_run_argument_mode \
      "$raw_mode" "$trim_mode" "$prelude_file" \
      backend_cmd \
      "${positional[@]}" \
      || write_rc=$?
  fi

  [[ -n $prelude_file ]] && rm -f -- "$prelude_file"

  if ((write_rc == 0)); then
    __cp_debug "$debug_mode" 'done' 'mode=pipeline'
  fi

  return "$write_rc"
}

# endregion

# region Execution guard
#
# When the file is executed directly (chmod +x ./copy.sh, or via
# a /usr/local/bin/copy symlink), BASH_SOURCE[0] equals $0 and we
# run the function with the user's arguments.
# When sourced (e.g. from ~/.bashrc), this branch is skipped
# and only the function definitions become available in the shell.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  copy "$@"
  exit "$?"
fi
# endregion

### End of file
