# 🌐 Network Indicator — DankBar Widget

A real-time network speed and data usage monitor plugin for [DankMaterialShell](https://danklinux.com/docs/dankmaterialshell/overview). It shows upload (↑) and download (↓) speeds directly in your DankBar, and automatically tracks your daily data usage!

![Screenshot 1](screenshot.png)
![Screenshot 2](screenshot2.png)

## ✨ Features

- 📊 **Live upload & download speeds** right in your DankBar
- 🔀 **Multi-interface aware** — all active interfaces are tracked and summed, not just the first one
- 🗂️ **Interface groups** — bucket interfaces with regex patterns (e.g. `VPN = (wg|tun).*`) and view each group's traffic, live and in history
- 📱 **Per-app traffic** (optional) — see which programs are using bandwidth while the popout is open (requires `nethogs`)
- 📅 **30-day data usage history** — persistent across reboots, filterable by group or WiFi network
- 🔌 **Automatic offline detection** — shows when your connection drops
- ↕️ **Works in horizontal and vertical bars**
- ⚙️ **Configurable** — combined or separate speed readouts, adjustable units & polling rate
- 🪶 **Minimal dependencies** — uses Linux built-ins; optional `iwgetid`/`nmcli` for per-WiFi-network naming, optional `nethogs` for per-app traffic

## 📦 Installation

### Option 1: DMS Plugin Manager (recommended)

1. Open **DMS Settings** → **Plugins**
2. Click **Browse** and search for **Network Indicator**
3. Click **Install**, then restart: `dms restart`

### Option 2: DMS CLI

```bash
dms plugins install network-indicator
dms restart
```

### Option 3: Manual (git clone)

```bash
cd ~/.config/DankMaterialShell/plugins
git clone https://github.com/gemb0-0/Network-Indicator.git "Network Indicator"
dms restart
```

### After installing

1. Open **DMS Settings → Plugins** and click **Scan for Plugins**
2. Toggle **Network Indicator** on
3. Add it to your **DankBar** widget list
4. Restart: `dms restart`

## 🎛️ Settings

| Setting | Description | Default |
|---------|-------------|---------|
| **Update Interval** | Polling frequency in seconds (e.g., `1` to `10`) | 2 sec |
| **Display Unit** | Auto / KB/s / MB/s | Auto |
| **Display Mode** | **Separate** (show ↑ and ↓) or **Combined** (single total speed) | Separate |
| **Tracked Interfaces** | Restrict tracking to specific interfaces (their traffic is summed); empty means all real interfaces | All real interfaces |
| **Interface Groups** | Named regex buckets for viewing traffic per group (see below) | None |
| **Per-App Traffic** | Live per-application rates in the popout, via `nethogs` | Off |

### Interface Groups

Each group is a **name** plus a **pattern**. Patterns are regular expressions matched
against the *whole* interface name — `en.*` matches `enp5s0f1`, and a plain name like
`wlan0` works as-is. Groups are **ordered**: an interface counts toward the *first*
group whose pattern matches, and anything unmatched lands in an implicit **Other**
bucket. Group totals appear in the popout and as filter chips in the 30-day history;
because grouping is applied at view time, editing a pattern re-groups your existing
history retroactively. An interface matched by a group pattern is tracked even if it
would normally be skipped as virtual (docker, veth, …), so a `Docker = (docker|br-|veth).*`
group does what you'd expect.

### Per-App Traffic

Enable the **Per-App Traffic** toggle and install [`nethogs`](https://github.com/raboof/nethogs).
nethogs needs packet-capture capabilities to see traffic:

```bash
sudo setcap 'cap_net_admin,cap_net_raw+ep' $(command -v nethogs)
```

The monitor only runs while the popout is open (zero idle cost), shows the top
programs by current rate, and persists nothing.

## 🛠️ How It Works

The plugin reads Linux's built-in network statistics.

| What | Source | Purpose |
|------|--------|---------|
| Byte counters | `/proc/net/dev` | Calculates per-interface upload/download deltas each poll |
| Link state | `/sys/class/net/*/operstate` | Detects online/offline instantly |
| WiFi network name | `iwgetid` (or `nmcli` fallback), optional | Names per-network usage buckets; falls back to the interface name if neither is available |
| Per-app rates | `nethogs -t`, optional | Live per-application traffic while the popout is open |
| Persistence | DMS Plugin State API | Saves daily per-interface usage across reboots (30-day rolling window) |

Every active interface is tracked and the bar shows the sum, ignoring loopback and
virtual interfaces (docker, veth, etc.) unless a group pattern or an explicit
**Tracked Interfaces** entry names them. Usage history is stored per interface and
per WiFi network, so both group chips and network chips can slice the same 30 days.

## 📄 License

MIT
