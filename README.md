# Kensington VeriMark (06cb:0088) Linux Driver

An open-source `libfprint` driver for the Kensington VeriMark fingerprint key.

> **Install, plug in, works.**
>
> 1. Add the driver to a fresh `libfprint` source tree (section 2)
> 2. `meson compile -C builddir`
> 3. Plug in your VeriMark
> 4. `fprintd-enroll` (or `examples/enroll` for testing)
>
> The driver auto-pairs with the device on first open, calibrates the sensor on first use, and keeps its state in `~/.local/share/libfprint/verimark-06cb-0088/` (or `/var/lib/fprint/validity-0088-pairing/` under fprintd). Works on both unpaired devices and devices that have been paired elsewhere; multiple machines can independently pair the same device. No Windows driver, registry data, or capture files are needed.

## 1. Device Information

This driver targets the **Kensington VeriMark Gen 1 USB-A Fingerprint Key** (USB ID `06cb:0088`), Kensington model K67977 (or K67977WW worldwide).

The VeriMark is a small USB-A dongle with a tap (capacitive area) fingerprint sensor, built around a Synaptics / Validity pre-Prometheus chip ("Windsor", sensor id `0x2449`). The sensing window is tiny: 56 × 144 pixels, about 7 × 3 mm. It speaks a Synaptics-modified TLS 1.2 protocol over USB bulk transfers. This repository contains a clean-room Linux implementation of that protocol as a `libfprint` driver, packaged for drop-in integration with the upstream `libfprint` source tree.

The sensor only captures images; it does no matching itself. The driver calibrates the sensor (section 2, *Calibration*) and matches fingerprints on the host with a built-in SIFT keypoint matcher (section 2, *Matching*). It supports enroll, verify and identify.

When everything is wired up the VeriMark works with `fprintd` (and therefore with PAM-based fingerprint authentication on most Linux desktops and login managers).

## 2. Compile the Driver

The driver compiles into `libfprint-2.so` and is loaded by `libfprint` automatically when a `06cb:0088` device is plugged in.

### Prerequisites

| Tool / library    | Notes                                           |
|-------------------|-------------------------------------------------|
| `meson` >= 0.59   | Build system                                    |
| `ninja`           | Backend used by meson                           |
| `gcc` or `clang`  | C compiler                                      |
| `glib2` (dev)     | GLib / GObject runtime + headers                |
| `gusb` (dev)      | USB transport used by libfprint                 |
| `gudev` (dev)     | udev integration (optional)                     |
| `openssl` >= 3 (dev) | Used by this driver for AES, HMAC, ECDH, ECDSA |
| `pixman` (dev)    | Image scaling for libfprint's image drivers (optional) |
| `pkg-config`      | Build introspection                             |

The fingerprint matcher is part of the driver; it needs no extra library (no OpenCV, no NBIS).

On Arch / CachyOS:

```bash
sudo pacman -S meson ninja base-devel glib2 libgusb libgudev openssl pixman pkgconf
```

On Debian / Ubuntu / Linux Mint:

```bash
sudo apt install meson ninja-build build-essential libglib2.0-dev \
    libgusb-dev libgudev-1.0-dev libssl-dev libpixman-1-dev pkg-config
```

### Build steps

1. **Clone this repository.**

   ```bash
   git clone https://github.com/rsipka/Kensington_VeriMark_06cb-0088.git
   cd Kensington_VeriMark_06cb-0088
   ```

2. **Clone upstream `libfprint`** somewhere convenient. The driver is meant to live inside its source tree.

   ```bash
   git clone https://gitlab.freedesktop.org/libfprint/libfprint.git
   ```

3. **Put the driver source into libfprint**, either as a copy or as a symlink (with a symlink, `meson compile` always builds what this repository has checked out):

   ```bash
   cp -r drivers/validity-0088 libfprint/libfprint/drivers/
   # or: ln -s "$PWD/drivers/validity-0088" libfprint/libfprint/drivers/validity-0088
   ```

