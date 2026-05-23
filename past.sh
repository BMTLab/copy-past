#!/bin/bash

# Name: past.sh
# Author: Nikita Neverov (BMTLab)
# Version: 2.0.0
# Date: 2026-07-03
# License: MIT
#
# Description:
#   Prints the content of the system clipboard (CLIPBOARD) to stdout.
#   Useful for piping clipboard content into other commands or scripts.
#   Integrates with KDE/Klipper and other managers automatically.
#
#   Behavior:
#     - Prints content 'as is' without appending an extra newline
#       (unless the clipboard content itself has one).
#     - On Wayland uses `wl-paste`
#       and strips the single trailing newline
#       that wl-paste appends,
#       while preserving any original trailing newlines.
#       This is a workaround for wl-clipboard ≤ 2.2.1,
#       where `--no-newline` truncates the last line
#       if the clipboard content is not LF-terminated.
#
#   MIME type support:
#     - --type MIME requests a specific MIME type from the backend,
#       useful for reading binary or rich-text payloads
#       written with `copy --type` or `copy --image`.
#     - --json is shorthand for --type application/json.
#     - --image[=FORMAT] is shorthand for --type image/<format>
#       (default png).
#       Output is binary; redirect it to a file:
#         past --image > screenshot.png
#
#   Backend override:
#     - Set COPY_PAST_BACKEND={wl-clipboard|xclip|xsel}
#       to force a specific backend.
#       The same variable is honored by copy.sh,
#       so both halves of a round-trip stay consistent.
#       xsel does not support MIME types,
#       so non-text payloads fall back to an error there.
#
#   Debug logging:
#     - --debug (alias -d / --verbose) emits structured event lines
#       on stderr, prefixed with '[past debug]'.
#       Format: '[past debug] event=<name> key=value key=value'.
#       The flag is silent by default,
#       so existing pipelines are not disturbed.
#
# Usage:
#   # As a standalone script:
#   past.sh > file.txt
#
#   # Sourced:
#   source /path/to/past.sh
#   my_var="$(past)"
#
#   # Binary payloads:
#   past --image > clipboard.png
#
# Exit Codes:
#   0: Success.
#   1: PAST_ERR_GENERAL
#      Generic error.
#   2: PAST_ERR_USAGE
#      Invalid usage or unknown backend override.
#   3: PAST_ERR_NO_BACKEND
#      No suitable clipboard utility found.
#   4: PAST_ERR_BACKEND_FAILED
#      The clipboard utility returned a non-zero exit code.
#   5: PAST_ERR_TYPE_MISMATCH
#      The active backend cannot handle the requested MIME type
#      (e.g., xsel + --json).
#
# Disclaimer:
#   This script is provided 'as is', without any warranty.
#   Ensure required dependencies (wl-clipboard, xclip, or xsel)
#   are installed on your system.

# region Error codes

# These constants are guarded against re-declaration,
# so the script can be sourced repeatedly in the same shell
# without tripping `readonly`.

# bashsupport disable=BP5001

if [[ -z ${PAST_ERR_GENERAL+x} ]]; then
  readonly PAST_ERR_GENERAL=1
fi

if [[ -z ${PAST_ERR_USAGE+x} ]]; then
  readonly PAST_ERR_USAGE=2
fi

if [[ -z ${PAST_ERR_NO_BACKEND+x} ]]; then
  readonly PAST_ERR_NO_BACKEND=3
fi

if [[ -z ${PAST_ERR_BACKEND_FAILED+x} ]]; then
  readonly PAST_ERR_BACKEND_FAILED=4
fi

if [[ -z ${PAST_ERR_TYPE_MISMATCH+x} ]]; then
  readonly PAST_ERR_TYPE_MISMATCH=5
fi

# endregion

# region Internal helpers

#######################################
# Print usage information.
#
# Outputs:
#   Usage text to stdout.
#######################################
function __ps_usage() {
  cat <<'EOF'
past - print system clipboard to stdout

Description:
  Detects the display server and outputs the clipboard content
  using wl-paste, xclip, or xsel.

Usage:
  past > output.txt
  echo "Clipboard contains: $(past)"
  past | cat
  past --image > screenshot.png
  past --help

Options:
  -h, --help            Show this help message.
      --type MIME       Request a specific MIME type from the backend
                        (e.g., application/json, image/png, text/html).
  -j, --json            Shortcut for --type application/json.
      --image[=FORMAT]  Read binary image data with the matching
                        image/<format> MIME type (default png).
  -d, --debug, --verbose
                        Print structured debug events on stderr
                        (lines prefixed with '[past debug]').
                        Has no effect on stdout or the payload.

Environment:
  COPY_PAST_BACKEND     Force a specific backend
                        (wl-clipboard | xclip | xsel).
EOF
}

