#!/bin/bash
#
# test-setup-fprintd.sh — packaging/setup-fprintd.sh in a sandbox.
#
# The script runs on a copy whose system paths point into a temporary
# directory, with stand-ins for systemctl and systemd-creds (the fake
# "encryption" prefixes FAKECRED; decryption fails without it, like a
# credential that cannot be decrypted). The systemctl stand-in plays the
# print key helper unit (restart decrypts the credential into run/credstore,
# stop removes it) and fprintd's ImportCredential=. Runs as root (e.g. in a container)
# or as root of a user namespace (unshare -r); prints "skip" if neither works.
#
# SPDX-License-Identifier: LGPL-2.1-or-later

set -u

REPO="$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT

if [ "$(id -u)" -eq 0 ]; then
    AS_ROOT=()
elif unshare -r true 2>/dev/null; then
    AS_ROOT=(unshare -r)
else
    echo "skip: needs root or unprivileged user namespaces (unshare -r)"
    exit 0
fi

FAILS=0
ok ()   { echo "ok   $*"; }
fail () { echo "FAIL $*"; FAILS=$((FAILS + 1)); }
check () { if eval "$1"; then ok "$2"; else fail "$2"; fi; }   # condition, label

mkdir -p "$W/bin" "$W/etc/systemd/system" "$W/run/credentials/fprintd.service" "$W/etc/credstore.encrypted" \
         "$W/var/lib/fprint/validity-0088-pairing" "$W/proc/4242" \
         "$W/build/libfprint" "$W/nodriver/libfprint"

cat > "$W/bin/systemctl" <<EOF
#!/bin/bash
echo "systemctl \$*" >> "$W/systemctl.log"
case "\$1 \${2:-}" in
  show*)   echo \${FAKE_PID:-4242} ;;
  "restart validity0088-print-key.service")
           mkdir -p "$W/run/credstore"
           exec "$W/bin/systemd-creds" decrypt --name=validity0088-print-key \
                "$W/etc/validity0088/print-key.cred" "$W/run/credstore/validity0088-print-key" ;;
  "stop validity0088-print-key.service")
           rm -f "$W/run/credstore/validity0088-print-key" ;;
  restart*) rm -f "$W/run/credentials/fprintd.service/validity0088-print-key"
           [ -f "$W/etc/systemd/system/fprintd.service.d/validity0088-print-key.conf" ] &&
           [ -f "$W/run/credstore/validity0088-print-key" ] &&
           touch "$W/run/credentials/fprintd.service/validity0088-print-key"
           exit \${FAKE_RESTART_RC:-0} ;;
esac
exit 0
EOF
cat > "$W/bin/systemd-creds" <<'EOF'
#!/bin/bash
cmd=$1; shift; args=()
for a in "$@"; do case $a in --*) ;; *) args+=("$a") ;; esac; done
in=${args[0]:-}; out=${args[1]:--}
case $cmd in
  has-tpm2) exit 0 ;;
  encrypt)  { printf FAKECRED; if [ "$in" = - ]; then cat; else cat "$in"; fi; } > "$out" ;;
  decrypt)  [ "$(head -c 8 "$in")" = FAKECRED ] || { echo "cannot decrypt" >&2; exit 1; }
            if [ "$out" = - ]; then tail -c +9 "$in"; else tail -c +9 "$in" > "$out"; fi ;;
esac
EOF
chmod +x "$W/bin/"*

# a "library" that contains the driver's symbol name, and one that does not
printf 'ELF...fpi_device_validity_0088_get_type...' > "$W/build/libfprint/libfprint-2.so.2.0.0"
printf 'ELF...' > "$W/nodriver/libfprint/libfprint-2.so.2.0.0"
echo "7f00 r-xp /run/libfprint-validity-0088/libfprint-2.so.2.0.0" > "$W/proc/4242/maps"

sed -e "s|^OVERRIDE_DIR=.*|OVERRIDE_DIR=$W/etc/systemd/system/fprintd.service.d|" \
    -e "s|^CRED_DIR=.*|CRED_DIR=$W/etc/validity0088|" \
    -e "s|^LEGACY_CRED_FILE=.*|LEGACY_CRED_FILE=$W/etc/credstore.encrypted/validity0088-print-key|" \
    -e "s|^UNIT_DIR=.*|UNIT_DIR=$W/etc/systemd/system|" \
    -e "s|^RUN_CREDSTORE=.*|RUN_CREDSTORE=$W/run/credstore|" \
    -e "s|^KEY_FILE=.*|KEY_FILE=$W/var/lib/fprint/validity-0088-pairing/print-key|" \
    -e "s|^PRINT_ROOT=.*|PRINT_ROOT=$W/var/lib/fprint|" \
    -e "s|\"/proc/\$PID/maps\"|\"$W/proc/\$PID/maps\"|" \
    -e "s|/run/credentials/|$W/run/credentials/|" \
    "$REPO/packaging/setup-fprintd.sh" > "$W/setup.sh"

