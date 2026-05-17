#!/usr/bin/env bats

# Name: tests/bats/test_features.bats
# Author: Nikita Neverov (BMTLab)
# Version: 1.0.0
# Date: 2026-05-17
# License: MIT
#
# Description:
#   Behavioural tests for the v1.3.0 feature additions:
#     - --append / -a       (text concatenation onto existing buffer)
#     - --trim              (whitespace trimming before write)
#     - --type MIME         (universal MIME-type forwarding)
#     - --json              (sugar for --type application/json --raw)
#     - --image[=FORMAT]    (sugar for --type image/<format> --raw)
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern.
#   The fake backend records the last write
#   (and its MIME-type flag, when applicable)
#   so we can assert both content and the chosen --type / -t flag.
#
# Disclaimer:
#   This script is provided 'as is', without any warranty.

bats_require_minimum_version 1.5.0

load 'test_helper.bash'

setup() {
  __cp_setup_fake_backend
  __cp_load_scripts
}


# region --append

@test "--append concatenates new text onto existing clipboard content" {
  # Arrange
  __cp_clipboard_set 'first '

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "%s" "second" | copy --append
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'first second' ]
}

@test "-a short form is equivalent to --append" {
  # Arrange
  __cp_clipboard_set 'A'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "%s" "B" | copy -a
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'AB' ]
}

@test "--append on empty clipboard behaves like a plain write" {
  # Arrange
  __cp_clipboard_set ''

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "%s" "fresh" | copy --append
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'fresh' ]
}

@test "--append works in argument mode (no stdin)" {
  # Arrange
  __cp_clipboard_set 'hello '

  # Act
  run --separate-stderr __cp_run_with_tty "
    source '${COPY_PAST_ROOT}/copy.sh'
    source '${COPY_PAST_ROOT}/past.sh'
    copy --append world
  "

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = 'hello world' ]
}

# endregion


# region --trim

@test "--trim removes leading and trailing whitespace" {
  # Arrange
  local -r expected='middle'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "  \t\nmiddle  \n" | copy --trim
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--trim preserves internal whitespace" {
  # Arrange:
  # only the surrounding whitespace should disappear;
  # interior spaces, tabs, and newlines stay verbatim.
  local -r expected=$'a b\tc\nd'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "  a b\tc\nd  " | copy --trim
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--trim composes with default ANSI stripping" {
  # Arrange:
  # ANSI codes around the payload are stripped first,
  # then the leftover whitespace is trimmed.
  local -r expected='red'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "  \033[31mred\033[0m  " | copy --trim
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

@test "--trim composes with --raw (ANSI kept, whitespace gone)" {
  # Arrange
  local -r expected=$'\033[31mred\033[0m'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "  \033[31mred\033[0m  " | copy --trim --raw
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = "$expected" ]
}

# endregion


# region --type / --json

@test "--type forwards MIME flag to wl-copy" {
  # Arrange:
  # extend the wl-copy fake to record its argv
  # next to the clipboard content,
  # so the test can assert the MIME flag was passed.
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "<html>hi</html>" | copy --type text/html
  '

  # Assert
  [ "$status" -eq 0 ]
  [ "$(__cp_clipboard_dump)" = '<html>hi</html>' ]
  grep -qx -- '--type' "${FAKE_BIN}/wl-copy.argv"
  grep -qx -- 'text/html' "${FAKE_BIN}/wl-copy.argv"
}

@test "--type=MIME (equals form) is accepted" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "x" | copy --type=text/plain
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'text/plain' "${FAKE_BIN}/wl-copy.argv"
}

@test "--type without an argument fails with COPY_ERR_USAGE" {
  # Arrange / Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "x" | copy --type
  '

  # Assert
  [ "$status" -eq "$COPY_ERR_USAGE" ]
  [[ "$stderr" == *'requires a MIME argument'* ]]
}

@test "--json forwards application/json and skips ANSI stripping" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"
  # ANSI escape that would normally be stripped
  # but must survive --json (because it implies --raw).
  local -r payload=$'{"key":"\033[31mvalue\033[0m"}'

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" $'"'"'{"key":"\033[31mvalue\033[0m"}'"'"' | copy --json
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
  [ "$(__cp_clipboard_dump)" = "$payload" ]
}

@test "-j short form is equivalent to --json" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "{\"k\":1}" | copy -j
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
}

# endregion


# region --auto

@test "JSON is auto-detected by default when jq is available" {
  # Arrange:
  # capture argv to confirm the auto-picked MIME reached the backend.
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  if ! command -v jq > /dev/null 2>&1; then
    skip 'jq not installed; default JSON detection is opt-in via jq presence'
  fi

  # Act: NO flags here — the heuristic should still fire.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "{\"hello\":\"world\"}" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
  [ "$(__cp_clipboard_dump)" = '{"hello":"world"}' ]
}