#######################################
# Print error message and return with code.
#
# Arguments:
#   1: Message text.
#   2: Return code (optional, default: PAST_ERR_GENERAL).
#
# Outputs:
#   Error message to stderr.
#######################################
function __ps_error() {
  local -r message="$1"
  local -ir code="${2:-$PAST_ERR_GENERAL}"

  printf 'ERROR: %s\n' "$message" >&2

  return "$code"
}

#######################################
# Emit a structured debug log line on stderr.
#
# Mirrors __cp_debug in copy.sh
# so both halves of a round-trip share the same log format,
# only the script-name prefix differs:
#
#   [past debug] event=<name> key=value key=value
#
# Values that contain whitespace are wrapped in single quotes.
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
function __ps_debug() {
  local -ir debug_mode=$1
  if ((!debug_mode)); then
    return 0
  fi

  local -r event="$2"
  shift 2

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
    printf '[past debug] event=%s\n' "$event" >&2
  else
    printf '[past debug] event=%s %s\n' "$event" "$suffix" >&2
  fi
}

#######################################
# Check if a command exists.
#
# Arguments:
#   1: Command name.
#
# Returns:
#   0: If exists.
#   1: Otherwise.
#######################################
function __ps_have_cmd() {
  command -v "$1" >/dev/null 2>&1
}

# endregion

# region Backend detection

#######################################
# Detect the best available clipboard 'read' backend.
#
# When COPY_PAST_BACKEND is set, that backend is used
# (and its absence is a hard error).
# Otherwise we prefer Wayland's wl-paste
# when a Wayland session is detected,
# then fall back to xclip, then xsel.
#
# Arguments:
#   1: Name of the array variable (nameref) to store the command.
#
# Returns:
#   0: On success.
#   PAST_ERR_NO_BACKEND: If no backend is available.
#   PAST_ERR_USAGE: If COPY_PAST_BACKEND has an unknown value.
#######################################
function __ps_detect_backend() {
  local -n _backend_command="$1"

  # Step 1: honour an explicit override (env var).
  #
  # We deliberately omit --no-newline here,
  # because wl-paste 2.2.1 has a known bug:
  # it drops the last line
  # when the clipboard content does not end with \n.
  # Instead, we always run wl-paste in its default mode
  # (which appends one \n)
  # and cancel that trailing byte ourselves
  # in __ps_read_wl_paste below.
  case "${COPY_PAST_BACKEND-}" in
    '') ;; # No override; fall through to auto-detection below.

    wl-clipboard | wayland | wl-paste)
      if __ps_have_cmd wl-paste; then
        _backend_command=(wl-paste)
        return 0
      fi
      return "$PAST_ERR_NO_BACKEND"
      ;;

    xclip)
      if __ps_have_cmd xclip; then
        _backend_command=(xclip -selection clipboard -out)
        return 0
      fi
      return "$PAST_ERR_NO_BACKEND"
      ;;

    xsel)
      if __ps_have_cmd xsel; then
        _backend_command=(xsel --clipboard --output)
        return 0
      fi
      return "$PAST_ERR_NO_BACKEND"
      ;;

    *)
      __ps_error \
        "Unknown COPY_PAST_BACKEND value: '${COPY_PAST_BACKEND}' (use wl-clipboard, xclip, or xsel)" \
        "$PAST_ERR_USAGE" \
        || return "$?"
      ;;
  esac

  # Step 2: auto-detection.
  if { [[ -n ${WAYLAND_DISPLAY-} ]] \
    || [[ ${XDG_SESSION_TYPE-} == 'wayland' ]]; } \
    && __ps_have_cmd wl-paste; then
    _backend_command=(wl-paste)
    return 0
  fi

  if __ps_have_cmd xclip; then
    _backend_command=(xclip -selection clipboard -out)
    return 0
  fi

  if __ps_have_cmd xsel; then
    _backend_command=(xsel --clipboard --output)
    return 0
  fi

  return "$PAST_ERR_NO_BACKEND"
}

