#!/usr/bin/env bats

# Name: tests/unit/test_mime.bats
# Author: Nikita Neverov (BMTLab)
# License: MIT
#
# Description:
#   Unit tests for MIME-handling helpers shared by copy and past:
#     - __cp_image_format_to_mime / __ps_image_format_to_mime
#     - __cp_classify_mime / __ps_classify_mime
#     - __cp_apply_mime    / __ps_apply_mime
#     - __cp_sniff_mime
#     - __cp_resolve_backend / __ps_resolve_backend
#
#   Each test follows the Arrange-Act-Assert (AAA) pattern.
#
# Disclaimer:
#   This script is provided 'as is', without any warranty.

bats_require_minimum_version 1.5.0

load '../support/test_helper.bash'

setup() {
  __cp_setup_fake_backend
  __cp_load_scripts
}


# region Image-format mapping (table-driven)

@test "__cp_image_format_to_mime maps every documented format" {
  # Arrange:
  # the table mirrors the case-statement in copy.sh.
  # When a format is added to the script, add a row here.
  local out=''

  # Act / Assert: explicit short forms.
  __cp_image_format_to_mime out 'jpg'
  [ "$out" = 'image/jpeg' ]
  __cp_image_format_to_mime out 'jpeg'
  [ "$out" = 'image/jpeg' ]
  __cp_image_format_to_mime out 'svg'
  [ "$out" = 'image/svg+xml' ]

  # Act / Assert: identity passthroughs.
  for fmt in png webp gif bmp tiff; do
    __cp_image_format_to_mime out "$fmt"
    [ "$out" = "image/${fmt}" ]
  done

  # Act / Assert: unknown format is forwarded verbatim,
  # so the backend can reject it with its own error.
  __cp_image_format_to_mime out 'avif'
  [ "$out" = 'image/avif' ]
}

@test "__ps_image_format_to_mime mirrors the copy-side mapping" {
  # Arrange
  local out=''

  # Act / Assert
  __ps_image_format_to_mime out 'jpeg'
  [ "$out" = 'image/jpeg' ]
  __ps_image_format_to_mime out 'svg'
  [ "$out" = 'image/svg+xml' ]
  __ps_image_format_to_mime out 'png'
  [ "$out" = 'image/png' ]
}

# endregion


# region MIME classification

@test "__cp_classify_mime correctly partitions binary vs text MIMEs" {
  # Arrange / Act / Assert (table-driven).
  local -i is_binary=0

  # Binary set.
  for mime in 'image/png' 'image/jpeg' 'image/svg+xml' \
    'application/octet-stream'; do
    is_binary=0
    __cp_classify_mime is_binary "$mime"
    [ "$is_binary" -eq 1 ] || {
      printf 'Expected %s to classify as binary\n' "$mime" >&2
      false
    }
  done

  # Text-ish set.
  for mime in '' 'text/plain' 'text/html' 'application/json' \
    'application/xml'; do
    is_binary=9
    __cp_classify_mime is_binary "$mime"
    [ "$is_binary" -eq 0 ] || {
      printf 'Expected %s to classify as text-ish\n' "$mime" >&2
      false
    }
  done
}

@test "__ps_classify_mime mirrors the copy-side classification" {
  # Arrange
  local -i is_binary=0

  # Act / Assert
  __ps_classify_mime is_binary 'image/jpeg'
  [ "$is_binary" -eq 1 ]

  __ps_classify_mime is_binary 'application/json'
  [ "$is_binary" -eq 0 ]
}

# endregion


# region __cp_apply_mime / __ps_apply_mime

@test "__cp_apply_mime appends --type for wl-copy" {
  # Arrange
  local -a cmd=(wl-copy)

  # Act
  __cp_apply_mime cmd 'application/json'

  # Assert
  [ "${#cmd[@]}" -eq 3 ]
  [ "${cmd[0]}" = 'wl-copy' ]
  [ "${cmd[1]}" = '--type' ]
  [ "${cmd[2]}" = 'application/json' ]
}

