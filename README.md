# Ubuntu 26.10 tuning for the Lenovo Yoga Slim 7 14IMH9 (83CV)

Run this once, after Ubuntu is installed on the SSD and the laptop is online.
Run it from a terminal inside your desktop session, so it can also set the desktop options:

```bash
sudo bash install.sh
```

Then reboot and finish in this order:

```bash
yoga-power status
sudo yoga-power hibernate-test    # check that hibernation really resumes
sudo yoga-power lid hibernate     # only after the test worked
yoga-power measure                # on battery: the real power draw
sudo howdy add                    # save your face for face login
```

The script only runs on an 83CV, refuses to run in the live USB session, and can be run again safely.

## Checked on the real laptop

First run on an 83CV with Ubuntu 26.10 (kernel 7.3.0), 2026-11-15:

| Part | Result |
|---|---|
| Woofer fix | Works. The sound driver reports `picked fixup alc287-yoga9-bass-spk-pin`. |
| Hibernation | Works. Hibernated and resumed twice; closing the lid hibernates. Secure Boot is off on this laptop. |
| Automatic battery/mains switching | Works: Power Saver, `low-power` platform profile and the 60 s disk flush apply on battery. |
| Idle devices, Wi-Fi power save | Applied: 24 PCI devices allowed to sleep; camera and Bluetooth suspend when unused. |
| Face login | Howdy 3.0.1 installed and a face enrolled. |
| Password-less keyring | Works; applications save into it without a prompt. |
| Claude Desktop 5.11492.5, Claude Code 2.1.311 | Installed and running. |
| Speaker sound profile | **Failed on the first run**: PipeWire could not load LV2 plugins. The missing package (`libspa-0.2-modules-extra`) is now installed by the script; not yet confirmed. |
| Compressed swap (zswap) | Added after this run; not yet confirmed. |
| Plain suspend (S0ix) and idle battery draw | Not measured yet. |

## What it changes

### Battery life

| Change | Why it helps | Where |
|---|---|---|
| Dark style | An OLED pixel showing black is switched off. This is the biggest single saving on this screen. | your desktop settings |
| Screen dims when idle, off after 3 minutes | The screen is the largest consumer. | your desktop settings |
| Suspend after 10 idle minutes on battery | Stops an unattended laptop from draining. | your desktop settings |
| Power Saver profile on battery, Balanced on mains, switched automatically | Lowers the CPU's energy preference and Lenovo's firmware power limits while unplugged. | `/etc/yoga-power.conf`, `yoga-power-auto.service` |
| Disk cache flushed every 60 s on battery (15 s on mains) | Lets the SSD stay asleep for longer. | `/etc/yoga-power.conf` |
| Idle PCI devices and the camera power down | Unused chips stop drawing power and the CPU can reach deeper idle states. | `/etc/udev/rules.d/90-yoga-slim7-power.rules` |
| Wi-Fi power save pinned on | The radio sleeps between packets. | `/etc/NetworkManager/conf.d/90-yoga-slim7-wifi-powersave.conf` |
| NMI watchdog off | Removes a periodic CPU wake-up. | `/etc/sysctl.d/90-yoga-slim7-power.conf` |
| Power-efficient kernel work queues | Background kernel work runs on a core that is already awake. Skipped if the kernel already has it on. | `/etc/default/grub.d/90-yoga-slim7-power.cfg` |
| Compressed swap (zswap) | Memory on its way to the swapfile is compressed and kept in RAM first, so the SSD is woken and written far less when memory is full. On this laptop about 2 GB was in swap during normal work. Skipped if the kernel already has it on. | `/etc/default/grub.d/90-yoga-slim7-power.cfg` |
| `thermald`, `power-profiles-daemon`, `intel-lpmd` enabled | Intel's and Ubuntu's own power daemons. `intel-lpmd` adjusts the CPU's energy preference to the workload the CPU reports. | services |

### Hibernation

