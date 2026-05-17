#!/bin/bash

# Name: past.sh
# Author: Nikita Neverov (BMTLab)
# Version: 1.4.0 # x-release-please-version
# Date: 2026-05-17
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
#     - On Wayland uses `wl-paste` and strips
#       the single trailing newline that wl-paste appends,
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
#       The same variable is honoured by copy.sh,
#       so both halves of a round-trip stay consistent.
#       xsel does not support MIME types,
#       so non-text payloads fall back to an error there.
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
                        (e.g. application/json, image/png, text/html).
  -j, --json            Shortcut for --type application/json.
      --image[=FORMAT]  Read binary image data with the matching
                        image/<format> MIME type (default png).

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
# When COPY_PAST_BACKEND is set, that backend is used (and its
# absence is a hard error). Otherwise we prefer Wayland's wl-paste
# when a Wayland session is detected, then fall back to xclip,
# then xsel.
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
  # We deliberately omit --no-newline here, because wl-paste 2.2.1
  # has a known bug: it drops the last line when the clipboard
  # content does not end with \n. Instead, we always run wl-paste
  # in its default mode (which appends one \n) and cancel that
  # trailing byte ourselves in __ps_read_wl_paste below.
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
#   Command substitution $(…) strips trailing newlines,
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

# region Public API

#######################################
# Main function to read from clipboard.
#
# Arguments:
#   [-h | --help]
#   [--type MIME | --json | --image[=FORMAT]]
#
# Returns:
#   0: On success.
#   Non-zero: On error (see header for code list).
#######################################
function past() {
  local mime_type=''
  # When MIME is binary, we bypass the trailing-newline workaround
  # because it would corrupt the payload.
  local -i is_binary_mime=0

  # region Argument parsing
  #
  # past has a small surface area:
  #   -h / --help        : print usage and exit 0
  #        --type MIME   : explicit MIME type
  #        --json        : sugar for --type application/json
  #        --image[=FMT] : sugar for --type image/<fmt>
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        __ps_usage
        return 0
        ;;
      --type)
        if [[ -z ${2-} ]]; then
          __ps_error '--type requires a MIME argument' \
            "$PAST_ERR_USAGE" \
            || return "$?"
        fi
        mime_type="$2"
        shift 2
        ;;
      --type=*)
        mime_type="${1#*=}"
        if [[ -z $mime_type ]]; then
          __ps_error '--type requires a MIME argument' \
            "$PAST_ERR_USAGE" \
            || return "$?"
        fi
        shift
        ;;
      --json | -j)
        mime_type='application/json'
        shift
        ;;
      --image)
        mime_type='image/png'
        shift
        ;;
      --image=*)
        local -r fmt="${1#*=}"
        if [[ -z $fmt ]]; then
          __ps_error '--image=FORMAT requires a non-empty format' \
            "$PAST_ERR_USAGE" \
            || return "$?"
        fi
        case "$fmt" in
          jpg | jpeg) mime_type='image/jpeg' ;;
          png | webp | gif | bmp | tiff)
            mime_type="image/${fmt}"
            ;;
          svg) mime_type='image/svg+xml' ;;
          *) mime_type="image/${fmt}" ;;
        esac
        shift
        ;;
      *)
        __ps_error "Unknown argument: $1" "$PAST_ERR_USAGE" \
          || return "$?"
        ;;
    esac
  done

  case "$mime_type" in
    image/* | application/octet-stream)
      is_binary_mime=1
      ;;
  esac
  # endregion

  # region Backend resolution
  #
  # `cmd || rc=$?` keeps $? readable; `if ! cmd` would clobber it.
  local -a clipboard_backend_cmd
  local -i _detect_rc=0

  __ps_detect_backend clipboard_backend_cmd || _detect_rc=$?

  if [[ $_detect_rc -ne 0 ]]; then
    if [[ $_detect_rc -eq $PAST_ERR_USAGE ]]; then
      # __ps_detect_backend already printed the error.
      return "$_detect_rc"
    fi

    local error_msg='No clipboard backend found. '
    error_msg+='Install wl-clipboard, xclip, or xsel.'

    __ps_error "$error_msg" \
      "$PAST_ERR_NO_BACKEND" \
      || return "$?"
  fi

  if [[ -n $mime_type ]]; then
    __ps_apply_mime clipboard_backend_cmd "$mime_type" \
      || return "$?"
  fi
  # endregion

  # region Read clipboard
  #
  # wl-paste needs the trailing-newline workaround for text payloads,
  # so it goes through __ps_read_wl_paste.
  # For binary MIME types
  # (image/*, application/octet-stream),
  # we exec wl-paste directly to preserve every byte intact.
  # xclip and xsel emit clipboard bytes verbatim,
  # so we just exec them directly in either case.
  if [[ ${clipboard_backend_cmd[0]} == 'wl-paste' && $is_binary_mime -eq 0 ]]; then
    if ! __ps_read_wl_paste "${clipboard_backend_cmd[@]}"; then
      __ps_error 'Clipboard backend failed to read.' \
        "$PAST_ERR_BACKEND_FAILED" \
        || return "$?"
    fi
    return 0
  fi

  if ! "${clipboard_backend_cmd[@]}"; then
    __ps_error 'Clipboard backend failed to read.' \
      "$PAST_ERR_BACKEND_FAILED" \
      || return "$?"
  fi
  # endregion
}

# endregion

# region Execution guard
#
# When the file is executed directly (not sourced),
# run the main function and propagate its exit code.
# If sourced, do nothing (just expose past() as a function).
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
  past "$@"
  exit "$?"
fi
# endregion

### End of file