@test "__cp_apply_mime uses -t for xclip" {
  # Arrange:
  # the base xclip invocation already carries -selection / -in;
  # __cp_apply_mime must append, not replace.
  local -a cmd=(xclip -selection clipboard -in)

  # Act
  __cp_apply_mime cmd 'text/html'

  # Assert:
  # base (4 args) + appended -t text/html (2 args) = 6 elements;
  # the -t flag lands at index 4 (right after -in).
  [ "${#cmd[@]}" -eq 6 ]
  [ "${cmd[4]}" = '-t' ]
  [ "${cmd[5]}" = 'text/html' ]
}

@test "__cp_apply_mime rejects xsel for any MIME (rc=5)" {
  # Arrange:
  # xsel does not support MIME selection at all,
  # so even text/plain must fail (the user clearly wants a typed write).
  local -a cmd=(xsel --clipboard --input)
  local -i rc=0

  # Act / Assert (text MIME)
  __cp_apply_mime cmd 'text/html' 2>/dev/null || rc=$?
  [ "$rc" -eq "$COPY_ERR_TYPE_MISMATCH" ]

  # Act / Assert (binary MIME)
  rc=0
  __cp_apply_mime cmd 'image/png' 2>/dev/null || rc=$?
  [ "$rc" -eq "$COPY_ERR_TYPE_MISMATCH" ]
}

@test "__ps_apply_mime appends --type for wl-paste" {
  # Arrange
  local -a cmd=(wl-paste)

  # Act
  __ps_apply_mime cmd 'image/png'

  # Assert
  [ "${#cmd[@]}" -eq 3 ]
  [ "${cmd[0]}" = 'wl-paste' ]
  [ "${cmd[1]}" = '--type' ]
  [ "${cmd[2]}" = 'image/png' ]
}

@test "__ps_apply_mime uses -t for xclip (read direction)" {
  # Arrange
  local -a cmd=(xclip -selection clipboard -out)

  # Act
  __ps_apply_mime cmd 'application/json'

  # Assert:
  # base (4 args) + appended -t application/json (2 args) = 6;
  # -t lands at index 4 (right after -out).
  [ "${#cmd[@]}" -eq 6 ]
  [ "${cmd[4]}" = '-t' ]
  [ "${cmd[5]}" = 'application/json' ]
}

@test "__ps_apply_mime rejects xsel for any MIME (rc=5)" {
  # Arrange
  local -a cmd=(xsel --clipboard --output)
  local -i rc=0

  # Act
  __ps_apply_mime cmd 'image/png' 2>/dev/null || rc=$?

  # Assert
  [ "$rc" -eq "$PAST_ERR_TYPE_MISMATCH" ]
}

# endregion


# region __cp_sniff_mime (table-driven magic bytes)

@test "__cp_sniff_mime recognises every documented binary signature" {
  # Arrange:
  # rows are 'mime|hex'.
  # The hex string is decoded into the buffer file
  # via xxd -r -p (the inverse of `xxd -p`).
  local -ra cases=(
    'image/png|89504E470D0A1A0A'  # PNG header
    'image/jpeg|FFD8FFE0'         # JPEG (JFIF marker)
    'image/gif|47494638'          # GIF (GIF8...)
    'image/bmp|424D'              # BMP (BM)
  )

  local row mime hex buffer
  for row in "${cases[@]}"; do
    mime="${row%%|*}"
    hex="${row#*|}"
    buffer="$(mktemp -p "$BATS_TEST_TMPDIR")"

    # Act
    printf '%s' "$hex" | xxd -r -p > "$buffer"
    local got
    got="$(__cp_sniff_mime "$buffer")"

    # Assert
    [ "$got" = "$mime" ] || {
      printf 'For %s expected %s but got %s\n' "$hex" "$mime" "$got" >&2
      false
    }

    rm -f -- "$buffer"
  done
}