| Change | Why | Where |
|---|---|---|
| Swapfile enlarged to the RAM size plus 1 GiB (17 GiB here) | Hibernation writes the whole memory to swap. If an existing swap area is already big enough it is used as it is; otherwise the swapfile is replaced, or `/swap.img` is created. | `/swap.img`, `/etc/fstab` (old copy in `/etc/fstab.yoga-slim7.bak`) |
| Resume boot option | Tells the kernel where the saved image is. | `/etc/default/grub.d/91-yoga-slim7-hibernate.cfg`, `/etc/initramfs-tools/conf.d/yoga-slim7-resume` |
| Lid action | Set by you with `yoga-power lid ...` after the test passes. | `/etc/systemd/logind.conf.d/90-yoga-slim7-lid.conf` |

**Secure Boot must be off.** Ubuntu's kernel refuses to hibernate while Secure Boot is on. If it is on, the script says so and skips this part; switch it off in the BIOS setup (F2 at power-on, Security, Secure Boot) and run the script again. If Windows with BitLocker is still on the disk, have its recovery key ready before changing this.

The lid is not switched to hibernate automatically. A hibernation that fails to resume loses your open work, so test it once first:

```bash
sudo yoga-power hibernate-test             # powers off; press the power button; your windows should come back
sudo yoga-power lid hibernate              # closing the lid hibernates: zero drain, about 20 s to wake
sudo yoga-power lid suspend-then-hibernate # or: suspend first, hibernate after 30 minutes
sudo yoga-power lid suspend                # back to Ubuntu's default
```

With an external monitor attached, closing the lid is still ignored, as on a stock Ubuntu.
Run `install.sh` again if you ever recreate the swapfile: its position on the disk is part of the boot option.

### Drivers

| Change | Why | Where |
|---|---|---|
| Woofer routing | The kernel has no entry for this laptop's sound codec (17aa:38d8), so without this the speakers sound thin. | `/etc/modprobe.d/yoga-slim7-audio.conf` |
| Sound firmware and Intel video decoder | Makes sure both are installed, so video playback uses the GPU, not the CPU. | packages |

### Tools

| Tool | What it does | Where |
|---|---|---|
| `yoga-power` | Status, real battery draw, charge limit, suspend reports. | `/usr/local/bin/yoga-power` |
| Suspend report | Logs every suspend: duration, how deep the sleep was, battery used. | `/usr/lib/systemd/system-sleep/yoga-sleep-report` |

Everything the script does is logged to `/var/log/yoga-slim7-tuning.log`.

## Options

```bash
sudo bash install.sh --keep-desktop   # leave dark style, dimming and idle times alone
sudo bash install.sh --no-hibernate   # no swapfile change, no resume boot option
sudo bash install.sh --no-zswap       # do not switch on compressed swap
sudo bash install.sh --no-speaker-tuning  # woofer fix only, no Dolby sound profile
sudo bash install.sh --no-face-login  # do not install Howdy
sudo bash install.sh --no-claude      # do not install Claude Desktop and Claude Code
sudo bash install.sh --keep-keyring   # keep the keyring locked by your login password
sudo bash install.sh --no-lpmd        # do not install intel-lpmd
```

Running the script again is safe. If you changed a desktop option back after the first run (for example from the dark style to the light one), the script leaves your choice alone.

## Adjusting it

Edit `/etc/yoga-power.conf`, then run `sudo yoga-power apply`:

- `ON_BATTERY_PROFILE=balanced` if Power Saver feels too slow when unplugged.
- `BATTERY_NO_TURBO=1` to switch CPU turbo boost off on battery: more runtime under load, slower bursts.

A profile you pick by hand (Fn+Q or the GNOME menu) stays until the charger is next plugged in or pulled out.

## Checking that it works

```bash
yoga-power measure 120            # average battery draw over two minutes, and hours left at that rate
yoga-power sleep-log              # last 10 suspend reports
sudo powertop                     # what is waking the CPU
```

