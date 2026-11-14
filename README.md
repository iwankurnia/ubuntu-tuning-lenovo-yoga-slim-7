# Ubuntu 26.10 tuning for the Lenovo Yoga Slim 7 14IMH9 (83CV)

Run this once, after Ubuntu is installed on the SSD and the laptop is online.
Run it from a terminal inside your desktop session, so it can also set the desktop options:

```bash
sudo bash install.sh
```

Then reboot, unplug the charger and measure:

```bash
yoga-power status
yoga-power measure
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
- **Hibernation.** It would stop all drain during long sleeps, but it needs a large swap area and does not work with Secure Boot on. Decide after reading a week of `yoga-power sleep-log`.
- **External USB devices.** Blanket USB power saving makes mice and keyboards lag.
- **TLP.** It conflicts with `power-profiles-daemon`.

## Speaker tuning (optional)

The woofer fix gives full-range sound, but not the Dolby tuning Windows applies.
`dolby-tuning/` holds this laptop's own tuning file, copied from its Windows driver.
To turn it into an EasyEffects preset:

```bash
sudo apt install easyeffects python3-numpy python3-scipy python3-rich python3-rich-argparse git
git clone https://github.com/antoinecellerier/speaker-tuning-to-easyeffects.git
cd speaker-tuning-to-easyeffects
python3 dolby_to_easyeffects.py /path/to/dolby-tuning/DEV_0287_SUBSYS_17AA38D8_PCI_SUBSYS_383917AA.xml --autoload
```

## Not covered

- **Face login:** the IR camera works, but Howdy is not in the Ubuntu 26.10 archive.
- **NPU:** the kernel driver loads, but Intel's user-space driver is a separate download from GitHub.
- **Dolby Atmos, Windows Studio Effects, Lenovo walk-away lock:** Windows only.

## Undo

```bash
sudo bash install.sh --undo
```

This removes every file listed above and puts your previous desktop settings back. Packages stay installed. Reboot afterwards.