#######################################
# Append the backend-specific MIME-type flag
# to a backend command array.
#
# Each backend uses a different flag for selecting MIME on read:
#   - wl-paste:  --type MIME
#   - xclip:     -t MIME
#   - xsel:      unsupported (text/plain only)
#
# Arguments:
#   1: Name of the backend command array (nameref).
#   2: MIME type string (e.g. 'application/json').
#
# Returns:
#   0: On success.
#   PAST_ERR_TYPE_MISMATCH: If the backend does not support MIME types.
#######################################
function __ps_apply_mime() {
  local -n _cmd="$1"
  local -r mime="$2"

  case "${_cmd[0]}" in
    wl-paste)
      _cmd+=(--type "$mime")
      return 0
      ;;
    xclip)
      _cmd+=(-t "$mime")
      return 0
      ;;
    xsel)
      __ps_error \
        "xsel does not support MIME types; use wl-clipboard or xclip for '${mime}'" \
        "$PAST_ERR_TYPE_MISMATCH" \
        || return "$?"
      ;;
    *)
      __ps_error \
        "Internal error: unknown backend '${_cmd[0]}' for MIME type" \
        "$PAST_ERR_GENERAL" \
        || return "$?"
      ;;
  esac
}

# endregion

# region wl-paste reader

#######################################
# Read clipboard via wl-paste,
# then strip the trailing newline that wl-paste appends.
# Preserves any newlines that were genuinely part of the clipboard content.
#
# Implementation note:
#   Command substitution $(...) strips trailing newlines,
#   so we use a sentinel character ('x')
#   and capture the exit code of wl-paste itself
#   (NOT the trailing printf, which would mask failures).
#
#   This trick is text-only: capturing binary payloads through $()
#   would corrupt embedded NUL bytes,
#   so callers that target binary MIME types
#   bypass this helper entirely.
#
# Arguments:
#   1..N: backend command and its arguments (typically 'wl-paste').
#
# Returns:
#   0: On success; clipboard content written to stdout.
#   PAST_ERR_BACKEND_FAILED: If wl-paste returns non-zero.
#######################################
function __ps_read_wl_paste() {
  local raw exit_code

  # Run wl-paste, append a sentinel byte,
  # then read its true exit status from a temp variable
  # so $() does not lose it.
  raw="$(
    "$@"
    printf 'x%d' "$?"
  )"

  # Recover the wl-paste exit code:
  # everything after the LAST 'x' in the captured output is the rc,
  # and everything before that 'x' is the real clipboard payload.
  exit_code="${raw##*x}"
  raw="${raw%x*}"

  if [[ -z $exit_code || $exit_code -ne 0 ]]; then
    return "$PAST_ERR_BACKEND_FAILED"
  fi

  # wl-paste (without --no-newline) ALWAYS appends one \n to the
  # output. Strip that one byte; any newlines that were genuinely
  # part of the clipboard content remain untouched.
  raw="${raw%$'\n'}"
  printf '%s' "$raw"
}

# endregion

# region Option model

#######################################
# Initialize the past option struct to its defaults.
#
# State is kept on the caller's stack (no globals)
# and threaded into helpers via Bash namerefs.
# Each `past` invocation therefore starts from a clean slate,
# even when the script is sourced into a long-lived shell.
#
# Arguments:
#   1: nameref to mime_type      (string, '' default).
#   2: nameref to is_binary_mime (int,    0 default).
#   3: nameref to debug_mode     (int,    0 default).
#######################################
function __ps_init_options() {
  local -n _mime_type="$1"
  local -n _is_binary_mime="$2"
  local -n _debug_mode="$3"

  _mime_type=''
  _is_binary_mime=0
  _debug_mode=0
}

