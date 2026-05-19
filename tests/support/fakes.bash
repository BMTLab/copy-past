#!/bin/bash

# Name: tests/support/fakes.bash
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Hermetic fake-backend setup for the bats suite.
#
#   Provides shadow binaries for wl-copy / wl-paste / xclip / xsel
#   on a per-test PATH, so the suite can exercise the full clipboard
#   pipeline without touching the host's real clipboard.
#
#   The fakes share state via a single file ($FAKE_CLIPBOARD_FILE),
#   so that copy() and past() round-trip through it.
#
#   Loaded automatically by tests/support/test_helper.bash;
#   do not load it directly from a test file.

# region Setup

#######################################
# Build a fake backend bin directory that shadows real clipboard tools.
#
# Globals set:
#   FAKE_BIN              Directory prepended to PATH.
#   FAKE_CLIPBOARD_FILE   File holding clipboard contents.
#   PATH                  Prefixed with FAKE_BIN.
#   WAYLAND_DISPLAY       Set to force the Wayland code path.
#   XDG_SESSION_TYPE      Cleared (we rely on WAYLAND_DISPLAY).
#######################################
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
  # Binary MIMEs (image/*, application/octet-stream)
  # are emitted verbatim, mirroring wl-paste's real behaviour:
  # for binary types it does not inject a trailing newline.
  # That keeps past --image byte-for-byte tests realistic.
  #
  # FAKE_WL_PASTE_RC lets a test simulate backend failures
  # (e.g. compositor unavailable, or empty selection in some
  # compositors). Defaults to 0 when unset.
  cat > "${FAKE_BIN}/wl-paste" << EOF
#!/usr/bin/env bash
no_newline=0
binary_mime=0
prev=''
for arg in "\$@"; do
  if [[ "\$arg" == '--no-newline' ]]; then
    no_newline=1
  fi
  if [[ "\$prev" == '--type' || "\$prev" == '-t' ]]; then
    case "\$arg" in
      image/*|application/octet-stream) binary_mime=1 ;;
    esac
  fi
  prev="\$arg"
done

if (( no_newline || binary_mime )); then
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

#######################################
# Replace the failing xclip stub with a working one
# that shares the same clipboard file as wl-copy.
# Used by backend-override tests.
#######################################
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

#######################################
# Replace the failing xsel stub with a working one.
#######################################
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

#######################################
# Make wl-copy / wl-paste fakes unavailable.
# Used by override tests that target xclip/xsel only.
#######################################
__cp_disable_wl() {
  rm -f "${FAKE_BIN}/wl-copy" "${FAKE_BIN}/wl-paste"
}

#######################################
# Replace the wl-copy fake with one that exits with the given code
# AFTER consuming stdin. Used by regression tests that need to
# simulate backend failures while keeping the pipeline shape intact.
#
# Arguments:
#   1: exit code the fake should return (1..255).
#######################################
__cp_install_failing_wl_copy() {
  local -r exit_code="$1"
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
cat > /dev/null
exit ${exit_code}
EOF
  chmod +x "${FAKE_BIN}/wl-copy"
}

# endregion

### End of file