@test "default JSON detection requires valid JSON; broken syntax stays text/plain" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  if ! command -v jq > /dev/null 2>&1; then
    skip 'jq not installed'
  fi

  # Act:
  # the payload starts with `{` but the JSON is broken
  # (missing closing brace), so jq rejects it.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "{\"hello\":" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  ! grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
  ! grep -qx -- '--type' "${FAKE_BIN}/wl-copy.argv"
}

@test "PNG is auto-detected by default (image magic bytes)" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act:
  # PNG magic = 89 50 4E 47 0D 0A 1A 0A.
  # Image detection runs by default; no flag required.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\x89PNG\r\n\x1a\nrest" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'image/png' "${FAKE_BIN}/wl-copy.argv"
}

@test "JPEG is auto-detected by default (image magic bytes)" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\xff\xd8\xff\xe0bytes" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'image/jpeg' "${FAKE_BIN}/wl-copy.argv"
}

@test "GIF89a is auto-detected by default (image magic bytes)" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "GIF89abytes" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'image/gif' "${FAKE_BIN}/wl-copy.argv"
}

@test "WebP is auto-detected by default (RIFF + WEBP marker)" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "RIFF\x10\x00\x00\x00WEBPpayload" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'image/webp' "${FAKE_BIN}/wl-copy.argv"
}

@test "--no-auto disables the default auto-detection" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  if ! command -v jq > /dev/null 2>&1; then
    skip 'jq not installed; --no-auto only matters when default sniff is active'
  fi

  # Act:
  # the payload IS valid JSON, but --no-auto pins us to text/plain.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "{\"a\":1}" | copy --no-auto
  '

  # Assert
  [ "$status" -eq 0 ]
  ! grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
  [ "$(__cp_clipboard_dump)" = '{"a":1}' ]
}

@test "default JSON detection is bypassed when jq is missing" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Drop a `jq` shim that always fails, so even if `jq` is on PATH
  # it cannot validate the payload. This is enough to exercise the
  # bypass branch without touching PATH.
  cat > "${FAKE_BIN}/jq" << 'EOF'
#!/usr/bin/env bash
exit 2
EOF
  chmod +x "${FAKE_BIN}/jq"

  # Act:
  # the payload IS valid JSON, but the failing jq shim
  # forces the heuristic to keep text/plain.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "{\"a\":1}" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  ! grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
  [ "$(__cp_clipboard_dump)" = '{"a":1}' ]
}

@test "default JSON detection ignores text that looks like JSON but is not" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  if ! command -v jq > /dev/null 2>&1; then
    skip 'jq not installed'
  fi

  # Act:
  # bash array literals and shell snippets begin with `{` but
  # are NOT valid JSON. jq rejects them, so we stay on text/plain.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "{ trap cleanup EXIT; }" | copy
  '

  # Assert
  [ "$status" -eq 0 ]
  ! grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
}

@test "explicit --type wins over auto-detection" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  if ! command -v jq > /dev/null 2>&1; then
    skip 'jq not installed'
  fi

  # Act:
  # the payload looks like JSON,
  # but the user pinned text/html — that wins.
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "%s" "{\"a\":1}" | copy --type text/html
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'text/html' "${FAKE_BIN}/wl-copy.argv"
  ! grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
}

@test "auto-detection silently skipped with --append (text-only mode)" {
  # Arrange:
  # the existing clipboard content is text;
  # the new payload looks like JSON.
  # When --append is set, auto-detection is suppressed
  # so that the prelude is never accidentally classified
  # as part of a JSON document.
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"
  __cp_clipboard_set 'prefix '

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    source "'"${COPY_PAST_ROOT}"'/past.sh"
    printf "%s" "{\"a\":1}" | copy --append
  '

  # Assert
  [ "$status" -eq 0 ]
  ! grep -qx -- 'application/json' "${FAKE_BIN}/wl-copy.argv"
  [ "$(__cp_clipboard_dump)" = 'prefix {"a":1}' ]
}

# endregion


# region --image

@test "--image forwards image/png by default and implies --raw" {
  # Arrange:
  # imitate a tiny PNG header (8 bytes)
  # so we can assert byte-fidelity round-trip,
  # not just MIME flag presence.
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "\x89PNG\r\n\x1a\n" | copy --image
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'image/png' "${FAKE_BIN}/wl-copy.argv"
  local hex
  hex=$(xxd -p "$FAKE_CLIPBOARD_FILE" | tr -d '\n')
  # \x89 P N G \r \n \x1a \n  ->  89 50 4e 47 0d 0a 1a 0a
  [ "$hex" = '89504e470d0a1a0a' ]
}

