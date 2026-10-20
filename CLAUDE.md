# Kensington VeriMark (USB 06cb:0088) – libfprint driver `validity-0088`

Out-of-tree libfprint driver for the Kensington VeriMark Gen 1 USB key
(Synaptics/Validity "Windsor" sensor, sensor id 0x2449). This branch makes it
work natively on Linux: sensor calibration, image capture, and host-side
matching. No Windows driver data or tooling is needed at runtime.

## Layout

- `drivers/validity-0088/` – the driver. Copied or symlinked into a libfprint
  tree at `libfprint/drivers/validity-0088/`.
  - `validity.c` – device class, TLS session use, enroll/verify state machines,
    session prep, calibration states.
  - `validity-match.c/.h` – matcher glue: print (de)serialisation, scoring
    against stored prints, match threshold, scan quality gate, image
    extraction from `51` replies.
  - `validity-transport.c` – USB bulk read/write, encrypted app-data
    exchange, reply status checks, async exchange and interrupt-wait helpers
    for the state machines.
  - `validity-capture-builder.c` – generic capture-program skeleton (2005 B,
    calibration slots blank) and the calibration code that fills it per device.
  - `validity-sift.c/.h` – self-contained SIFT matcher (no OpenCV).
  - `validity-printkey.c/.h` – AES-256-GCM encryption of stored templates
    (format 2), key lookup (systemd credential, else `print-key` file).
  - `validity-handshake.c`, `validity-crypto.c`, `validity-pairing.c`,
    `validity-pretls-pair.c` – Synaptics-modified TLS, pairing, key storage.
  - `validity-commands.c` – wire command builders (ClientHello, capture,
    read image, LED, flash) and the debug overrides for captured commands.
  - `validity-init-data.c`, `validity-init-clean-slate.c`,
    `validity-enroll-data.c` – static protocol payloads (INIT_MSG4 variants,
    hostpart); `validity-pubkeys.c` – zeroed paired-identity placeholders.
  - `meson-fragment.txt` – lines to add to libfprint's meson files.
- `packaging/setup-fprintd.sh` – fprintd systemd drop-in helper.

## Build and test

In a libfprint checkout:

1. `libfprint/meson.build` (inner) → `driver_sources['validity_0088']` must
   list all driver `.c` files, **including `validity-sift.c`**.
2. Root `meson.build` → `drivers_info`: `'validity_0088' : { 'helper': ['openssl'] }`
   (older trees: `driver_helper_mapping`, `'validity_0088' : [ 'openssl' ]`).
3. `meson setup builddir -Ddrivers=validity_0088 && ninja -C builddir`.

Test without installing:

```
G_MESSAGES_DEBUG=all LD_LIBRARY_PATH=$PWD/builddir/libfprint ./builddir/examples/enroll
G_MESSAGES_DEBUG=all LD_LIBRARY_PATH=$PWD/builddir/libfprint ./builddir/examples/verify
```

`examples/*` keep prints in `test-storage.variant` in the current folder.
Testing needs a person to touch the sensor; ask before each tap sequence.

fprintd uses the build through a systemd drop-in
(`/etc/systemd/system/fprintd.service.d/override.conf`) that sets
`LD_LIBRARY_PATH` and bind-mounts the build directory (see
`packaging/setup-fprintd.sh`, `--remove` to undo). PAM:
`pam-auth-update --enable fprintd`.

## Storage

Directory from `validity_pairing_get_storage_dir()`:
`$VALIDITY0088_STORAGE_DIR`, else `$STATE_DIRECTORY/validity-0088-pairing`
(fprintd: `/var/lib/fprint/validity-0088-pairing`), else
`~/.local/share/libfprint/verimark-06cb-0088`.

Contents: pairing keys (`cert-blob`, `host-key.pem`, `device-ecdh-pubkey.bin`),
`calibration.bin`, calibration debug dumps `cal-*.bin`, and `print-key` (print
encryption key, created at the first enroll when no credential
`$CREDENTIALS_DIRECTORY/validity0088-print-key` exists) — all mode 600.

## Protocol facts (established)

- Commands are TLS application-data records on EP 0x01, replies on EP 0x81
  (2-byte status + payload); finger events on interrupt EP 0x83.
- Session prep: `1a`, `06` (init msg4, 661 B), `5b`, `01` (ROM info), `19`,
  `75`, `39` (LED/scan setup), then `1a`, `06`, `5b`, `06` (hostpart, 10501 B).
- Capture: `02` + capture program (header `02 | u16 line_len=152 | u16 lines`,
  then TLV records `u16 type, u16 len, payload`), interrupt events, then
  `51` → 8082 B (18 B header + 8064 px). Pixel stream is column-major
  (56 columns × 144); the driver transposes to a 56×144 image.
- The sensor does no on-chip matching (opcodes `5e`/`69` → status `0x0401`).
- `51` returning 18 B with status `0x0007` = no image (tap too short/light).
- `get_fw_info(fwext)` returns `0x04af` at every open; harmless, logged at debug
  level only (other non-zero values still warn).

## Calibration (`validity-capture-builder.c`)

Ported from synaWudfBioUsb66.dll (Windsor path `FUN_1800a0c60`,
`FUN_18008fb90`, `FUN_180092c70`) and checked against a Windows USB capture.

Runs at the end of session prep when `calibration.bin` is missing or
`VALIDITY0088_RECALIBRATE=1` (finger off the sensor):

1. Trim: `6f 00 0e 00 00 00 00 00 00` → config block list; block id
   `0x80000003` payload (after a 4-byte header) = 56-byte per-column trim.