@test "__cp_sniff_mime recognises WebP (RIFF + WEBP marker)" {
  # Arrange:
  # WebP signature: 'RIFF' + 4 size bytes + 'WEBP'.
  # The 4 size bytes are arbitrary here.
  local -r buffer="$(mktemp -p "$BATS_TEST_TMPDIR")"
  printf 'RIFF\x10\x00\x00\x00WEBPextra' > "$buffer"

  # Act
  local got
  got="$(__cp_sniff_mime "$buffer")"

  # Assert
  [ "$got" = 'image/webp' ]

  # Cleanup
  rm -f -- "$buffer"
}

@test "__cp_sniff_mime falls back to text/plain for plain text input" {
  # Arrange
  local -r buffer="$(mktemp -p "$BATS_TEST_TMPDIR")"
  printf 'just some text\n' > "$buffer"

  # Act
  local got
  got="$(__cp_sniff_mime "$buffer")"

  # Assert
  [ "$got" = 'text/plain' ]

  # Cleanup
  rm -f -- "$buffer"
}

@test "__cp_sniff_mime returns application/json for valid JSON when jq is installed" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed; the JSON branch is opt-in via jq presence'
  fi
  local -r buffer="$(mktemp -p "$BATS_TEST_TMPDIR")"
  printf '%s' '{"hello":"world"}' > "$buffer"

  # Act
  local got
  got="$(__cp_sniff_mime "$buffer")"

  # Assert
  [ "$got" = 'application/json' ]

  # Cleanup
  rm -f -- "$buffer"
}

@test "__cp_sniff_mime stays at text/plain for JSON-shaped but invalid bytes" {
  # Arrange
  if ! command -v jq >/dev/null 2>&1; then
    skip 'jq not installed'
  fi
  local -r buffer="$(mktemp -p "$BATS_TEST_TMPDIR")"
  # Looks like JSON, but jq cannot parse it.
  printf '%s' '{ trap cleanup EXIT; }' > "$buffer"

  # Act
  local got
  got="$(__cp_sniff_mime "$buffer")"

  # Assert
  [ "$got" = 'text/plain' ]

  # Cleanup
  rm -f -- "$buffer"
}

# endregion


# region __cp_resolve_backend / __ps_resolve_backend

@test "__cp_resolve_backend picks wl-copy under Wayland and forwards MIME" {
  # Arrange
  local -a backend=()

  # Act
  __cp_resolve_backend backend 'application/json'

  # Assert:
  # backend should now look like (wl-copy --type application/json).
  [ "${backend[0]}" = 'wl-copy' ]
  [ "${backend[1]}" = '--type' ]
  [ "${backend[2]}" = 'application/json' ]
}

@test "__cp_resolve_backend rejects xsel + non-text MIME (rc=5)" {
  # Arrange:
  # force xsel explicitly via COPY_PAST_BACKEND,
  # so the assertion stays deterministic regardless of the host.
  # Relying on auto-detection to fall through to xsel was fragile:
  # CI installs a real xclip, which __cp_detect_backend would pick
  # before ever reaching xsel.
  # __cp_apply_mime rejects the binary MIME before xsel is executed,
  # so the fake only needs to be discoverable on PATH, not functional.
  __cp_enable_xsel_fake
  export COPY_PAST_BACKEND=xsel
  local -a backend=()
  local -i rc=0

  # Act
  __cp_resolve_backend backend 'image/png' 2>/dev/null || rc=$?

  # Assert
  [ "$rc" -eq "$COPY_ERR_TYPE_MISMATCH" ]
}

@test "__ps_resolve_backend picks wl-paste under Wayland and forwards MIME" {
  # Arrange
  local -a backend=()

  # Act
  __ps_resolve_backend backend 'application/json'

  # Assert
  [ "${backend[0]}" = 'wl-paste' ]
  [ "${backend[1]}" = '--type' ]
  [ "${backend[2]}" = 'application/json' ]
}

# endregion

### End of file