D="$W/etc/systemd/system/fprintd.service.d"
OV="$D/override.conf"
C="$W/etc/validity0088/print-key.cred"
LC="$W/etc/credstore.encrypted/validity0088-print-key"
H="$W/etc/systemd/system/validity0088-print-key.service"
PK="$W/run/credstore/validity0088-print-key"
K="$W/var/lib/fprint/validity-0088-pairing/print-key"
P="$W/var/lib/fprint/user/validity-0088/dev"

# RC and OUTPUT are read by the conditions passed to check (eval)
# shellcheck disable=SC2034
run () {   # args...; sets RC and OUTPUT
    OUTPUT="$(PATH="$W/bin:$PATH" "${AS_ROOT[@]}" bash "$W/setup.sh" "$@" < /dev/null 2>&1)"
    RC=$?
}

# --- library drop-in -------------------------------------------------------
mkdir -p "$D"; echo "hand-written" > "$OV"
run "$W/build"
check '[ $RC -eq 0 ] && grep -q "BindReadOnlyPaths=$W/build/libfprint:/run/libfprint-validity-0088" "$OV"' \
      "install: drop-in binds the build's library directory"
check 'grep -q "^RequiresMountsFor=$W/build/libfprint" "$OV"' "install: RequiresMountsFor= the build"
check '[ "$(cat "$OV.bak" 2>/dev/null)" = hand-written ]' "install: previous drop-in kept as .bak"
check 'echo "$OUTPUT" | grep -q "fprintd (pid 4242) is using"' "install: checks the library fprintd mapped"
run "$W/build/libfprint"
check '[ $RC -eq 0 ] && [ ! -e "$OV.bak.1" ]' "install: the libfprint/ subdir works; unchanged rerun makes no backup"
run "$W/nodriver"
check '[ $RC -ne 0 ] && echo "$OUTPUT" | grep -q "does not include the validity-0088 driver"' \
      "install: library without the driver refused"
run /nonexistent
check '[ $RC -ne 0 ] && echo "$OUTPUT" | grep -q "build dir not found"' "install: missing build dir refused"
FAKE_RESTART_RC=1 run "$W/build"
check '[ $RC -ne 0 ] && echo "$OUTPUT" | grep -q "failed to start"' "install: failed restart reported"
FAKE_PID=0 run "$W/build"
check '[ $RC -ne 0 ] && echo "$OUTPUT" | grep -q "did not load"' "install: library not loaded reported"
run bogus extra
check '[ $RC -ne 0 ] && echo "$OUTPUT" | grep -q usage' "usage on wrong arguments"

# --- print key credential ---------------------------------------------------
head -c 32 /dev/urandom > "$K"
run --encrypt-prints
check '[ $RC -eq 0 ] && [ "$(tail -c +9 "$C" | cmp - "$K" && echo same)" = same ]' \
      "encrypt-prints: existing key file imported into the credential"
check '[ "$(stat -c %a "$C")" = 600 ]' "encrypt-prints: credential mode 600"
check 'grep -q "^ImportCredential=validity0088-print-key" "$D/validity0088-print-key.conf" &&
       grep -q "^Wants=validity0088-print-key.service" "$D/validity0088-print-key.conf" &&
       grep -q "^After=validity0088-print-key.service" "$D/validity0088-print-key.conf" &&
       ! grep -q DeviceAllow "$D/validity0088-print-key.conf"' \
      "encrypt-prints: drop-in pulls in the helper and imports the key, no TPM access for fprintd"
check 'grep -q "^ExecStart=$W/bin/systemd-creds decrypt --name=validity0088-print-key $C $PK$" "$H" &&
       grep -q "^Before=fprintd.service" "$H" && grep -q "^UMask=0077" "$H" &&
       grep -q "^ExecStop=.*rm -f $PK$" "$H"' \
      "encrypt-prints: helper unit decrypts the credential into run/credstore"
check 'cmp -s "$PK" "$K" && [ -e "$W/run/credentials/fprintd.service/validity0088-print-key" ]' \
      "encrypt-prints: helper provided the key, fprintd received it"
