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

Two runs and a reboot on an 83CV with Ubuntu 26.10 (kernel 7.3.0) on 2026-11-15. The second run finished with no warnings.

| Part | Result |
|---|---|
| Woofer fix | Works. The sound driver reports `picked fixup alc287-yoga9-bass-spk-pin`. |
| Hibernation | Works. Hibernated and resumed twice; closing the lid hibernates. Secure Boot is off on this laptop. |
| Automatic battery/mains switching | Works when the charger is plugged in or pulled out and after waking. It did **not** run at boot: the unit was tied to `multi-user.target`, which loops with `power-profiles-daemon`, so systemd dropped it. Now tied to `graphical.target` and installed that way on the laptop; a boot has not confirmed it yet. |
| Idle devices, Wi-Fi power save | Applied: 24 PCI devices allowed to sleep; camera and Bluetooth suspend when unused. |
| Face login | Howdy 3.0.1 installed and a face enrolled. |
| Password-less keyring | Works; applications save into it without a prompt. |
| Claude Desktop 5.11492.5, Claude Code 2.1.311 | Installed and running. |
| Speaker sound profile | Installed on the second run: PipeWire loads the `Dolby_Balanced` filter and attaches it to the speakers. It failed on the first run because `libspa-0.2-modules-extra` was missing; the script installs it now. It loads again after a reboot. How it sounds has not been judged. |
| Compressed swap (zswap) | Works after the reboot: `zswap: loaded using pool lz4`. |
| Swapfile at 150% of the RAM (22 GiB) | Works: the 16 GiB swapfile in use was replaced by a 22 GiB one, and the boot option, the running kernel and `/etc/fstab` all point at it. After the reboot the kernel was started with the new position. Hibernating to the new file has not been tested yet. |
| `yoga-scale` | Works: 110, 112, 120, `125x0.9` and `125x0.8` were all applied on the laptop. |
| `--windows-fonts` | Tried on the laptop and rendered correctly in a test window; the owner went back to Ubuntu's fonts, so it is off by default. |
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
| Swapfile sized at 150% of the RAM (22 GiB here) | Hibernation writes the whole memory to swap, and needs room on top of that for what is already swapped out. If an existing swap area is already that big it is used as it is; otherwise the swapfile is replaced, or `/swap.img` is created. While it is replaced a temporary swapfile takes over, so it works with memory nearly full. | `/swap.img`, `/etc/fstab` (old copy in `/etc/fstab.yoga-slim7.bak`) |
| Resume boot option | Tells the kernel where the saved image is. | `/etc/default/grub.d/91-yoga-slim7-hibernate.cfg`, and for the early boot image `/etc/dracut.conf.d/90-yoga-slim7-resume.conf` (Ubuntu 26.10 uses dracut; on installs with initramfs-tools it is `/etc/initramfs-tools/conf.d/yoga-slim7-resume`) |
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
To use a different size, change `SWAP_PERCENT` at the top of `install.sh`; the script only ever enlarges the swapfile.

### Drivers

| Change | Why | Where |
|---|---|---|
| Woofer routing | The kernel has no entry for this laptop's sound codec (17aa:38d8), so without this the speakers sound thin. | `/etc/modprobe.d/yoga-slim7-audio.conf` |
| Sound firmware and Intel video decoder | Makes sure both are installed, so video playback uses the GPU, not the CPU. | packages |

### Fonts (only with `--windows-fonts`)

Ubuntu's own fonts and text smoothing are left alone unless you ask for this.

| Change | Why | Where |
|---|---|---|
| Interface font: Selawik | Microsoft's open stand-in for Segoe UI, so menus and windows look as they did on Windows. Shipped inside this kit. | `~/.local/share/fonts/selawik`, your desktop settings |
| Segoe UI requests answered by Selawik | Teams, Outlook, WhatsApp and GitHub ask for Segoe UI first; without this they fall back to Arial. | `~/.config/fontconfig/conf.d/45-yoga-slim7-fonts.conf` |
| Code and terminal font: Consolas | The Visual Studio default. Only set when Consolas is installed. | your desktop settings |
| Greyscale text smoothing | Ubuntu's colour smoothing is made for LCD stripes; on this OLED panel it puts coloured edges on letters in browsers and Electron applications. | both of the above |

### Tools

