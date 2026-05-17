#!/bin/bash

# Name: tests/bats/test_helper.bash
# Author: Nikita Neverov (BMTLab)
# Version: 1.0.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   Shared bats test helper for the copy-past suite.
#   Provides a fake clipboard backend so tests are hermetic
#   and do not touch the real system clipboard.
#   The fake backend records writes to a temp file
#   and serves reads from that same file,
#   mimicking wl-copy / wl-paste semantics
#   closely enough for behavioural coverage.

# Path of the project root (parent of tests/).
COPY_PAST_ROOT="${BATS_TEST_DIRNAME}/../.."

# region Setup

# Build a fake backend bin directory that shadows real clipboard tools
# (wl-copy, wl-paste, xclip, xsel).
# The fakes share state via the file at $FAKE_CLIPBOARD_FILE,
# so that copy + past can round-trip through it.
#
# Globals set:
#   FAKE_BIN              Directory prepended to PATH.
#   FAKE_CLIPBOARD_FILE   File holding clipboard contents.
#   PATH                  Prefixed with FAKE_BIN.
#   WAYLAND_DISPLAY       Set to force the Wayland code path.
#   XDG_SESSION_TYPE      Cleared (we rely on WAYLAND_DISPLAY).
__cp_setup_fake_backend() {
  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  FAKE_CLIPBOARD_FILE="${BATS_TEST_TMPDIR}/clipboard.bin"
  mkdir -p "$FAKE_BIN"
  : > "$FAKE_CLIPBOARD_FILE"

  # Fake wl-copy: read stdin into the clipboard file.
  # Ignores all flags it receives (--foreground, --type, etc.):
  # they don't change the on-disk semantics for our tests.
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Fake wl-paste: emit clipboard content.
  #
  # Without --no-newline, the real wl-paste
  # ALWAYS appends a single \n unconditionally
  # (it does not check whether the clipboard already ends with one,
  # so the output may end up with two trailing newlines).
  # past.sh's logic relies on stripping exactly one of those.
  #
  # FAKE_WL_PASTE_RC lets a test simulate backend failures
  # (e.g. compositor unavailable, or empty selection in some
  # compositors). Defaults to 0 when unset.
  cat > "${FAKE_BIN}/wl-paste" << EOF
#!/usr/bin/env bash
no_newline=0
for arg in "\$@"; do
  if [[ "\$arg" == '--no-newline' ]]; then
    no_newline=1
  fi
done

if (( no_newline )); then
  cat "${FAKE_CLIPBOARD_FILE}"
else
  cat "${FAKE_CLIPBOARD_FILE}"
  printf '\n'
fi

exit "\${FAKE_WL_PASTE_RC:-0}"
EOF
  chmod +x "${FAKE_BIN}/wl-paste"

  # Disable xclip/xsel by default,
  # so detection unambiguously picks wl-copy.
  # Individual tests that need to exercise the X11 path
  # call __cp_enable_xclip_fake / __cp_enable_xsel_fake
  # to install working stubs.
  for stub in xclip xsel; do
    cat > "${FAKE_BIN}/${stub}" << 'EOF'
#!/usr/bin/env bash
echo "fake ${0##*/} should not be called" >&2
exit 99
EOF
    chmod +x "${FAKE_BIN}/${stub}"
  done

  PATH="${FAKE_BIN}:${PATH}"
  export PATH
  export WAYLAND_DISPLAY='fake-wayland-0'
  unset XDG_SESSION_TYPE

  # Ensure no stray override from the parent shell leaks into tests.
  # Individual tests opt in by exporting the variable
  # inside their own subshell.
  unset COPY_PAST_BACKEND
}

# endregion

# region Backend togglers

# Replace the failing xclip stub with a working one
# that shares the same clipboard file as wl-copy.
# Used by backend-override tests.
__cp_enable_xclip_fake() {
  cat > "${FAKE_BIN}/xclip" << EOF
#!/usr/bin/env bash
mode=in
for arg in "\$@"; do
  case "\$arg" in
    -in)  mode=in  ;;
    -out) mode=out ;;
  esac
