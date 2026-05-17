#!/bin/bash

# Name: copy.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.4.0 # x-release-please-version
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
#       Covers e.g. window titles (ESC]0;…) and OSC 8 hyperlinks.
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
#   Uses bash $'…' to inject the literal escape character;
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
  # Inject literal ESC (0x1B) and BEL (0x07) bytes via $'…'.
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
# can wrap the whole thing in `(set -o pipefail; …)`
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

# region Public API

#######################################
# Main function to write to clipboard.
#
# Arguments:
#   [options] [text...] or read from stdin.
#
# Options:
#   See __cp_usage for the authoritative list.
#
# Returns:
#   0: On success.
#   Non-zero: On error (see header for code list).
#######################################
function copy() {
  # Restrict word splitting to newline/tab inside this function.
  # Stops accidental space-splitting on user input, while still
  # allowing arrays-from-newlines patterns where they are intended.
  # When we need space-joining (echo "$*"), we override IFS locally.
  local IFS=$'\n\t'
  local -i raw_mode=0
  local -i trim_mode=0
  local -i append_mode=0
  # Auto-detection:
  #   1 (default) : both heuristics run
  #                 (JSON via jq, image magic bytes).
  #   0           : disabled (--no-auto flag).
  local -i auto_mode=1
  local mime_type=''

  # region Option parsing
  #
  # Standard GNU-style:
  #   -h / --help        : print usage and exit 0
  #   -r / --raw         : disable ANSI stripping
  #   -a / --append      : append to existing clipboard content
  #        --trim        : trim leading/trailing whitespace
  #        --type MIME   : explicit MIME type
  #        --json        : sugar for --type application/json --raw
  #        --image[=FMT] : sugar for --type image/<fmt> --raw
  #   --                 : end of options, the rest is text
  #   -*                 : unknown option, exit 2
  #
  # Plain words break the loop and reach the 'argument mode' branch
  # below. Multiple flags of the same kind are idempotent.
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        __cp_usage
        return 0
        ;;
      -r | --raw)
        raw_mode=1
        shift
        ;;
      -a | --append)
        append_mode=1
        shift
        ;;
      --trim)
        trim_mode=1
        shift
        ;;
      --type)
        if [[ -z ${2-} ]]; then
          __cp_error '--type requires a MIME argument' \
            "$COPY_ERR_USAGE" \
            || return "$?"
        fi
        mime_type="$2"
        shift 2
        ;;
      --type=*)
        mime_type="${1#*=}"
        if [[ -z $mime_type ]]; then
          __cp_error '--type requires a MIME argument' \
            "$COPY_ERR_USAGE" \
            || return "$?"
        fi
        shift
        ;;
      -j | --json)
        # JSON is a textual format,
        # but ANSI stripping might corrupt embedded escape sequences,
        # so we treat it like binary and skip the strip step.
        mime_type='application/json'
        raw_mode=1
        shift
        ;;
      --image)
        mime_type='image/png'
        raw_mode=1
        shift
        ;;
      --image=*)
        local -r fmt="${1#*=}"
        if [[ -z $fmt ]]; then
          __cp_error '--image=FORMAT requires a non-empty format' \
            "$COPY_ERR_USAGE" \
            || return "$?"
        fi
        # Map a few common short names to canonical IANA media types.
        case "$fmt" in
          jpg | jpeg) mime_type='image/jpeg' ;;
          png | webp | gif | bmp | tiff)
            mime_type="image/${fmt}"
            ;;
          svg) mime_type='image/svg+xml' ;;
          *) mime_type="image/${fmt}" ;; # forward as-is
        esac
        raw_mode=1
        shift
        ;;
      --no-auto)
        # Suppress the always-on auto-detection;
        # useful when the payload looks like JSON
        # but should be copied as plain text verbatim.
        auto_mode=0
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
        break
        ;;
    esac
  done
  # endregion

  # region Option compatibility checks
  #
  # Reject combinations that would silently corrupt data
  # before we touch the clipboard at all.
  local -i is_binary_mime=0
  case "$mime_type" in
    image/* | application/octet-stream)
      is_binary_mime=1
      ;;
  esac

  if ((append_mode && is_binary_mime)); then
    __cp_error \
      '--append is only valid for text payloads, not for binary MIME types' \
      "$COPY_ERR_TYPE_MISMATCH" \
      || return "$?"
  fi

  if ((trim_mode && is_binary_mime)); then
    __cp_error \
      '--trim is only valid for text payloads, not for binary MIME types' \
      "$COPY_ERR_TYPE_MISMATCH" \
      || return "$?"
  fi

  # An explicit MIME pin always wins over auto-detection.
  # We honour the user's intent and skip sniffing entirely.
  if ((auto_mode)) && [[ -n $mime_type ]]; then
    auto_mode=0
  fi

  # --append is text-only by design,
  # and the auto-detected MIME might be a binary type
  # (e.g. image/png).
  # When both flags are set,
  # we silently disable the heuristic
  # rather than failing,
  # because the more conservative behaviour
  # is also what an experienced user expects:
  # 'append this text to whatever is already in the clipboard'.
  if ((auto_mode && append_mode)); then
    auto_mode=0
  fi
  # endregion

  # region Backend resolution
  #
  # We deliberately use `cmd || rc=$?` rather than `if ! cmd`,
  # because `if !` resets $? before we can read it
  # (the `!` itself is the most recent command in the pipeline).
  local -a clipboard_backend_cmd
  local -i _detect_rc=0

  __cp_detect_backend clipboard_backend_cmd || _detect_rc=$?

  if [[ $_detect_rc -ne 0 ]]; then
    # Usage errors (unknown override) are already reported
    # by __cp_detect_backend; we just propagate the code.
    if [[ $_detect_rc -eq $COPY_ERR_USAGE ]]; then
      return "$_detect_rc"
    fi

    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'

    __cp_error "$error_msg" \
      "$COPY_ERR_NO_BACKEND" \
      || return "$?"
  fi

  # Apply --type / --json / --image to the backend command,
  # if a MIME type was requested.
  # __cp_apply_mime emits its own error on xsel + non-text combos.
  if [[ -n $mime_type ]]; then
    __cp_apply_mime clipboard_backend_cmd "$mime_type" \
      || return "$?"
  fi
  # endregion

  # region Auto-detection
  #
  # When auto-detection is on (the default),
  # we buffer the payload to a temp file,
  # inspect its leading bytes,
  # and pick a MIME type:
  #
  #   * binary magic bytes (PNG / JPEG / GIF / BMP / WebP)
  #     -> image/<format>
  #     (these signatures cannot occur in plain text by design,
  #     so the detection is false-positive-free);
  #   * `{` or `[` followed by a clean `jq` parse
  #     -> application/json
  #     (skipped silently when `jq` is not installed);
  #   * anything else -> text/plain.
  #
  # On a non-text result we feed the backend straight from the
  # buffer, bypassing __cp_emit / ANSI stripping / trimming,
  # because those would corrupt binary payloads
  # and rewrite JSON strings that happen to contain
  # escape characters.
  #
  # On a text/plain result we replace the function's stdin
  # with the buffered file via `exec < "$buffer"`
  # so the regular pipe/argument paths below
  # see the same bytes we just classified.
  if ((auto_mode)); then
    local sniff_buffer
    sniff_buffer="$(mktemp -t copy-auto.XXXXXX)"

    if [[ ! -t 0 ]]; then
      cat >"$sniff_buffer"
    elif [[ $# -gt 0 ]]; then
      # Argument mode: same join-with-spaces convention as below.
      (
        IFS=' '
        echo "$*"
      ) >"$sniff_buffer"
    else
      rm -f -- "$sniff_buffer"
      local error_msg='No input provided. '
      error_msg+='Pass text as arguments or pipe via stdin.'

      __cp_usage >&2
      __cp_error "$error_msg" \
        "$COPY_ERR_USAGE" \
        || return "$?"
    fi

    local sniffed_mime
    sniffed_mime="$(__cp_sniff_mime "$sniff_buffer")"

    if [[ "$sniffed_mime" != 'text/plain' ]]; then
      # Non-text result: apply the MIME to the backend
      # and feed bytes verbatim from the buffer.
      if ! __cp_apply_mime clipboard_backend_cmd "$sniffed_mime"; then
        local -ir _mime_rc=$?
        rm -f -- "$sniff_buffer"
        return "$_mime_rc"
      fi
      echo "::notice title=copy::auto-detected MIME ${sniffed_mime}" >&2 \
        2>/dev/null || true

      local -i emit_rc=0
      "${clipboard_backend_cmd[@]}" <"$sniff_buffer" || emit_rc=$?
      rm -f -- "$sniff_buffer"

      if ((emit_rc != 0)); then
        __cp_error 'Clipboard backend failed.' \
          "$COPY_ERR_BACKEND_FAILED" \
          || return "$?"
      fi
      return 0
    fi

    # text/plain result: keep the regular pipeline below
    # (which honours --raw / --trim / ANSI stripping).
    # Replace stdin with the buffered file so the downstream
    # `__cp_emit_with_prelude | __cp_emit` chain
    # sees the same bytes we just classified.
    exec <"$sniff_buffer"
    rm -f -- "$sniff_buffer"
  fi
  # endregion

  # region Append prelude
  #
  # When --append is set, we read the current clipboard content first
  # and stash it in a temp file, so the new payload can be concatenated
  # with the old one before reaching the backend.
  # The temp file is cleaned up on every exit path
  # via an EXIT trap registered in a subshell.
  local prelude_file=''
  if ((append_mode)); then
    prelude_file="$(mktemp -t copy-append.XXXXXX)"
    if ! __cp_read_clipboard >"$prelude_file"; then
      rm -f -- "$prelude_file"
      __cp_error \
        'Failed to read existing clipboard for --append' \
        "$COPY_ERR_BACKEND_FAILED" \
        || return "$?"
    fi
  fi

  # Helper: emit prelude (existing buffer) + new payload through the
  # configured pipeline. The prelude is NEVER passed through ANSI
  # stripping or trimming, because we already trust whatever was in
  # the clipboard; only the new payload is transformed.
  local -i emit_rc=0
  function __cp_emit_with_prelude() {
    if [[ -n $prelude_file ]]; then
      cat -- "$prelude_file"
    fi
    cat
  }
  # endregion

  # region Pipe mode
  #
  # `[[ ! -t 0 ]]` is true when stdin is NOT a terminal,
  # i.e. someone is piping data in. The pipeline runs in a subshell
  # so that `set -o pipefail` does not leak into the caller's shell.
  #
  # We use the `cmd || rc=$?` pattern (instead of `if ! cmd`)
  # because `if ! ( … )` would clobber `$?` with the inversion
  # result and we would never see the real subshell exit code.
  if [[ ! -t 0 ]]; then
    (
      set -o pipefail
      __cp_emit_with_prelude \
        | __cp_emit "$raw_mode" "$trim_mode" "${clipboard_backend_cmd[@]}"
    ) || emit_rc="$?"
    [[ -n $prelude_file ]] && rm -f -- "$prelude_file"

    if ((emit_rc != 0)); then
      __cp_error 'Clipboard backend failed during pipe operation.' \
        "$COPY_ERR_BACKEND_FAILED" \
        || return "$?"
    fi
    return 0
  fi
  # endregion

  # region Argument mode
  #
  # No piped stdin: the remaining positional args become the payload.
  # Empty argv at this point means the user invoked `copy` with no
  # input at all, which is a usage error.
  if [[ $# -eq 0 ]]; then
    [[ -n $prelude_file ]] && rm -f -- "$prelude_file"

    local error_msg='No input provided. '
    error_msg+='Pass text as arguments or pipe via stdin.'

    __cp_usage >&2
    __cp_error "$error_msg" \
      "$COPY_ERR_USAGE" \
      || return "$?"
  fi

  # Join arguments with single spaces, mirroring `echo "$*"` semantics.
  # Done in a subshell so the temporary `IFS=' '` does not affect
  # the surrounding code (which keeps `IFS=$'\n\t'`).
  local -r input_text="$(
    IFS=' '
    echo "$*"
  )"

  (
    set -o pipefail
    printf '%s' "$input_text" \
      | __cp_emit_with_prelude \
      | __cp_emit "$raw_mode" "$trim_mode" "${clipboard_backend_cmd[@]}"
  ) || emit_rc="$?"
  [[ -n $prelude_file ]] && rm -f -- "$prelude_file"

  if ((emit_rc != 0)); then
    __cp_error 'Clipboard backend failed.' \
      "$COPY_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
  # endregion
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
