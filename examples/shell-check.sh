#!/usr/bin/env bash
# What a Nix evaluation cannot check: whether the shell a floe emits means what
# its author intended.
#
# `postgres.nix` builds `ExecStartPre` and `ExecStartPost` as strings, which is
# forced — a floe's output must be inert data, so it cannot build a script
# derivation. Every check in the repo passes on a string that parses as *some*
# shell, and the NixOS evaluation is happy with any string at all. Even `sh -n`
# is not enough: the first version of this SQL was syntactically valid and
# semantically wrong, emitting
#
#     CREATE ROLE webapp LOGIN PASSWORD SECRET
#
# with no quotes around the password, because the outer `sh -c '…'` had consumed
# them. Postgres would have rejected it at apply time.
#
# So: run the emitted command with fake binaries on PATH and look at what the
# arguments actually came out as. Not a flake check — it needs a writable
# directory and a real shell — but cheap to run and the only thing here that
# would have caught that bug.
set -uo pipefail
cd "$(dirname "$0")/.."

fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
mkdir -p "$fake/bin"
ln -sf /bin/sh "$fake/bin/sh"

# Echo the `-c` argument, so the SQL as psql would receive it is visible.
cat > "$fake/bin/psql" <<'EOF'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in -c) shift; echo "SQL: $1" ;; esac
  shift
done
EOF

# Fail the existence guards so the create branch runs — and echo what came in,
# because the guard's SQL goes to this through a pipe and is otherwise invisible.
printf '#!/bin/sh\ncat >&2\nexit 1\n' > "$fake/bin/grep"
# Stand in for the generated secret.
printf '#!/bin/sh\necho SECRET\n' > "$fake/bin/cat"
# The generator side. `test` is a shell builtin and cannot be faked, so the
# state directory is redirected instead — otherwise the generator really tries to
# write to /var/lib and fails on permissions rather than on anything real.
printf '#!/bin/sh\necho RANDOM\n' > "$fake/bin/head"
printf '#!/bin/sh\ncat\n' > "$fake/bin/base64"
chmod +x "$fake"/bin/*
mkdir -p "$fake/var/lib/postgres-main/credentials"

emitted() {
  nix eval --impure --raw --expr "
    let
      lib = import <nixpkgs/lib>;
      floe = import ./lib { inherit lib; };
      ex = import ./examples/nixos { inherit lib floe; };
    in
    ex.link.out.\"nixos.config\".main.systemd.services.\"postgres-main\".serviceConfig.$1
  " 2>/dev/null | sed -e "s|/run/current-system/sw/bin|$fake/bin|g" -e "s|/var/lib|$fake/var/lib|g"
}

status=0
check() { # check <description> <haystack> <needle>
  if printf '%s' "$2" | grep -qF -- "$3"; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s\n     wanted: %s\n     got:    %s\n' "$1" "$3" "$2" >&2
    status=1
  fi
}

sql=$(sh -c "$(emitted ExecStartPost)" 2>&1)

# The bug this file exists for: the password must reach psql as a quoted SQL
# string literal, not a bare word.
check "password is a quoted SQL literal" "$sql" "PASSWORD 'SECRET'"
check "role name is a quoted SQL literal" "$sql" "rolname='webapp'"
check "the database is created for the claimant" "$sql" "CREATE DATABASE webapp OWNER webapp"

# And the generator side runs at all, rather than dying on a quoting error.
if sh -c "$(emitted ExecStartPre)" >/dev/null 2>&1; then
  printf 'ok   the credential generator runs\n'
else
  printf 'FAIL the credential generator exits non-zero\n' >&2
  status=1
fi

exit $status