cp "$C" "$W/c.before"
run --encrypt-prints
check '[ $RC -eq 0 ] && cmp -s "$C" "$W/c.before"' "encrypt-prints: rerun reuses the credential"
run --drop-file-key
check '[ $RC -eq 0 ] && [ ! -e "$K" ]' "drop-file-key: key file removed when the credential holds the same key"
head -c 32 /dev/urandom > "$K"
run --drop-file-key
check '[ $RC -ne 0 ] && [ -e "$K" ]' "drop-file-key: different key -> file kept"
rm -f "$K"
printf garbage > "$C"
run --encrypt-prints
check '[ $RC -ne 0 ] && [ "$(cat "$C")" = garbage ]' "encrypt-prints: undecryptable credential never replaced"
run --status
check 'echo "$OUTPUT" | grep -q "CANNOT be decrypted"' "status: undecryptable credential reported"
rm -f "$C"
run --encrypt-prints
check '[ $RC -eq 0 ] && [ "$(tail -c +9 "$C" | wc -c)" -eq 32 ]' "encrypt-prints: new 32-byte key generated"
check '! ls -A "$W/etc/validity0088" | grep -q "^\.validity"' "encrypt-prints: no temporary files left"
check '[ "$(stat -c %a "$W/etc/validity0088")" = 700 ]' "encrypt-prints: credential directory mode 700"

# --- migration from the earlier credential location -------------------------
mv "$C" "$LC"; cp "$LC" "$W/lc.before"; rm -f "$PK" "$H"
run --status
check 'echo "$OUTPUT" | grep -q "old location"' "status: credential in the old location flagged"
run --encrypt-prints
check '[ $RC -eq 0 ] && [ ! -e "$LC" ] && cmp -s "$C" "$W/lc.before" && [ -e "$H" ]' \
      "encrypt-prints: old credential moved unchanged, helper installed"
cp "$C" "$LC"
run --encrypt-prints
check '[ $RC -eq 0 ] && [ ! -e "$LC" ] && cmp -s "$C" "$W/lc.before"' \
      "encrypt-prints: same key in both places -> old copy removed"
{ printf FAKECRED; head -c 32 /dev/urandom; } > "$LC"
run --encrypt-prints
check '[ $RC -ne 0 ] && [ -e "$LC" ] && echo "$OUTPUT" | grep -q "different keys"' \
      "encrypt-prints: different keys in both places -> refused, both kept"
rm -f "$LC"
run --status
check 'echo "$OUTPUT" | grep -q "key decrypted for fprintd"' "status: helper state shown"

# --- encryption on/off, status, delete-key ----------------------------------
mkdir -p "$P"
printf 'xx(uayayay)xx' > "$P/7"; printf 'xx(uayayay)xx' > "$P/8"; printf 'xx(uaay)xx' > "$P/9"
run --status
check 'echo "$OUTPUT" | grep -q "prints: *2 encrypted, 1 unencrypted"' "status: counts encrypted and plain prints"
check 'echo "$OUTPUT" | grep -q "decrypts"' "status: credential decrypts"
run --encryption-off
check '[ $RC -eq 0 ] && grep -q "^Environment=VALIDITY0088_PRINT_ENCRYPTION=0" "$D/validity0088-encryption.conf"' \
      "encryption-off: drop-in sets VALIDITY0088_PRINT_ENCRYPTION=0"
run --encryption-on
check '[ $RC -eq 0 ] && [ ! -e "$D/validity0088-encryption.conf" ]' "encryption-on: drop-in removed"
run --delete-key
check '[ $RC -ne 0 ] && [ -e "$C" ] && echo "$OUTPUT" | grep -q "add --yes"' \
      "delete-key: refuses without a terminal or --yes"
run --delete-key --yes
check '[ $RC -eq 0 ] && [ ! -e "$C" ] && [ ! -e "$D/validity0088-print-key.conf" ] &&
       [ ! -e "$H" ] && [ ! -e "$PK" ]' \
      "delete-key --yes: credential, helper unit, decrypted key and drop-in removed"
run --status
check 'echo "$OUTPUT" | grep -q "UNREADABLE"' "status: encrypted prints without key marked unreadable"

# --- remove -----------------------------------------------------------------
run --encrypt-prints
run --encryption-off
run --remove
check '[ $RC -eq 0 ] && [ ! -e "$OV" ] && [ ! -e "$D/validity0088-print-key.conf" ] &&
       [ ! -e "$D/validity0088-encryption.conf" ] && [ ! -e "$H" ] && [ ! -e "$PK" ] && [ -e "$C" ]' \
      "remove: drop-ins and helper unit removed, credential kept"

echo "$([ $FAILS -eq 0 ] && echo passed || echo FAILED): $FAILS failure(s)"
[ $FAILS -eq 0 ]