4. **Register the driver with libfprint's meson.** Two upstream files need a one-line entry added:

   **(a)** Open `libfprint/libfprint/meson.build` (the inner one) and find the `driver_sources` dictionary (entries like `'elan' :`, `'synaptics' :`). Add:

   ```meson
   'validity_0088' :
       [ 'drivers/validity-0088/validity.c',
         'drivers/validity-0088/validity-capture-builder.c',
         'drivers/validity-0088/validity-commands.c',
         'drivers/validity-0088/validity-crypto.c',
         'drivers/validity-0088/validity-handshake.c',
         'drivers/validity-0088/validity-init-data.c',
         'drivers/validity-0088/validity-init-clean-slate.c',
         'drivers/validity-0088/validity-enroll-data.c',
         'drivers/validity-0088/validity-match.c',
         'drivers/validity-0088/validity-pairing.c',
         'drivers/validity-0088/validity-pretls-pair.c',
         'drivers/validity-0088/validity-printkey.c',
         'drivers/validity-0088/validity-pubkeys.c',
         'drivers/validity-0088/validity-sift.c',
         'drivers/validity-0088/validity-transport.c' ],
   ```

   **(b)** Open `libfprint/meson.build` (the outer one, at the project root). Current libfprint lists drivers in the `drivers_info` dictionary (entries like `'uru4000': { 'helper': ['openssl'] },`). Add:

   ```meson
   'validity_0088' : { 'helper': ['openssl'] },
   ```

   Older libfprint trees use a `driver_helper_mapping` dictionary instead (entries like `'uru4000' : [ 'openssl' ],`); there, add `'validity_0088' : [ 'openssl' ],`.

   This wires the driver up against libcrypto, which it uses for AES, HMAC, ECDH, and ECDSA.

   The dictionary key MUST be `validity_0088` (underscore) — upstream's meson pastes it directly into a generated C identifier in `fpi-drivers.c` and a hyphen there produces invalid C. The directory and file paths stay as `validity-0088`. Both snippets live in `drivers/validity-0088/meson-fragment.txt`.

5. **Configure + build libfprint** with the new driver enabled:

   ```bash
   cd libfprint
   meson setup --wipe builddir -Ddrivers=validity_0088 -Ddoc=false
   meson compile -C builddir
   ```

   A successful build produces `builddir/libfprint/libfprint-2.so.2`.

6. **Install the udev rule** (optional, only needed if you plan to use `libfprint` examples directly without `sudo`):

   ```bash
   sudo cp ../Kensington_VeriMark_06cb-0088/packaging/70-vmark.rules /etc/udev/rules.d/
   sudo udevadm control --reload-rules
   sudo udevadm trigger
   ```

7. **Sanity check the build** by running the bundled `examples/verify` against the live device. Plug the VeriMark in and run:

   ```bash
   LD_LIBRARY_PATH=$(pwd)/builddir/libfprint ./builddir/examples/verify
   ```

   At the "Choose finger" prompt, pick `6` (right index). On first run with no enrolled finger you'll get `Did you remember to enroll your finger first?` — that's expected; run `examples/enroll` instead to enroll, then come back. The examples keep their prints in `test-storage.variant` in the current directory; `examples/identify` matches a scan against all of them.

### Calibration

Every sensor needs its own calibration; the driver does it by itself. When no calibration is stored yet, the next enroll or verify first calibrates the sensor (about a quarter of a second, logged as `calibrating the sensor - do not touch it`): **keep your finger off the sensor until you are asked to tap.** The driver then

1. reads the factory trim stored in the sensor,
2. runs two calibration scans of the empty sensor,
3. saves the result as `calibration.bin` in the storage directory (see below), and
4. builds the capture program from it for every scan.

Set `VALIDITY0088_RECALIBRATE=1` for one run to calibrate again (finger off). The capture program embedded in the source is only a generic skeleton with all sensor-specific parts blank, so scanning without a calibration is not possible: if calibration fails, enroll and verify fail with an error and calibration is retried on the next attempt.

### Matching

The sensor window is too small for classic minutiae matching (a scan holds only 3–9 minutiae). The driver instead reduces each scan to up to 250 SIFT keypoints and accepts a match when enough of them agree with one enrolled tap under a single rotation and shift (RANSAC; up to ±25° rotation).

- **Score** = number of consistent keypoints. Match threshold: **12** (`VALIDITY0088_SIFT_THRESHOLD`). In testing, the enrolled finger scored roughly 20–150 and other fingers at most 5.
- **Prints** store keypoints only (about 33 KB per tap, 10 taps per print), never fingerprint images, and are **encrypted** (AES-256-GCM) with a key kept in the storage directory (`print-key`, created at the first enrollment; no systemd needed; if it cannot be created, the print is stored unencrypted with a warning). Prints made by older versions of this driver (unencrypted, or storing raw scans) still verify; they stay unencrypted until the finger is enrolled again. Without the key, encrypted prints cannot be read: back it up together with the pairing data. Design and limits: [docs/print-encryption.md](docs/print-encryption.md).
- **Identify** scores a scan against every enrolled print and reports the best one above the threshold. fprintd uses this for its duplicate check when you enroll.
- **Coverage matters:** a scan of a finger area that none of the enrolled taps covers scores like a different finger. Vary the placement while enrolling (centre, tip, left and right edge, lower part).

