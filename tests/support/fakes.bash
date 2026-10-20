#!/usr/bin/env bash

# Put fake clipboard backends first on PATH, so no test touches the real clipboard.

# region Setup

#######################################
# Make fake wl-copy, wl-paste, xclip and xsel, and put them first on PATH.
#
# The fakes share one file as the clipboard,
# so copy and past make a round trip through it.
# xclip and xsel fail until a test turns them on,
# so detection always takes wl-copy.
# Each temporary file of copy goes to the directory of the test,
# which bats removes.
#
# Globals:
#   FAKE_BIN: set to the directory of the fakes.
#   FAKE_CLIPBOARD_FILE: set to the file that holds the clipboard.
#   PATH, TMPDIR, WAYLAND_DISPLAY: set and exported.
#   XDG_SESSION_TYPE, COPY_PAST_BACKEND: unset.
#######################################
function setup_fake_backends() {
  local stub

  FAKE_BIN="${BATS_TEST_TMPDIR}/fake-bin"
  FAKE_CLIPBOARD_FILE="${BATS_TEST_TMPDIR}/clipboard.bin"
  mkdir -p -- "${FAKE_BIN}"
  : >"${FAKE_CLIPBOARD_FILE}"

  # wl-copy reads stdin into the clipboard;
  # its options, such as --type, change nothing in the file.
  cat >"${FAKE_BIN}/wl-copy" <<EOF
#!/usr/bin/env bash
cat >${FAKE_CLIPBOARD_FILE@Q}
EOF
  chmod +x -- "${FAKE_BIN}/wl-copy"

  # Without --no-newline, the real wl-paste adds one newline to text,
  # even after a newline of the text itself; past removes exactly one.
  # A binary MIME type comes out as it is, as with the real wl-paste.
  # FAKE_WL_PASTE_CODE makes it fail, as a lost compositor would.
  cat >"${FAKE_BIN}/wl-paste" <<EOF
#!/usr/bin/env bash
is_raw=0
previous=''
for argument in "\$@"; do
  if [[ "\${argument}" == '--no-newline' ]]; then
    is_raw=1
  fi
  if [[ "\${previous}" == '--type' || "\${previous}" == '-t' ]]; then
    case "\${argument}" in
      image/* | application/octet-stream) is_raw=1 ;;
    esac
  fi
  previous="\${argument}"
done

cat ${FAKE_CLIPBOARD_FILE@Q}
if ((!is_raw)); then
  printf '\n'
fi

exit "\${FAKE_WL_PASTE_CODE:-0}"
EOF
  chmod +x -- "${FAKE_BIN}/wl-paste"

  for stub in xclip xsel; do
    cat >"${FAKE_BIN}/${stub}" <<'EOF'
#!/usr/bin/env bash
printf 'fake %s should not be called\n' "${0##*/}" >&2
exit 99
EOF
    chmod +x -- "${FAKE_BIN}/${stub}"
  done

  export PATH="${FAKE_BIN}:${PATH}"
  export TMPDIR="${BATS_TEST_TMPDIR}"
  export WAYLAND_DISPLAY='fake-wayland-0'
  unset XDG_SESSION_TYPE

  # A test that wants a backend exports the variable itself.
  unset COPY_PAST_BACKEND
}

# endregion Setup

# region Backend switches

#######################################
# Replace the failing xclip with one that shares the clipboard file.
#
# Globals:
#   FAKE_BIN, FAKE_CLIPBOARD_FILE: read.
#######################################
function enable_fake_xclip() {
  cat >"${FAKE_BIN}/xclip" <<EOF
#!/usr/bin/env bash
mode='in'
for argument in "\$@"; do
  case "\${argument}" in
    -in) mode='in' ;;
    -out) mode='out' ;;
  esac
done

if [[ "\${mode}" == 'in' ]]; then
  cat >${FAKE_CLIPBOARD_FILE@Q}
else
  cat ${FAKE_CLIPBOARD_FILE@Q}
fi
EOF
  chmod +x -- "${FAKE_BIN}/xclip"
}

#######################################
# Replace the failing xsel with one that shares the clipboard file.
#
# Globals:
#   FAKE_BIN, FAKE_CLIPBOARD_FILE: read.
#######################################
function enable_fake_xsel() {
  cat >"${FAKE_BIN}/xsel" <<EOF
#!/usr/bin/env bash
mode='out'
for argument in "\$@"; do
  case "\${argument}" in
    --input) mode='in' ;;
    --output) mode='out' ;;
  esac
done

if [[ "\${mode}" == 'in' ]]; then
  cat >${FAKE_CLIPBOARD_FILE@Q}
else
  cat ${FAKE_CLIPBOARD_FILE@Q}
fi
EOF
  chmod +x -- "${FAKE_BIN}/xsel"
}

#######################################
# Remove the fake wl-copy and wl-paste.
#
# Globals:
#   FAKE_BIN: read.
#######################################
function disable_fake_wl_clipboard() {
  rm -f -- "${FAKE_BIN}/wl-copy" "${FAKE_BIN}/wl-paste"
}

#######################################
# Replace wl-copy with one that reads stdin and then fails,
# so a pipeline keeps its shape while its backend fails.
#
# Arguments:
#   1: The exit code of the fake, 1 to 255.
#   2: A message the fake prints to stderr first; optional.
#
# Globals:
#   FAKE_BIN: read.
#######################################
function install_failing_wl_copy() {
  local -r exit_code="$1"
  local -r message="${2:-}"

  cat >"${FAKE_BIN}/wl-copy" <<EOF
#!/usr/bin/env bash
cat >/dev/null
if [[ -n ${message@Q} ]]; then
  printf '%s\n' ${message@Q} >&2
fi
exit ${exit_code@Q}
EOF
  chmod +x -- "${FAKE_BIN}/wl-copy"
}

#######################################
# Replace wl-copy with one that, like the real wl-copy,
# leaves a process behind that keeps the stdout and stderr it got,
# as the server of the clipboard does until another program takes it.
# The process closes fd 3, the channel of bats,
# which would otherwise wait for it at the end of the test.
#
# Arguments:
#   1: How many seconds the process left behind lives.
#
# Globals:
#   FAKE_BIN, FAKE_CLIPBOARD_FILE: read.
#######################################
function install_forking_wl_copy() {
  local -r seconds="$1"

  cat >"${FAKE_BIN}/wl-copy" <<EOF
#!/usr/bin/env bash
cat >${FAKE_CLIPBOARD_FILE@Q}
sleep ${seconds@Q} 3>&- &
exit 0
EOF
  chmod +x -- "${FAKE_BIN}/wl-copy"
}

# endregion Backend switches

### End