#######################################
# Map a bare image format identifier (e.g. 'jpg', 'svg', 'webp')
# to a canonical IANA `image/<...>` MIME type.
#
# Mirrors __cp_image_format_to_mime in copy.sh
# so the two halves of a round-trip stay perfectly in sync.
#
# Arguments:
#   1: nameref to the destination string variable.
#   2: format identifier string (already validated as non-empty).
#######################################
function __ps_image_format_to_mime() {
  # Use a private nameref name distinct from any caller variable,
  # so we never end up with a self-referencing nameref
  # (which Bash silently downgrades to a plain string).
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

#######################################
# Parse the value of a `--type[=]MIME` flag.
#
# Supports both `--type MIME` and `--type=MIME` forms.
# Empty values are rejected with PAST_ERR_USAGE.
#
# Arguments:
#   1:    nameref to mime_type slot.
#   2:    nameref to consumed-arg counter.
#   3..N: remaining argv (only $3 and $4 are inspected).
#
# Returns:
#   0: on success.
#   PAST_ERR_USAGE: when the value is missing or empty.
#######################################
function __ps_parse_type_flag() {
  local -n _mime_out="$1"
  local -n _consumed="$2"
  local -r flag="$3"

  if [[ "$flag" == --type=* ]]; then
    _mime_out="${flag#*=}"
    _consumed=1
  else
    if [[ -z ${4-} ]]; then
      __ps_error '--type requires a MIME argument' \
        "$PAST_ERR_USAGE" \
        || return "$?"
    fi
    _mime_out="$4"
    _consumed=2
  fi

  if [[ -z $_mime_out ]]; then
    __ps_error '--type requires a MIME argument' \
      "$PAST_ERR_USAGE" \
      || return "$?"
  fi
}

#######################################
# Parse the value of an `--image[=FORMAT]` flag.
#
# `--image` alone is treated as `--image=png`.
#
# Arguments:
#   1: nameref to mime_type slot.
#   2: nameref to consumed-arg counter.
#   3: the original flag (`--image` or `--image=FOO`).
#
# Returns:
#   0: on success.
#   PAST_ERR_USAGE: when an empty format is supplied.
#######################################
function __ps_parse_image_flag() {
  local -n _mime_out="$1"
  local -n _consumed="$2"
  local -r flag="$3"

  if [[ "$flag" == '--image' ]]; then
    _mime_out='image/png'
  else
    local -r format="${flag#*=}"
    if [[ -z $format ]]; then
      __ps_error '--image=FORMAT requires a non-empty format' \
        "$PAST_ERR_USAGE" \
        || return "$?"
    fi
    __ps_image_format_to_mime _mime_out "$format"
  fi

  _consumed=1
}

#######################################
# Parse the full argv into the option struct.
#
# Past has a small surface area:
#   -h / --help        : print usage and exit 0
#        --type MIME   : explicit MIME type
#   -j / --json        : sugar for --type application/json
#        --image[=FMT] : sugar for --type image/<fmt>
#   -d / --debug       : turn on the structured stderr log
#        --verbose     : alias for --debug
#
# Any leftover positional arguments are rejected with PAST_ERR_USAGE,
# because past has no notion of positional input.
#
# Arguments:
#   1:    nameref to mime_type  (string).
#   2:    nameref to debug_mode (int).
#   3..N: the original argv to parse.
#
# Returns:
#   0:               parsing succeeded.
#   200:             --help was consumed; caller should exit 0.
#   PAST_ERR_USAGE:  on unknown flags or stray positional args.
#######################################
function __ps_parse_args() {
  local -n _mime="$1"
  local -n _debug="$2"
  shift 2

  local -i consumed=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        __ps_usage
        return 200
        ;;
      --type | --type=*)
        __ps_parse_type_flag _mime consumed "$@" || return "$?"
        shift "$consumed"
        ;;
      --json | -j)
        _mime='application/json'
        shift
        ;;
      --image | --image=*)
        __ps_parse_image_flag _mime consumed "$1" || return "$?"
        shift "$consumed"
        ;;
      -d | --debug | --verbose)
        _debug=1
        shift
        ;;
      *)
        __ps_error "Unknown argument: $1" "$PAST_ERR_USAGE" \
          || return "$?"
        ;;
    esac
  done
}