@test "--image=jpg maps to image/jpeg" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "binary" | copy --image=jpg
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'image/jpeg' "${FAKE_BIN}/wl-copy.argv"
}

@test "--image=svg maps to image/svg+xml" {
  # Arrange
  cat > "${FAKE_BIN}/wl-copy" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-copy.argv"
cat > "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-copy"

  # Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "<svg/>" | copy --image=svg
  '

  # Assert
  [ "$status" -eq 0 ]
  grep -qx -- 'image/svg+xml' "${FAKE_BIN}/wl-copy.argv"
}

# endregion


# region Compatibility errors

@test "--append with --image fails with COPY_ERR_TYPE_MISMATCH" {
  # Arrange / Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "x" | copy --append --image
  '

  # Assert
  [ "$status" -eq "$COPY_ERR_TYPE_MISMATCH" ]
  [[ "$stderr" == *'--append is only valid for text payloads'* ]]
}

@test "--trim with --image fails with COPY_ERR_TYPE_MISMATCH" {
  # Arrange / Act
  run --separate-stderr bash -c '
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "x" | copy --trim --image
  '

  # Assert
  [ "$status" -eq "$COPY_ERR_TYPE_MISMATCH" ]
  [[ "$stderr" == *'--trim is only valid for text payloads'* ]]
}

@test "--type=image/* with xsel backend fails with COPY_ERR_TYPE_MISMATCH" {
  # Arrange:
  # force the xsel backend
  # AND make the xsel fake responsive,
  # so we reach __cp_apply_mime instead of failing earlier.
  __cp_enable_xsel_fake

  # Act
  run --separate-stderr bash -c '
    export COPY_PAST_BACKEND=xsel
    source "'"${COPY_PAST_ROOT}"'/copy.sh"
    printf "x" | copy --image
  '

  # Assert
  [ "$status" -eq "$COPY_ERR_TYPE_MISMATCH" ]
  [[ "$stderr" == *'xsel does not support MIME types'* ]]
}

# endregion


# region past --image / past --type

@test "past --type forwards MIME flag to wl-paste" {
  # Arrange:
  # capture wl-paste argv to confirm the flag reached the backend.
  cat > "${FAKE_BIN}/wl-paste" << EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "${FAKE_BIN}/wl-paste.argv"
cat "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-paste"
  __cp_clipboard_set 'binary-bytes'

  # Act
  run --separate-stderr past --type image/png

  # Assert
  [ "$status" -eq 0 ]
  [ "$output" = 'binary-bytes' ]
  grep -qx -- '--type' "${FAKE_BIN}/wl-paste.argv"
  grep -qx -- 'image/png' "${FAKE_BIN}/wl-paste.argv"
}

@test "past --image bypasses the trailing-newline workaround" {
  # Arrange:
  # the workaround calls $(…), which corrupts NUL bytes.
  # When MIME is image/*, past must exec wl-paste directly
  # so the binary payload reaches stdout intact.
  cat > "${FAKE_BIN}/wl-paste" << EOF
#!/usr/bin/env bash
# When run directly (no \$()-capture), printf can emit NUL.
cat "${FAKE_CLIPBOARD_FILE}"
EOF
  chmod +x "${FAKE_BIN}/wl-paste"
  # Three-byte payload with an embedded NUL in the middle.
  printf 'a\x00b' > "$FAKE_CLIPBOARD_FILE"

  # Act:
  # capture into a temp file to preserve NULs across `run` boundaries.
  local -r out_file="${BATS_TEST_TMPDIR}/past-image.bin"
  past --image > "$out_file"
  local -ir rc=$?

  # Assert
  [ "$rc" -eq 0 ]
  local hex
  hex=$(xxd -p "$out_file" | tr -d '\n')
  # a (61), NUL (00), b (62)
  [ "$hex" = '610062' ]
}

# endregion


# region Constants

@test "COPY_ERR_TYPE_MISMATCH constant equals 5" {
  # Arrange / Act:
  # constants are populated by source in setup().

  # Assert
  [ "$COPY_ERR_TYPE_MISMATCH" -eq 5 ]
}

@test "PAST_ERR_TYPE_MISMATCH constant equals 5" {
  # Arrange / Act:
  # constants are populated by source in setup().

  # Assert
  [ "$PAST_ERR_TYPE_MISMATCH" -eq 5 ]
}

# endregion