### Per-device data

**You don't need to supply any.** The driver auto-pairs on first open: it generates a fresh keypair, exchanges it with the device, and persists `cert-blob`, `host-key.pem`, and `device-ecdh-pubkey.bin`. Subsequent opens reuse the on-disk material. The sensor calibration (`calibration.bin`, plus `cal-*.bin` debug dumps) and the print encryption key (`print-key`) live in the same directory. All files are mode 600.

The storage directory is

- `$VALIDITY0088_STORAGE_DIR` if set, else
- `$STATE_DIRECTORY/validity-0088-pairing` — under fprintd: `/var/lib/fprint/validity-0088-pairing/`, else
- `~/.local/share/libfprint/verimark-06cb-0088/` (CLI tools such as the libfprint examples).

fprintd and the examples therefore keep separate pairing data and calibrations; each calibrates on its first use.

To skip the autonomous ceremony (e.g., for debugging), set `VALIDITY0088_SKIP_AUTO_PAIR=1`. With that set and no on-disk pair material present, `open()` will fail rather than self-pair, and you can drop your own `cert-blob`, `host-key.pem`, and `device-ecdh-pubkey.bin` into the pairing storage directory by hand.

### Environment variables

| Environment variable | Effect |
|---|---|
| `VALIDITY0088_RECALIBRATE=1` | Calibrate the sensor again in the next enroll/verify (keep the finger off the sensor). |
| `VALIDITY0088_PRINT_ENCRYPTION=0` | Store new prints unencrypted. Encrypted prints can still be read while the key is there. |
| `VALIDITY0088_SIFT_THRESHOLD=<n>` | Match threshold in consistent keypoints (default 12, allowed 4–10000). Higher means fewer false accepts and more false rejects. |
| `VALIDITY0088_LED_RESULT=0` | No LED feedback (success pulse / red flash) after a verify or identify. |
| `VALIDITY0088_DUMP_SCANS=<dir>` | Save every accepted scan (enroll, verify, identify) as a 56 × 144 PGM image named `<time>-<action>-f<finger>.pgm`, for offline evaluation with `tools/scan-eval.c`. These are images of your fingerprints: keep them private and delete them when done. |
| `VALIDITY0088_VERIFY_MODE=enroll` | Capture verify scans with capture mode `0x23` (as enroll taps) instead of `0x02`. Debugging aid. |
| `VALIDITY0088_TRY_HARD_RESET=1` | On the next `open()`, send the device's unpair sequence instead of opening it; then unplug, replug and unset the variable. Recovery tool. |
| `VALIDITY0088_SKIP_AUTO_PAIR=1` | Disable the autonomous pairing on first open. `open()` will fail instead of self-pairing when no on-disk pair material is present. |
| `VALIDITY0088_FLASH_LIVE=1` | Allow the post-handshake pairing ceremony's flash-write step to actually send `0x3f` / `0x41` / `0x42` frames to the device. **The default is dry-run**: the driver computes every frame and hexdumps it via the journal but does NOT send anything. Only set this once you've reviewed the dry-run output and accept the risk of touching partition 1 (the cert store). |
| `VALIDITY0088_FLASH_DRY_RUN=1` | Force dry-run mode even when `VALIDITY0088_FLASH_LIVE=1` is set. Useful as an explicit safety override in scripts. |
| `VALIDITY0088_FORCE_REPAIR=1` | On the next `open()`, wipe the pairing storage dir so the bootstrap runs fresh. The storage dir is `$STATE_DIRECTORY/validity-0088-pairing` when running under `fprintd` (typically `/var/lib/fprint/validity-0088-pairing/`) and `$XDG_DATA_HOME/libfprint/verimark-06cb-0088/` for CLI tools. |
| `VALIDITY0088_STORAGE_DIR=<path>` | Override the pairing-storage directory entirely (testing / non-systemd hosts). |
| `VALIDITY0088_FLASH_SIGNATURE_HEX=<hex>` | When the cert-store flash write needs an attached firmware-extension signature, supply it as a hex string. Not required for the default cert-store write path. |
| `VALIDITY0088_ENROLL_HOSTPART_CMD=<path>` | Override the embedded enroll-time HOSTPART payload with raw bytes at the given path. The file must be 10501 B and start with the `0x06` wire opcode. Debugging aid; not needed in normal operation. |
| `VALIDITY0088_ENROLL_CAPTURE_CMD=<path>` | Send the capture program from this file instead of building it from the calibration. The file must be 18869 B and start with the `0x02` wire opcode; it is sent as is (the capture mode byte is not set and the calibration is not applied). Debugging aid only. |