2. Calibration program 1 (base records up to and incl. `0x17`, then `0x44`,
   `0x30` without frame entries, `0x43`; `0x34` timeslot head zeroed;
   header lines = 337) → sensor streams 337 × 152 B raw lines on bulk EP 0x82
   (3 passes × 112 lines + end line, 8-byte line header `01 fe NN pass …`).
   Calibration frame = per-row average of the line pair in pass 2.
3. Calibration program 2 = program 1 + frame-derived records → second stream
   → baseline frame (same reduction).
4. Save `calibration.bin` (`VCAL` v1: trim, frame, baseline), re-run the prep
   tail.

Normal capture program (18869 B) = skeleton with:
- `0x34` first 144 B: `clamp((px-128)*10/4)` from frame rows 18/28/38 (5 → 4);
- `0x30`: 36 entries `0xffffffff / 0x85000000|4g`, each 56 rows × 4 px scaled;
- `0x43`: trim bit-packed twice (`[(bits-1)|8, min, 0, 0]` + LSB-first fields);
- `0x48`: baseline frame verbatim after the 4-byte prefix.

There is no uncalibrated fallback: without `calibration.bin` capture fails.

Verified: built from the Windows calibration data, the program is identical to
the Windows one (18869 B); on Linux the trim matched Windows byte for byte and
the frame matched within sensor noise.

Unverified detail: one instruction byte in record `0x34` of program 1 may
depend on a device flag (`+0x4c`) not readable on Linux; current choice works.

## Matcher (`validity-sift.c`, glue in `validity-match.c`)

- SIFT: 2× upscale, local contrast normalisation, 3 octaves × 3 intervals,
  strongest 250 keypoints, 128-d descriptors.
- Match: ratio test 0.8 + RANSAC similarity (≤25° rotation, ±15% scale);
  score = consistent keypoints. Threshold 12 (`VALIDITY0088_SIFT_THRESHOLD`).
- Prints: `fpi-data = (u ay ay ay)`, format 2 = (key id, nonce, AES-256-GCM
  of the format-1 `aay`), AAD = label + key id + print device id. Format 1
  `(u aay)` (one serialised feature set per tap, ~33 KB each, no images) is
  written with `VALIDITY0088_PRINT_ENCRYPTION=0`; format 1 and legacy `aay`
  raw-image prints still verify. Design: `docs/print-encryption.md`.
- Quality gate before matching: high-pass RMS ≥ 15.
- Identify uses the verify SSM; the match step scores the scan against every
  gallery print and reports the best one at or above the threshold (prints
  without usable templates are skipped). This also enables fprintd's
  duplicate check at enroll.
- Test set (4 fingers × 10 taps, one person): same finger 19–150 (incl.
  synthetic ±25° rotation), other fingers ≤ 5. The old correlation matcher
  failed beyond ~10° rotation and other fingers reached 0.42–0.48 vs 0.50.
- A scan of a finger area not covered by any enrolled tap scores like a
  different finger (~0–5). Enroll with varied placement.

## Environment variables

| Variable | Effect |
|---|---|
| `VALIDITY0088_RECALIBRATE=1` | Recalibrate in the next session prep |
| `VALIDITY0088_SIFT_THRESHOLD=n` | Match threshold (default 12) |
| `VALIDITY0088_STORAGE_DIR=path` | Override storage directory |
| `VALIDITY0088_PRINT_ENCRYPTION=0` | Store new prints unencrypted (format 1) |
| `VALIDITY0088_VERIFY_MODE=enroll` | Verify with capture mode 0x23 |
| `VALIDITY0088_LED_RESULT=0` | No LED feedback after verify |
| `VALIDITY0088_NCC_THRESHOLD` | Obsolete (old correlation matcher) |
| `VALIDITY0088_FORCE_REPAIR`, `_TRY_HARD_RESET`, `_SKIP_AUTO_PAIR`, `_RUN_FRESH_PAIR`, `_FLASH_*` | Pairing/recovery tools from upstream |

## Rules for this repo

- Never commit device-specific data: `calibration.bin`, `cal-*.bin`,
  `test-storage.variant`, pairing keys, USB captures, or capture programs
  taken from a Windows install.
- The capture skeleton in `validity-capture-builder.c` holds no sensor data;
  never put a full capture program (any sensor's) back into the source.
- One logical change per commit; keep `meson-fragment.txt` in sync when files
  are added.

## Open items

1. Field-test SIFT threshold; measure false accepts with more fingers/people.
2. More enroll stages (10 → 15–20) and/or placement prompts for coverage.
   Findings (2026-10-20): fprintd maps enroll retries to fixed statuses
   (`enroll-finger-not-centered`, `enroll-retry-scan`, …), so a driver cannot
   show placement prompts there; its message text only reaches libfprint's
   examples and logs. Between taps of one enrollment, taps on the same spot
   scored 130–180, varied taps mostly below 125 (often 0–30). A "too similar"
   gate (reject ≥130, at most 2 in a row) was tried and dropped: two real
   enrollments never triggered it, and repeating a placement exactly on the
   7 × 3 mm sensor is hard even on purpose.
3. Encrypt stored prints: driver part done (format 2, key file fallback,
   tested offline and on the sensor). Left: `setup-fprintd.sh
   --encrypt-prints` (systemd credential, host+tpm2, no PCRs,
   `ImportCredential=`) and testing what fprintd does when the credential
   cannot be decrypted. See `docs/print-encryption.md`.
4. Optional k-of-n rule (require ≥2 templates above a lower threshold).