#######################################
# Classify a MIME string as binary or text-ish.
#
# Binary MIMEs (image/*, application/octet-stream)
# bypass the wl-paste trailing-newline workaround,
# because that workaround is text-only:
# stripping a trailing 0x0A byte from a PNG would corrupt it.
# JSON and text/* are treated as text-ish.
#
# Arguments:
#   1: nameref to a 0/1 sink (set to 1 for binary, 0 for text).
#   2: MIME type string (may be empty).
#######################################
function __ps_classify_mime() {
  local -n _is_binary="$1"
  local -r mime="$2"

  case "$mime" in
    image/* | application/octet-stream) _is_binary=1 ;;
    *) _is_binary=0 ;;
  esac
}

# endregion

# region Backend wiring

#######################################
# Resolve the clipboard backend command and apply an explicit MIME.
#
# Wraps __ps_detect_backend + __ps_apply_mime
# so the orchestrator stays free of duplicated rc-handling.
#
# Arguments:
#   1: nameref to a string array that receives the backend argv.
#   2: explicit MIME type (may be empty; skips __ps_apply_mime).
#
# Returns:
#   0: on success.
#   PAST_ERR_USAGE: on unknown COPY_PAST_BACKEND override.
#   PAST_ERR_NO_BACKEND: when no backend is installed.
#   PAST_ERR_TYPE_MISMATCH: when the MIME flag is incompatible
#                           with the chosen backend (e.g., xsel).
#######################################
function __ps_resolve_backend() {
  local -n _backend="$1"
  local -r mime="$2"

  local -i detect_rc=0
  __ps_detect_backend _backend || detect_rc=$?

  if ((detect_rc != 0)); then
    if ((detect_rc == PAST_ERR_USAGE)); then
      # __ps_detect_backend already emitted its own message.
      return "$detect_rc"
    fi

    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'
    __ps_error "$error_msg" \
      "$PAST_ERR_NO_BACKEND" \
      || return "$?"
  fi

  if [[ -n $mime ]]; then
    __ps_apply_mime _backend "$mime" || return "$?"
  fi
}

# endregion

# region Read pipeline

#######################################
# Stream the clipboard content to stdout.
#
# Routing rules:
#   - wl-paste, text MIME: go through __ps_read_wl_paste
#                          to undo the trailing-newline quirk.
#   - wl-paste, binary MIME: invoke directly,
#                            because the sentinel-and-strip trick
#                            would corrupt embedded NULs.
#   - xclip / xsel: invoke directly in either case,
#                   they emit clipboard bytes verbatim.
#
# Arguments:
#   1: is_binary_mime flag (int).
#   2: nameref to the backend command array.
#
# Returns:
#   0: on success.
#   PAST_ERR_BACKEND_FAILED: when the backend exits non-zero.
#######################################
function __ps_emit_clipboard() {
  local -ir is_binary_mime=$1
  local -n _backend="$2"

  if [[ ${_backend[0]} == 'wl-paste' && $is_binary_mime -eq 0 ]]; then
    if ! __ps_read_wl_paste "${_backend[@]}"; then
      __ps_error 'Clipboard backend failed to read.' \
        "$PAST_ERR_BACKEND_FAILED" \
        || return "$?"
    fi
    return 0
  fi

  if ! "${_backend[@]}"; then
    __ps_error 'Clipboard backend failed to read.' \
      "$PAST_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
}

# endregion

# region Public API

#######################################
# Main function to read from clipboard.
#
# Thin orchestrator: every step lives in its own helper above,
# so this body reads as a sequence of named phases.
# State is kept on the local stack and threaded through helpers
# via Bash namerefs (parameters whose names start with `_`).
# No global state is used; each invocation gets a fresh slate.
#
# Arguments:
#   [-h | --help]
#   [--type MIME | --json | --image[=FORMAT]]
#
# Returns:
#   0: on success.
#   Non-zero: on error (see header for code list).
#######################################
function past() {
  # Phase 1: option struct.
  local mime_type
  local -i is_binary_mime debug_mode
  __ps_init_options mime_type is_binary_mime debug_mode

  # Phase 2: parse argv.
  local -i parse_rc=0
  __ps_parse_args mime_type debug_mode "$@" || parse_rc=$?

  if ((parse_rc == 200)); then
    # --help was consumed; usage already printed.
    return 0
  fi
  if ((parse_rc != 0)); then
    return "$parse_rc"
  fi

  __ps_debug "$debug_mode" 'options-parsed' \
    "mime=${mime_type:-<none>}"

  # Phase 3: classify the requested MIME
  # so the read step knows
  # whether to apply the trailing-newline workaround.
  __ps_classify_mime is_binary_mime "$mime_type"

  __ps_debug "$debug_mode" 'mime-classified' \
    "is-binary=${is_binary_mime}"

  # Phase 4: backend resolution (+ explicit --type application).
  # shellcheck disable=SC2034 # passed by name (nameref) into helpers
  local -a backend_cmd
  __ps_resolve_backend backend_cmd "$mime_type" || return "$?"

  __ps_debug "$debug_mode" 'backend-resolved' \
    "backend=${backend_cmd[0]}"

  # Phase 5: stream clipboard content to stdout.
  if [[ ${backend_cmd[0]} == 'wl-paste' && $is_binary_mime -eq 0 ]]; then
    __ps_debug "$debug_mode" 'read-strategy' \
      'mode=wl-paste-newline-strip'
  else
    __ps_debug "$debug_mode" 'read-strategy' \
      'mode=direct-exec'
  fi

  __ps_emit_clipboard "$is_binary_mime" backend_cmd
}

# endregion

# region Execution guard

# When the file is executed directly (not sourced),
# run the main function and propagate its exit code.
# If sourced, do nothing (expose past() as a function).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  past "$@"
  exit "$?"
fi
# endregion

### End of file