Variables from older versions (`VALIDITY0088_BZ3_THRESHOLD`, `VALIDITY0088_NCC_THRESHOLD`, `VALIDITY0088_IMAGE_SCALE`, `VALIDITY0088_IMAGE_PARTIAL`, `_IMAGE_INVERT`, `_IMAGE_H_FLIP`, `_IMAGE_V_FLIP`) no longer have any effect.

## 3. Quick Setup (use the fingerprint on the login screen)

The steps below are written for **CachyOS / Arch with KDE Plasma 6** and the Plasma Login Manager (`plasmalogin`). They also apply almost verbatim to other Arch-based systems using SDDM or to other distros with similar PAM stacks; just substitute the right PAM service name.

### Step 1 - Make `fprintd` use your built `libfprint`

**Easy path — use the bundled setup script:**

```bash
sudo packaging/setup-fprintd.sh /path/to/libfprint/builddir
```

That writes the systemd drop-in (keeping a `.bak` copy of any existing one), reloads the daemon, restarts `fprintd.service`, and checks that fprintd really loaded the library from your build. `sudo packaging/setup-fprintd.sh --remove` undoes it. Skip to step 2.

**Optional — keep the print key in a systemd credential** (sealed with the TPM when available; recommended on systemd systems):

```bash
sudo packaging/setup-fprintd.sh --encrypt-prints
```

This stores fprintd's print encryption key in `/etc/credstore.encrypted/validity0088-print-key` (importing the existing key file, so already encrypted prints stay readable) and passes it to fprintd. After a successful `fprintd-verify`, delete the plain key file:

```bash
sudo packaging/setup-fprintd.sh --drop-file-key
```

The credential is not bound to boot measurements (PCRs), so firmware or Secure Boot updates do not lock it; clearing the TPM does (see *Troubleshooting*). The TPM itself is not modified, so a dual-boot Windows (including BitLocker) is not affected.

