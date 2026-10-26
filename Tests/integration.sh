#!/bin/sh
set -eu

binary=${1:-dist/kcx}
if [ ! -x "$binary" ]; then
  echo "test: executable not found: $binary" >&2
  exit 2
fi

service="kcx-test-$$-$(date +%s)"
second_service="${service}-second"
account="kcx-test"
secret="kcx-integration-test-secret"
second_secret="kcx-second-integration-test-secret"
marker="${TMPDIR:-/tmp}/kcx-test-marker-$$"
stdout_file="${TMPDIR:-/tmp}/kcx-test-stdout-$$"
stderr_file="${TMPDIR:-/tmp}/kcx-test-stderr-$$"
keychain_path="${TMPDIR:-/tmp}/kcx-test-$$.keychain-db"
keychain_password="kcx-test-keychain-password"
original_keychains=$(security list-keychains -d user | sed 's/^[[:space:]]*//; s/^"//; s/"$//')

cleanup() {
  set --
  while IFS= read -r keychain; do
    [ -n "$keychain" ] && set -- "$@" "$keychain"
  done <<EOF
$original_keychains
EOF
  if [ "$#" -gt 0 ]; then
    security list-keychains -d user -s "$@" >/dev/null 2>&1 || true
  fi
  security delete-keychain "$keychain_path" >/dev/null 2>&1 || true
  rm -f "$marker" "$stdout_file" "$stderr_file"
}
trap cleanup EXIT HUP INT TERM

echo "test: checking help output"
"$binary" --help >"$stdout_file" 2>"$stderr_file"
grep -q '^Usage:' "$stdout_file"
grep -q -- '--env NAME=SERVICE' "$stdout_file"
grep -q 'kcx generate' "$stdout_file"
grep -q -- 'Generate options (only valid after' "$stdout_file"
grep -q -- '--format FORMAT' "$stdout_file"
test ! -s "$stderr_file"

echo "test: checking generated shell completion"
"$binary" completion zsh >"$stdout_file" 2>"$stderr_file"
grep -q 'compdef _kcx kcx' "$stdout_file"
grep -q 'run)' "$stdout_file"
grep -q 'generate)' "$stdout_file"
test ! -s "$stderr_file"
zsh -n "$stdout_file"
"$binary" completion bash >"$stdout_file" 2>"$stderr_file"
grep -q 'complete -o bashdefault -o default -F _kcx_complete kcx' "$stdout_file"
grep -q 'run) COMPREPLY=' "$stdout_file"
grep -q 'generate) COMPREPLY=' "$stdout_file"
test ! -s "$stderr_file"
bash -n "$stdout_file"
set +e
"$binary" completion fish >"$stdout_file" 2>"$stderr_file"
completion_status=$?
set -e
test "$completion_status" -eq 2
test ! -s "$stdout_file"
grep -q "choose 'zsh' or 'bash'" "$stderr_file"

"$binary" -h >"$stdout_file" 2>"$stderr_file"
grep -q '^Usage:' "$stdout_file"
test ! -s "$stderr_file"

echo "test: checking argument errors"
set +e
"$binary" --env >"$stdout_file" 2>"$stderr_file"
argument_status=$?
set -e
test "$argument_status" -eq 2
test ! -s "$stdout_file"
grep -q -- "--env requires a NAME=SERVICE mapping" "$stderr_file"
grep -q "kcx --help" "$stderr_file"

set +e
"$binary" headers --bearer service >"$stdout_file" 2>"$stderr_file"
argument_status=$?
set -e
test "$argument_status" -eq 2
test ! -s "$stdout_file"
grep -q "unexpected option or argument 'headers'" "$stderr_file"

set +e
"$binary" run --format json -- /usr/bin/true >"$stdout_file" 2>"$stderr_file"
argument_status=$?
set -e
test "$argument_status" -eq 2
test ! -s "$stdout_file"
grep -q "unexpected option or argument '--format'" "$stderr_file"

set +e
"$binary" generate --env TOKEN=service -- /usr/bin/true >"$stdout_file" 2>"$stderr_file"
argument_status=$?
set -e
test "$argument_status" -eq 2
test ! -s "$stdout_file"
grep -q "unexpected option or argument '--env'" "$stderr_file"

set +e
"$binary" --env BAD-NAME=service -- /usr/bin/true >"$stdout_file" 2>"$stderr_file"
argument_status=$?
set -e
test "$argument_status" -eq 2
grep -q "invalid environment-variable name" "$stderr_file"