Measure the same activity before and after a change; that is the only reliable way to know whether it helped.
To judge `intel-lpmd`, compare `yoga-power measure` with it running and after `sudo systemctl stop intel_lpmd`.

A healthy suspend report looks like `slept 8h02m10s, S0ix 97%, used 1.90 Wh (236 mW average)`.
If S0ix stays near 0%, something is keeping the laptop awake while the lid is closed.

## Battery charge limit

Left as it is, because capping at 80% trades runtime for battery lifespan. On this laptop it was already on at the first Ubuntu boot. The setting lives in the laptop's firmware, so it most likely carried over from Windows.

```bash
yoga-power battery status         # what it is set to now
```

To change it:

```bash
sudo yoga-power battery conserve  # stop charging at about 80%
sudo yoga-power battery full      # charge to 100%
```

## What it deliberately leaves alone

- **The kernel drivers themselves.** Graphics, Wi-Fi, sound and SSD drivers are maintained by Intel and already default to their deepest power states on this chip. The savings are in the settings above, not in changing driver code.
- **SSD link power states.** Forcing deeper states than the firmware sets up has caused freezes on this SSD family (WD SN740).
- **External USB devices.** Blanket USB power saving makes mice and keyboards lag.
- **TLP.** It conflicts with `power-profiles-daemon`.

## Speaker sound profile

The woofer fix makes all four speakers play. On top of that, the script rebuilds the sound profile Windows applies:

- `dolby-tuning/` holds this laptop's own Dolby tuning file, copied from its Windows driver.
- The script downloads [speaker-tuning-to-easyeffects](https://github.com/antoinecellerier/speaker-tuning-to-easyeffects) release `v2026.10.1` into `/opt/yoga-slim7` and runs its `dolby_to_pipewire.py` as you, never as root.
- The download is checked against a fixed commit hash (`2838efda3e5b…`). If it is anything else, it is deleted and not run. To move to a newer release, change `SPEAKER_TOOL_TAG` and `SPEAKER_TOOL_COMMIT` in `install.sh` together.
- The result is a PipeWire filter in `~/.config/pipewire/pipewire.conf.d/` that loads every time sound starts. No extra application has to run.

It needs PipeWire's LV2 support (`libspa-0.2-modules-extra`), which Ubuntu does not install by default; the script adds it. The sound cuts out for a moment while it installs. Judge the result after the reboot, when the woofers are active.

```bash
python3 /opt/yoga-slim7/speaker-tuning-to-easyeffects/dolby_to_pipewire.py --doctor      # check it
python3 /opt/yoga-slim7/speaker-tuning-to-easyeffects/dolby_to_pipewire.py --uninstall   # remove it
```

It is close to the Windows sound, not identical: Dolby Atmos itself is Windows-only. Skip it with `--no-speaker-tuning`.

## Face login

The script installs [Howdy](https://github.com/boltgolt/howdy) 3 from its author's PPA (`ppa:boltgolt/howdy`), because it is not in the Ubuntu archive, and points it at the infrared camera. The install compiles a face-recognition library, which takes several minutes.

After the reboot, enrol your face and test:

```bash
sudo howdy add     # look at the camera
sudo howdy test    # shows what the infrared camera sees
sudo -i            # in a new terminal: should recognise you without a password
```

What to expect:

- **Where it works:** the login screen, the lock screen and `sudo`. Your face is tried first; if you are not recognised, the password prompt follows as usual.
- **Keyring prompt:** a face login cannot unlock a password-protected keyring, so the script sets up a keyring without a password. See the next section.
- **Security:** Howdy's authors say plainly that it is less secure than a password and must not be the only way in. A good photo or a lookalike may pass.
- **Lid closed:** Howdy skips itself, so a docked laptop asks for the password straight away.

If `sudo howdy test` shows a black or very dark picture, the infrared light is not switching on. That needs a one-off interactive setup with [linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter), which asks you to watch the light, so the script cannot do it for you:

```bash
# download linux-enable-ir-emitter-7.0.0-release-x86-64.tar.gz from the project's releases page, then:
sudo tar -C /usr/local/bin/ --no-same-owner -m -vxzf linux-enable-ir-emitter*.tar.gz
linux-enable-ir-emitter configure
sudo linux-enable-ir-emitter setup-howdy
```

Skip face login with `--no-face-login`. Remove it later with `sudo apt remove howdy howdy-gtk`.

## Password keyring without a password

GNOME keeps saved passwords (browser, application sign-ins, some Wi-Fi) in a keyring that is normally encrypted with your login password. After a face login nothing has typed that password, so every application that needs the keyring asks for it.

The script stops those prompts by making a keyring that has no password the default one:

| File | What it is |
|---|---|
| `~/.local/share/keyrings/Default_keyring.keyring` | The new keyring, in gnome-keyring's plain-text format. |
| `~/.local/share/keyrings/default` | Names the keyring applications use by default. Was `login`, now `Default_keyring`. |

It takes effect the next time you log in.

**The trade-off:** anything saved in that keyring is stored unencrypted. Anyone who can read the disk, for example by booting the laptop from a USB stick, can read those passwords. Disk encryption is what protects them; you choose it in the Ubuntu installer ("Encrypt this installation"), and it asks for a passphrase at every boot.

The script checks whether your home folder is on an encrypted disk. If it is not, it still sets this up, because you asked for no prompts, but it prints a warning and counts it in the final summary.

Other details:

- The original `login` keyring is left untouched. Anything already saved in it stays there, still protected by your login password.
- `sudo`, the lock screen and the login screen are not affected; those are handled by face login, with your password as the fallback.
- Skip this with `--keep-keyring`. To go back later, `sudo bash install.sh --undo` points the default back to `login` and keeps the password-less keyring file, because it holds whatever was saved meanwhile.

## Claude Desktop and Claude Code

The script installs both from Anthropic's own apt repositories, so they update with the normal system updates (`sudo apt update && sudo apt upgrade`):

| Package | What it is | Start it with |
|---|---|---|
| `claude-desktop` | The desktop app: Chat, Cowork and Claude Code. A beta on Linux. | "Claude" in the application menu |
| `claude-code` | The terminal command. | `claude` |

How it is done:

- **Signing key check:** before either repository is trusted, the script downloads Anthropic's signing key and compares its fingerprint with the published one (`31DD DE24 DDFA B679 F42D 7BD2 BAA9 29FF 1A7E CACE`). If it differs, nothing is installed.
- **Release channel:** Claude Code comes from the `stable` channel, about a week behind the newest release. To follow every release, change `stable stable` to `latest latest` in `/etc/apt/sources.list.d/claude-code.list`.
- **Cowork:** it runs its tasks in a virtual machine, so the script adds you to the `kvm` group. Log out and back in once for that to apply.

After the install, open Claude and sign in, then run `claude` in a terminal and sign in there too. Your settings, skills and session history are not copied from Windows; they live in `~/.claude` and have to be brought over separately.

Things to know about the Linux beta:

- **Ubuntu 26.10 is not on Anthropic's tested list** (Ubuntu 22.04 or later is the stated requirement), but both packages installed and run on this laptop under 26.10.
- **Not available yet:** Computer Use and dictation.
- **"Cowork requires the vhost_vsock kernel module":** run `sudo modprobe vhost_vsock` and restart the app.

Skip both with `--no-claude`.

## Not covered

- **NPU:** the kernel driver loads, but Intel's user-space driver is a separate download from GitHub.
- **Dolby Atmos, Windows Studio Effects, Lenovo walk-away lock:** Windows only.

## Undo

```bash
sudo bash install.sh --undo
```

This removes every file listed above, the sound profile, Howdy (with its PPA) and both Claude packages (with their repositories; `~/.claude` is kept), and puts your previous desktop settings back. Closing the lid suspends again. Ordinary Ubuntu packages stay installed and the swapfile keeps its new size. Reboot afterwards.