Run it from a normal terminal: `sudo` does not work inside sandboxed shells (for example an AI assistant's shell) that set the "no new privileges" flag. The build directory may be behind a symlink (such as `~/Documents` pointing to another disk); the script resolves it. After rebuilding the library, `sudo systemctl restart fprintd` makes fprintd load the new build.

**Manual path** — if you'd rather edit by hand, run:

```bash
sudo systemctl edit fprintd.service
```

Add (replace the path with your actual location):

```ini
[Unit]
RequiresMountsFor=/path/to/libfprint/builddir/libfprint

[Service]
Environment=LD_LIBRARY_PATH=/run/libfprint-validity-0088
BindReadOnlyPaths=/path/to/libfprint/builddir/libfprint:/run/libfprint-validity-0088
```

Use the real path (no symlinks) of the build directory. `RequiresMountsFor=` makes fprintd wait at boot until the disk with the build is mounted.

The `BindReadOnlyPaths=src:dst` line bind-mounts the build's lib directory at a stable system path (`/run/libfprint-validity-0088`) inside fprintd's mount namespace, then points `LD_LIBRARY_PATH` at that mount. This is needed because the fprintd unit ships with `ProtectHome=yes`, which hides `/home` from the service — bind-mounting to a `/home`-relative destination wouldn't help (the destination is under the hidden tmpfs), so we bind to a path outside `/home`.

Save, then reload and restart:

```bash
sudo systemctl daemon-reload
sudo systemctl restart fprintd.service
```

### Step 2 - Confirm fprintd sees the device

```bash
fprintd-list "$USER"
```

Expected output names the device as `Synaptics/Validity (pre-Prometheus)`. If you see "No devices available" instead, double-check the `LD_LIBRARY_PATH` and `BindReadOnlyPaths` in the systemd override.

### Step 3 - Enroll a fingerprint

```bash
fprintd-enroll "$USER"
```

If no calibration exists yet for fprintd, the first scan is preceded by a short calibration: keep the finger off the sensor until you are asked to tap. If you already have enrolled fingers, fprintd first asks for one tap to check that the finger is not enrolled yet (duplicate check).

You will then be prompted to "Place your finger" ten times. Use the same finger every time, but **vary where it touches the sensor** (centre, tip, left and right edge, lower part): the sensor sees only about 7 × 3 mm of the finger, and a later scan only matches an area that one of the enrolled taps covered. Lift the finger completely between taps; a tap that is too short or too light is simply asked for again. The LED glows blue while the device waits for a tap. After the tenth accepted tap, `fprintd` reports success and the print is stored in its system-managed location.

### Step 4 - Wire PAM for the login screen

On **Debian / Ubuntu / Linux Mint**, fprintd ships a PAM profile; enable it with

```bash
sudo pam-auth-update --enable fprintd
```

and continue with step 5. On **Arch / CachyOS**, edit the PAM stack by hand as below.

Open a second TTY (Ctrl+Alt+F3) and log in there before changing PAM, so you have a fallback if you misconfigure something.

```bash
sudo cp /etc/pam.d/system-auth /etc/pam.d/system-auth.bak
sudo $EDITOR /etc/pam.d/system-auth
```

Add ONE line at the very top of the `auth` section, before the existing `auth required pam_unix.so` line:

```
auth       sufficient pam_fprintd.so
```

`sufficient` means: if the fingerprint scan succeeds, that is enough to authenticate; if it fails or the user cancels, the prompt falls back to your password. This is the safe setting: as long as your password still works, you cannot lock yourself out.

### Step 5 - Log out and tap to log in

Log out of your current Plasma session (or reboot). At the login screen, click your user and tap your enrolled finger. The desktop should load. If the fingerprint is not recognized, the prompt falls back to asking for your password.

The same PAM stack also applies to KDE's screen locker, so unlocking the screen via fingerprint works after this is set up.

To extend fingerprint authentication to `sudo`, add the same `auth sufficient pam_fprintd.so` line to the top of `/etc/pam.d/sudo`.

### Troubleshooting

- **Look at the log first:** `journalctl -u fprintd -n 50`. For the libfprint examples, run them with `G_MESSAGES_DEBUG=all`.
- **"device did not return an image"** during a scan means the tap was too short or too light (status `0x0007`); the scan is simply asked for again.
- **Verify works for some placements only:** enroll the finger again with more varied placement (step 3).
- **Calibration seems off** (many failed scans, low match scores after moving the device to another machine or after a firmware change): run once with `VALIDITY0088_RECALIBRATE=1` and the finger off the sensor. For fprintd, delete `/var/lib/fprint/validity-0088-pairing/calibration.bin` instead (as root) and restart fprintd.
- **fprintd stopped working after the build directory moved:** run `setup-fprintd.sh` again with the new path.
- **fprintd does not start, journal shows status `243/CREDENTIALS`:** the print key credential can no longer be decrypted, typically because the TPM was cleared (firmware setup, Windows "Clear TPM", or some firmware updates). The prints encrypted with that key are lost. To recover:

  ```bash
  sudo mv /etc/credstore.encrypted/validity0088-print-key /etc/credstore.encrypted/validity0088-print-key.broken
  sudo systemctl restart fprintd
  fprintd-delete "$USER"
  fprintd-enroll "$USER"
  sudo packaging/setup-fprintd.sh --encrypt-prints
  ```

  The new enrollment creates a new key file, which `--encrypt-prints` turns into a new credential; then run `--drop-file-key` after a successful verify.
- **"Stored print is encrypted with key …, which is not available":** the key that print was made with is gone (deleted `print-key`, other machine). Restore the key from a backup, or delete the print and enroll the finger again.
- **Prints enrolled with a much older version** of this driver (NBIS era) do not verify any more: delete them (`fprintd-delete "$USER"`) and enroll again.

## 4. Copyright

This project is published under the GNU Lesser General Public License version 2.1 or later (LGPL-2.1-or-later), matching upstream `libfprint`. See the `LICENSE` file for the full text.

**Disclaimer of affiliation.** This is an independent, open-source community project. The maintainers of this repository have no affiliation with, endorsement from, or sponsorship by Kensington Computer Products Group, ACCO Brands Corporation, Synaptics Incorporated, or any other company whose hardware or software is referenced in this work. "Kensington" and "VeriMark" are trademarks of their respective owners; all references to those marks in this repository are descriptive nominative use only, used solely to identify the hardware device this driver supports. Any other product or company names mentioned may be trademarks of their respective owners.

**No warranty.** This driver is provided "as is", without warranty of any kind, express or implied, including but not limited to the warranties of merchantability, fitness for a particular purpose, and noninfringement. In no event shall the contributors be liable for any claim, damages, or other liability arising from the use of this software. See the LICENSE file for the full warranty disclaimer.

**Security note.** Fingerprint authentication on a consumer USB device is convenient but not equivalent to a hardware-isolated secure enclave. Treat it as a convenience layer on top of (not a replacement for) strong password authentication and full-disk encryption.