echo "test: creating temporary Keychain"
security create-keychain -p "$keychain_password" "$keychain_path"
security unlock-keychain -p "$keychain_password" "$keychain_path"
security set-keychain-settings -lut 3600 "$keychain_path"
set -- "$keychain_path"
while IFS= read -r keychain; do
  [ -n "$keychain" ] && set -- "$@" "$keychain"
done <<EOF
$original_keychains
EOF
security list-keychains -d user -s "$@"

echo "test: adding temporary Keychain items"
security add-generic-password -U -a "$account" -s "$service" -w "$secret" -T "$binary" "$keychain_path"
security add-generic-password -U -a "$account" -s "$second_service" -w "$second_secret" -T "$binary" "$keychain_path"

# The child confirms injection without printing the secret.
echo "test: checking multiple environment mappings"
"$binary" run \
  --env KCX_TEST_SECRET="$service" \
  --env KCX_TEST_SECRET_TWO="$second_service" \
  -- /bin/sh -c \
  'test "$KCX_TEST_SECRET" = "$1" && test "$KCX_TEST_SECRET_TWO" = "$2" && printf "injection-ok\n"' \
  sh "$secret" "$second_secret" >"$stdout_file" 2>"$stderr_file"
test "$(cat "$stdout_file")" = "injection-ok"
test ! -s "$stderr_file"

# Generate JSON headers from Keychain values without contaminating stderr.
echo "test: checking generated HTTP headers"
"$binary" generate --format json \
  --header X-API-Key="$service" \
  --bearer "$second_service" >"$stdout_file" 2>"$stderr_file"
expected_json=$(printf '{"Authorization":"Bearer %s","X-API-Key":"%s"}' "$second_secret" "$secret")
test "$(cat "$stdout_file")" = "$expected_json"
test ! -s "$stderr_file"

# JSON remains the default when --format is omitted.
"$binary" generate --bearer "$service" >"$stdout_file" 2>"$stderr_file"
test "$(cat "$stdout_file")" = "$(printf '{"Authorization":"Bearer %s"}' "$secret")"
test ! -s "$stderr_file"

# Unsupported formats are rejected without writing output.
if "$binary" generate --format yaml --bearer "$service" >"$stdout_file" 2>"$stderr_file"; then
  echo "test: unsupported output format unexpectedly succeeded" >&2
  exit 1
fi
test ! -s "$stdout_file"
grep -q "only 'json' is supported" "$stderr_file"

# Missing Keychain values must not result in partial JSON.
missing_service="$service-missing"
if "$binary" generate --header X-API-Key="$service" --bearer "$missing_service" \
  >"$stdout_file" 2>"$stderr_file"; then
  echo "test: missing header Keychain item unexpectedly succeeded" >&2
  exit 1
fi
test ! -s "$stdout_file"
grep -q "no generic password found for Keychain service" "$stderr_file"

# Duplicate header names are rejected case-insensitively.
if "$binary" generate --header X-API-Key="$service" --header x-api-key="$second_service" \
  >"$stdout_file" 2>"$stderr_file"; then
  echo "test: duplicate header unexpectedly succeeded" >&2
  exit 1
fi
test ! -s "$stdout_file"
grep -q "was specified more than once" "$stderr_file"

# A failed lookup must not start the requested command, even if an earlier
# mapping resolved successfully.
echo "test: checking missing-item failure"
missing_service="$service-missing"
if "$binary" \
  --env KCX_TEST_SECRET="$service" \
  --env KCX_TEST_SECRET_TWO="$missing_service" \
  -- /usr/bin/touch "$marker" \
  >"$stdout_file" 2>"$stderr_file"; then
  echo "test: missing Keychain item unexpectedly succeeded" >&2
  exit 1
fi
test ! -e "$marker"
test ! -s "$stdout_file"
grep -q "no generic password found for Keychain service" "$stderr_file"

# The command's exit status must pass through kcx.
echo "test: checking child exit status"
set +e
"$binary" --env KCX_TEST_SECRET="$service" -- /bin/sh -c 'exit 23' \
  >"$stdout_file" 2>"$stderr_file"
child_status=$?
set -e
test "$child_status" -eq 23

echo "test: checking command-not-found guidance"
set +e
"$binary" --env KCX_TEST_SECRET="$service" -- kcx-command-that-does-not-exist \
  >"$stdout_file" 2>"$stderr_file"
child_status=$?
set -e
test "$child_status" -eq 127
test ! -s "$stdout_file"
grep -q "was not found" "$stderr_file"
grep -q "PATH" "$stderr_file"

echo "kcx integration tests passed"