| Tool | What it does | Where |
|---|---|---|
| `yoga-power` | Status, real battery draw, charge limit, suspend reports. | `/usr/local/bin/yoga-power` |
| `yoga-scale` | In-between screen sizes such as 110% or 120%, which GNOME's Settings does not offer. | `/usr/local/bin/yoga-scale` |
| Suspend report | Logs every suspend: duration, how deep the sleep was, battery used. | `/usr/lib/systemd/system-sleep/yoga-sleep-report` |

Everything the script does is logged to `/var/log/yoga-slim7-tuning.log`.

## Options

```bash
sudo bash install.sh --keep-desktop   # leave dark style, dimming and idle times alone
sudo bash install.sh --windows-fonts  # also switch to Selawik, Consolas and greyscale smoothing
sudo bash install.sh --no-hibernate   # no swapfile change, no resume boot option
sudo bash install.sh --no-zswap       # do not switch on compressed swap
sudo bash install.sh --no-speaker-tuning  # woofer fix only, no Dolby sound profile
sudo bash install.sh --no-face-login  # do not install Howdy
sudo bash install.sh --no-claude      # do not install Claude Desktop and Claude Code
sudo bash install.sh --keep-keyring   # keep the keyring locked by your login password
sudo bash install.sh --no-lpmd        # do not install intel-lpmd
sudo bash install.sh --force          # run on a laptop that is not an 83CV (not tested anywhere else)
```

Running the script again is safe. If you changed a desktop option back after the first run (for example from the dark style to the light one), the script leaves your choice alone.

## Adjusting it

Edit `/etc/yoga-power.conf`, then run `sudo yoga-power apply`:

- `ON_BATTERY_PROFILE=balanced` if Power Saver feels too slow when unplugged.
- `BATTERY_NO_TURBO=1` to switch CPU turbo boost off on battery: more runtime under load, slower bursts.

A profile you pick by hand (Fn+Q or the GNOME menu) stays until the settings are next applied: when the charger is plugged in or pulled out, after waking from sleep, at boot, and when `install.sh` runs.

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

## Screen size in between GNOME's steps

GNOME's Settings offers 100%, 125%, 133%, 150% and so on, but nothing in between. `yoga-scale` reaches any size by combining the display scale with GNOME's text scaling:

```bash
yoga-scale status      # what is set now
yoga-scale 110         # 100% display x 1.10 text
yoga-scale 120         # 100% display x 1.20 text
yoga-scale 125         # back to plain 125%
yoga-scale 125x0.9     # choose both parts: 125% display with text at 0.9 (about 112%)
yoga-scale 120 --dry-run   # show the split and check GNOME accepts it, change nothing
```

It needs no `sudo`. How applications respond:

- **Brave and Electron applications** (VS Code, Claude, Teams and the like) follow the combined size exactly.
- **GNOME's own applications** scale their text, and the buttons and rows that hold it. Icons follow the display scale only, so at 110% or 120% they stay at their 100% size.

The two ways to reach about 110% differ in what stays large:

| Command | Icons, top bar, window buttons | Text |
|---|---|---|
| `yoga-scale 110` (100% display x 1.10 text) | small, at 100% | 110% |
| `yoga-scale 125x0.9` (125% display x 0.90 text) | large, at 125% | about 112% |