done

if [[ "\$mode" == 'in' ]]; then
  cat > "${FAKE_CLIPBOARD_FILE}"
else
  cat "${FAKE_CLIPBOARD_FILE}"
fi
EOF
  chmod +x "${FAKE_BIN}/xclip"
}

# Replace the failing xsel stub with a working one.
__cp_enable_xsel_fake() {
  cat > "${FAKE_BIN}/xsel" << EOF
#!/usr/bin/env bash
mode=out
for arg in "\$@"; do
  case "\$arg" in
    --input)  mode=in  ;;
    --output) mode=out ;;
  esac
done

if [[ "\$mode" == 'in' ]]; then
  cat > "${FAKE_CLIPBOARD_FILE}"
else
  cat "${FAKE_CLIPBOARD_FILE}"
fi
EOF
  chmod +x "${FAKE_BIN}/xsel"
}

# Make wl-copy / wl-paste fakes unavailable.
# Used by override tests that target xclip/xsel only.
__cp_disable_wl() {
  rm -f "${FAKE_BIN}/wl-copy" "${FAKE_BIN}/wl-paste"
}

# endregion

# region Inspection

# Read the raw clipboard contents recorded by the fake backend.
__cp_clipboard_dump() {
  cat "$FAKE_CLIPBOARD_FILE"
}

# Pre-load the clipboard with arbitrary bytes (used by past tests).
__cp_clipboard_set() {
  printf '%s' "$1" > "$FAKE_CLIPBOARD_FILE"
}

# endregion

# region Script loader

# Run a snippet under a pseudo-terminal so that
# `if [[ ! -t 0 ]]; then # pipe mode` evaluates to false
# and the script enters argument-mode.
#
# Why this is needed:
#   bats by itself does not allocate a pty for `run`,
#   and `bash -c` inherits whatever stdin bats has.
#   When bats is launched from a non-interactive shell (CI),
#   stdin is a pipe, not a tty,
#   so argument-mode code paths cannot be reached
#   without explicit pty allocation.
#
# Implementation note:
#   util-linux `script -qec '<cmd>' /dev/null` looks tempting,
#   but `script` runs the command string through /bin/sh, which
#   does not understand bash quoting like $'…' and `[[`.
#   We sidestep that by writing the snippet to a temp file and
#   asking script to run it via an explicit bash invocation.
#
# Cross-platform notes:
#   - util-linux script (Linux) and BSD script (macOS) share
#     `-q`, but their argv layouts diverge slightly.
#   - The temp file is auto-cleaned at end of the bats test,
#     because $BATS_TEST_TMPDIR is recreated per-test.
#
# Arguments:
#   $@: the shell snippet to execute (single string).
__cp_run_with_tty() {
  local -r snippet="$*"
  local bash_bin
  bash_bin="$(command -v bash)"

  local script_file="${BATS_TEST_TMPDIR:-/tmp}/__cp_tty_snippet.sh"
  {
    printf '#!%s\n' "$bash_bin"
    printf '%s\n' "$snippet"
  } > "$script_file"
  chmod +x "$script_file"

  if [[ "$(uname -s)" == 'Darwin' ]]; then
    # BSD script: `script [-q] file [command...]`
    script -q /dev/null "$bash_bin" "$script_file" < /dev/null
  else
    # util-linux script: `script [-q] [-c command] file`.
    # Pass an explicit bash invocation so the snippet does not
    # have to pass through script's default /bin/sh wrapper.
    script -qec "$bash_bin $script_file" /dev/null < /dev/null
  fi
}

# Source copy.sh / past.sh into the current shell,
# so tests can call the functions directly.
# Both scripts' execution guards skip auto-running when sourced.
__cp_load_scripts() {
  # shellcheck source=../../copy.sh
  source "${COPY_PAST_ROOT}/copy.sh"
  # shellcheck source=../../past.sh
  source "${COPY_PAST_ROOT}/past.sh"
}

# endregion

### End of file