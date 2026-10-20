# Encrypted fingerprint templates — design note

Status: driver part implemented (`validity-printkey.c`): format 2, key
lookup, key file creation, failure messages; tested offline and on the
sensor. Not yet implemented: `setup-fprintd.sh --encrypt-prints`.

## Goal

Stored prints of the validity-0088 driver should not be readable or usable
when someone gets a copy of the files (stolen or copied disk, backup, another
OS on the same machine reading the Linux partition). Prints already enrolled
keep working.

Non-goals: protection against root on the running system (root can always
read the key from the service, or simply use the sensor), and encrypting
fprintd's metadata (user name, finger, enroll date), which fprintd writes
itself.

## Where encryption can happen

fprintd, not the driver, stores the print files
(`/var/lib/fprint/<user>/validity-0088/<device-id>/<finger>`). It serialises
the whole `FpPrint`; the driver only controls the `fpi-data` value inside it.
So the driver encrypts exactly that value: the SIFT keypoints of the 10 taps.
This works the same for fprintd and for the libfprint examples, and needs no
fprintd change.

What a template is: up to 250 keypoints (position + 128-value gradient
histogram) per tap, no image. Turning that back into a usable fingerprint is
hard but not proven impossible, which is why it is worth encrypting.

## Print format

Today (format 1, plaintext):

    fpi-data = (u aay)    u = 1, aay = one serialised keypoint set per tap

New (format 2, encrypted):

    fpi-data = (u ay ay ay)
      u   = 2
      ay  = key id: first 8 bytes of SHA-256("validity-0088 print key" || key)
      ay  = nonce: 12 random bytes, new for every print
      ay  = AES-256-GCM ciphertext of the GVariant-serialised format-1 `aay`,
            followed by the 16-byte tag

    AAD = "validity-0088 print v2" || key id || device id of the print

- AES-256-GCM through OpenSSL EVP, which the driver already links.
- The key id lets the driver pick the right key and report a clear error when
  it is missing ("print encrypted with key 1a2b…; key not available").
- The device id in the AAD stops a template from being moved to a print of
  another sensor. Not included on purpose: user name and finger. They would
  stop swapping templates between users, but break a print when an account is
  renamed, and swapping needs write access to fprintd's files (= root) anyway.

Reading: format 2 is decrypted, then handled exactly like format 1. Format 1
and the legacy raw-scan `aay` prints keep working unchanged; they stay
plaintext until the finger is enrolled again (libfprint has no way for the
driver to rewrite a stored print during verify).

## Where the key comes from

One 32-byte random key per installation. The driver looks in this order:

1. `$CREDENTIALS_DIRECTORY/validity0088-print-key` — the systemd credential
   (fprintd setup, below).
2. `print-key` in the driver's storage directory
   (`/var/lib/fprint/validity-0088-pairing/` under fprintd,
   `~/.local/share/libfprint/verimark-06cb-0088/` for the examples), mode 600.

For decryption every available key is tried by key id, so prints made with
the file key keep working after a credential is set up. New prints are
encrypted with the first key found.

When no key exists at enroll time, the driver creates the `print-key` file
(32 bytes from the OS random generator, mode 600), so new prints are
encrypted. If that file cannot be created, the print is stored unencrypted
with a warning rather than failing the enrollment. This needs no systemd:
on other init systems fprintd's storage directory is root's
`~/.local/share/libfprint/verimark-06cb-0088/`, and the key file lives there
next to the pairing data. `VALIDITY0088_PRINT_ENCRYPTION=0` turns encryption of new prints
off (reading encrypted ones still works if the key is there).

The file key alone only protects copies of the print files made without the
storage directory (for example a backup of `/var/lib/fprint/<user>` only). The
credential is the real protection.

## fprintd: the key as a systemd credential

`setup-fprintd.sh --encrypt-prints` (new option):

1. If `/var/lib/fprint/validity-0088-pairing/print-key` exists, use that key
   (so existing encrypted prints stay readable), else generate a new one. The
   key goes through a pipe only, never a new plaintext file:

       head -c 32 /dev/urandom |
         systemd-creds encrypt --name=validity0088-print-key \
           --with-key=host+tpm2 --tpm2-pcrs= - \
           /etc/credstore.encrypted/validity0088-print-key

   `--with-key=host` instead when `systemd-creds has-tpm2` does not report
   full TPM support (on this machine: TPM present, `libtss2` libraries missing).