**For clean text, prefer the plain form (`yoga-scale 110`, `yoga-scale 112`).** A 100% display is drawn pixel for pixel. At 125%, newer applications (GNOME's own, Brave, Electron) still draw sharply, but older ones cannot draw at 125% at all: GTK 3 programs such as DBeaver draw at 200% and GNOME shrinks the picture, which blurs their text. Measured on this laptop with the same font and size, the edges of DBeaver's letters have about a third less contrast at `125x0.9` than at `112`. No font setting changes that; only a whole-number display scale does. `yoga-scale` prints a note whenever you choose a display scale with this effect.

With an external monitor connected, the display scale is left alone and only the text scaling is adjusted.

## Fonts

This part is optional. Run the script with `--windows-fonts` to get it; it then sets up the fonts for the person who ran `sudo`, in their home folder:

- **Selawik** comes with the kit (`files/fonts/selawik`, version 1.01, identical to Microsoft's release, SIL Open Font License). It has no true italic; applications slant the regular shape instead.
- **Consolas** is not in the kit, because it is Microsoft's property. It arrives with `ttf-mscorefonts-installer`, which asks you to accept Microsoft's licence, so the script does not install it for you. Without it, the code font stays as it is.
- **Open applications keep their old fonts** until you restart them.

Why a plain font substitution was not enough: browsers and Electron applications only accept a substitute font when it is the first choice after substitution. The rules file therefore uses `prefer`; an `accept` rule looks right in `fc-match` and is silently ignored by Brave, Teams and the rest.

To see what an application will get:

```bash
fc-match "Segoe UI"      # Selawik
fc-match monospace       # Consolas
```

If text looks too soft with greyscale smoothing and you want Ubuntu's colour smoothing back, remove the last two `<match>` blocks from the rules file (the script keeps a rules file you have edited) and run:

```bash
gsettings set org.gnome.desktop.interface font-antialiasing rgba
```

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

It also downloads the three face-recognition model files Howdy needs (about 30 MB, from dlib's model repository) by running Howdy's own `/etc/howdy/dlib-data/install.sh`, so the first `sudo howdy add` does not stop and ask you to run it.

It also keeps the camera's **infrared light on** during a scan. On its own, this camera flashes the light a few times when it starts and then leaves it off, so Howdy sees only a dark outline and times out ("Failure, timeout reached"). The script installs [linux-enable-ir-emitter](https://github.com/EmixamPP/linux-enable-ir-emitter) 7.0.0 (the release download, checked against its SHA-256), writes the setting that keeps the light on to `~/.config/linux-enable-ir-emitter.toml`, and adds it to the login settings so the light is switched on before every face scan. The setting (UVC unit 14, selector 6, value `1 3 2`) was found on this laptop with `linux-enable-ir-emitter configure`; it is only written when the camera `04f2:b7f5` is present, and a config that already has a setting is kept.

It replaces Howdy's "Loading..." bar with a **Face ID-style popup**: a small rounded square under the camera with the Face ID symbol, which pulses while it scans and turns into a tick ("Recognised") when it knows you. Howdy's own popup file is moved aside with `dpkg-divert` (kept as `/usr/lib/howdy-gtk/authsticky.py.howdy`), so a Howdy update does not overwrite the new one. The tick comes from a small Howdy rubberstamp (`/lib/security/howdy/rubberstamps/faceid.py`, rule `faceid 1s failsafe` in `/etc/howdy/config.ini`): it adds about a third of a second to a successful sign-in and can never block one. Howdy does not tell the popup about a failure, so then it simply closes and the password prompt follows. The files are in `files/howdy-faceid/`.

After the reboot, enrol your face and test:

```bash
sudo howdy add     # look at the camera
sudo -k true       # should print "Identified face as <you>" with no password
sudo howdy test    # shows what the infrared camera sees: your face should be lit
```

What to expect:

- **Where it works:** the login screen, the lock screen and `sudo`. Your face is tried first; if you are not recognised, the password prompt follows as usual.
- **Keyring prompt:** a face login cannot unlock a password-protected keyring, so the script sets up a keyring without a password. See the next section.
- **Security:** Howdy's authors say plainly that it is less secure than a password and must not be the only way in. A good photo or a lookalike may pass.
- **Lid closed:** Howdy skips itself, so a docked laptop asks for the password straight away.

If your face is still a dark outline in `sudo howdy test` (another camera, or a firmware update changed the control), find the setting again. It asks whether the light is blinking after each try: answer **n** at the first question when the light only flashes at the start, and **y** only when it keeps flashing, otherwise it stops with "already working" and saves nothing.

```bash
linux-enable-ir-emitter configure
sudo linux-enable-ir-emitter setup-howdy
```

Re-enrol (`sudo howdy add`) after the light starts working, since a face saved in the dark matches badly.

Skip face login, including the infrared step and the popup, with `--no-face-login`. `--undo` puts Howdy's own popup and rubberstamp settings back, removes the infrared step from the login settings and the setting the script wrote, then Howdy.

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
- **Release channel:** Claude Code comes from the `stable` channel, about a week behind the newest release. To follow every release, change `stable stable` to `latest latest` in `/etc/apt/sources.list.d/claude-code.list`; the script leaves that line alone once it exists.
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

This removes the files the script wrote, the sound profile, Howdy (with its PPA), both Claude packages with their repositories and signing keys (`~/.claude` is kept), and the font rules (the Selawik files stay). It puts your previous desktop settings back, fonts included, and closing the lid suspends again.

What stays, on purpose:

- **Ordinary Ubuntu packages** that were installed.
- **The swapfile** at its new size, with its line in `/etc/fstab`. The `fstab` from before the kit is kept as `/etc/fstab.yoga-slim7.bak`.
- **Your membership of the `kvm` group**, if an earlier version of this kit added it. Versions from 2026-11-15 on remember adding it and take it back.

The script says so if something could not be undone. Reboot afterwards.
