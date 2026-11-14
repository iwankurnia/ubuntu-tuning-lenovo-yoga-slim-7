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
sudo bash install.sh --no-speaker-tuning  # woofer fix only, no Dolby sound profile
sudo bash install.sh --no-face-login  # do not install Howdy
sudo bash install.sh --no-lpmd        # do not install intel-lpmd
```

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

Left as it is, because capping at 80% trades runtime for battery lifespan:

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

The sound cuts out for a moment while it installs. Judge the result after the reboot, when the woofers are active.

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
- **Keyring prompt:** after a face login, GNOME asks for your password once to unlock saved passwords, because they are encrypted with it.
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

## Not covered

- **NPU:** the kernel driver loads, but Intel's user-space driver is a separate download from GitHub.
- **Dolby Atmos, Windows Studio Effects, Lenovo walk-away lock:** Windows only.

## Undo

```bash
sudo bash install.sh --undo
```

This removes every file listed above, the sound profile and Howdy (with its PPA), and puts your previous desktop settings back. Closing the lid suspends again. Ordinary Ubuntu packages stay installed and the swapfile keeps its new size. Reboot afterwards.