2. Add `ImportCredential=validity0088-print-key` to the drop-in.
3. Restart fprintd, check that a verify still works, then delete the old
   `print-key` file (keys are tried by key id, so this is safe once the
   credential holds the same key).

`--remove` keeps the credential file, so removing the drop-in never makes
prints unreadable.

Why these choices:

- **No PCR binding (`--tpm2-pcrs=` empty).** systemd 255 binds to PCR 7 by
  default. PCR 7 changes with Secure Boot settings, firmware updates and the
  Secure Boot database updates Windows Update installs. A key bound to it
  would stop decrypting after such an update, and fprintd could no longer read
  any print. Without PCRs the key is still bound to this TPM chip.
- **host+tpm2**: decryption needs both systemd's host key on this disk and
  this TPM. A copied disk or backup alone is not enough, and neither is the
  TPM alone.
- **The TPM is not modified.** `systemd-creds` seals the key with the TPM's
  storage key — the one at the standard handle `0x81000001` that Windows
  uses too, or, if none is stored there, a key derived from the TPM's seed
  with the standard template (systemd's `systemd-tpm2-setup` may store it at
  that handle; it only adds, never replaces) — and keeps the sealed result
  in the credential file. It never clears the TPM, changes its owner
  password or touches BitLocker data. A dual-boot Windows is not affected.
  Only clearing the TPM (firmware setup, `tpm.msc`, `tpm2_clear`) would make
  the credential undecryptable.

What it does not protect against: an administrator of another OS on the same
machine who can read the Linux partition (host key) and use the TPM. PCR
binding would stop that, at the price above.

## Failure behaviour

| Situation | Result |
|---|---|
| Print is format 2, its key is not available | verify/identify: `FP_DEVICE_ERROR_DATA_INVALID`, "print encrypted with key …, key not available; restore the key or enroll again". Identify skips that print and continues with the others. |
| Key present, GCM tag check fails | same error, "print damaged or encrypted with another key". |
| Credential configured but missing / undecryptable (TPM cleared) | **to be tested**: does `ImportCredential=` then start fprintd without the credential, or fail the unit? If it fails the unit, fprintd does not start and PAM falls back to the password; the README must say how to recover (`--remove`, re-enroll). |
| No key anywhere at enroll | `print-key` file created, print encrypted. |
| No key, and the file cannot be created (storage not writable, disk full) | print stored **unencrypted** (format 1) with a warning; enrolling the finger again later encrypts it. |
| `print-key` exists but is not a valid key (wrong size, unreadable) | enroll fails; the file is never replaced, so prints made with the real key are not lost. |
| `VALIDITY0088_PRINT_ENCRYPTION=0` | new prints in format 1 (plaintext). |

Nothing is ever deleted automatically.

## Code layout

- New `validity-printkey.c/.h`: key lookup (credential, file, creation), key
  id, `validity_print_encrypt (GVariant *aay, const gchar *device_id)` and
  `validity_print_decrypt (GVariant *fpi_data, …)`.
- `validity-match.c`: `validity_tpl_best_score()` accepts format 2 by calling
  the decrypt function first; enroll (`validity.c`, commit state) wraps the
  `aay` with the encrypt function.
- `meson-fragment.txt`, README, `CLAUDE.md`, `setup-fprintd.sh` updated.

## Tests

Offline (no sensor): encrypt/decrypt round trip; wrong key, flipped byte,
other device id must fail; format 1 and legacy prints still pass through.

On the sensor, with the libfprint examples: enroll (format 2 written,
`print-key` created) and verify; verify an old format-1 print; identify over a
gallery mixing format 1 and format 2; remove the key → clear error.

With fprintd (needs `sudo` in a normal terminal): `--encrypt-prints`, enroll,
verify, PAM login; then move the credential away to see the failure case.

## Decisions to confirm

1. Always encrypt new prints, creating a `print-key` file when no credential
   is set up (proposed), or encrypt only once `--encrypt-prints` was run?
2. AAD with the device id only (proposed), or also user name and finger?
3. No PCR binding (proposed), accepting that another OS with access to the
   Linux partition and the TPM could decrypt?
