# leapctl

> Written with [Claude Code](https://claude.com/claude-code), and tested command by command on a real
> RA2 Select system (see [What it can do](#what-it-can-do)).

**A Lutron companion for Home Assistant.** Home Assistant's Lutron Caséta integration lets you use your
lights and Pico remotes, but it can't change Lutron's own programming: what a Pico button does by
itself, Lutron's schedules, rooms and names, or adding a device. leapctl does that, from the command
line or from Claude Code, with the certificate Home Assistant already has. Together with Home
Assistant, Claude Code can then look after both sides: your automations, and what the Lutron system
does on its own.

leapctl talks to the Lutron bridge directly over **LEAP**, the local protocol Home Assistant's
integration uses. Nothing goes through the cloud. It is unofficial and not affiliated with Lutron
Electronics; use it at your own risk.

## Why

* **Hidden button actions.** When you add a remote, Lutron's *AutoProgrammer* automatically gives its
  buttons actions, and later re-copies them from per-room templates, undoing your edits. If Home
  Assistant automations handle your Pico presses, a press can then do two things at once.
  `leapctl programming` shows what every button does in Lutron, `leapctl clear-button` removes Lutron's
  action (the press still reaches Home Assistant), and `leapctl pair --no-auto-program` adds a remote
  and undoes what the AutoProgrammer assigned.
* **No overview, no backup.** The Lutron app has no overview of every button and no export of the
  programming. leapctl takes a backup before every change; `diff` compares the system with a backup,
  and `restore` puts back which lights each button, template, scene and schedule controls.

## What it can do

| Area | Commands | Tested on real hardware |
|---|---|---|
| Overview and health | `doctor`, `devices`, `rooms`, `zones`, `programming`, `schedules` | yes |
| Control | `level`, `fan`, `press` | yes |
| Remote programming | `assign`, `unassign`, `clear-button` | yes: 3-button raise/lower, 2-button and engraved 4-button scene Picos, with their templates |
| Names and rooms | `rename-device`, `rename-zone`, `rename-room`, `room-add`, `room-delete`, `move-device` | yes |
| Lutron schedules | `schedule-add`, `-time`, `-days`, `-rename`, `-enable`, `-disable`, `-delete` | yes |
| Adding and removing devices | `pair`, `remove-device` | yes, with Picos |
| Safety | `backup`, `backups`, `diff`, `restore` | yes |
| Dimmer trim | `trim` | read and no-op write only |

Tested on one **RA2 Select main repeater** (LEAP 01.124) with Picos. On a **Caséta Smart Hub** (or PRO)
the read commands should work; changes and pairing haven't been tested there yet. Reports are welcome:
please share the summary lines of `leapctl doctor`, not your device names. Wall keypads, the 4-button
L31 Pico and other remotes are untested. RadioRA 3, HomeWorks QSX and Athena work differently;
read-only commands may work there, changes probably won't.

## What you need

* **Home Assistant with the Lutron Caséta integration** set up for your bridge. leapctl reuses its
  client certificate, and Home Assistant stays connected while leapctl works.
* **Access to Home Assistant's config folder** from the computer that runs leapctl. On Home Assistant
  OS, the Samba share app makes it a network folder: on a Mac, Finder > Go > Connect to Server,
  `smb://homeassistant.local/config`, which appears as `/Volumes/config`. leapctl reads the certificate
  from there every time, so keep the share mounted (for example as a Login Item).
* **Ruby 2.6 or newer.** macOS still includes it (`/usr/bin/ruby`); on Linux, `apt install ruby` or
  similar. There are no gems to install.
* **A network path to the bridge** (TCP port 8081) from that computer.
* For Claude: **Claude Code** with the plugin below. The command line works without it.

Without Home Assistant, see [below](#without-home-assistant).

## Install

**Claude Code** (2.1.292 or later for this one line; inside Claude Code,
`/plugin install leapctl --marketplace corgicommander/leapctl` works from 2.1.275):

```bash
claude plugin install leapctl --marketplace corgicommander/leapctl
```

Then ask Claude to "set up leapctl": it asks for Home Assistant's config folder and runs setup for you.
On older versions: `claude plugin marketplace add corgicommander/leapctl`, then
`claude plugin install leapctl@leapctl`. The plugin needs Claude Code (or Cowork on a computer that can
reach the bridge); claude.ai chat doesn't run its tools.

**Command line**, no git needed (into your home folder, and onto your PATH):

```bash
cd ~ && curl -fsSL https://github.com/corgicommander/leapctl/releases/latest/download/leapctl.tar.gz | tar xz
echo 'export PATH="$HOME/leapctl/exe:$PATH"' >> ~/.zshrc && source ~/.zshrc
leapctl help
```

Or `git clone https://github.com/corgicommander/leapctl.git` and add its `exe` folder to your PATH the
same way. On Linux, use `~/.bashrc` instead of `~/.zshrc`.

## Connect to your bridge

```bash
leapctl setup --from-home-assistant=/Volumes/config
```

`setup` reads the Lutron Caséta integration's certificate files in that folder, and the bridge's
address from Home Assistant's `.storage/core.config_entries` (only the Lutron entry; leapctl ignores
the other integrations' settings in that file). It checks the files, connects once, and only then
saves the settings to `~/.config/leapctl/config.json` (paths only, never the key itself). It also
saves the path of the bridge's CA file, so leapctl checks that it is talking to your bridge. If it
can't find the address, add `--host=<bridge IP>`. Then it runs `doctor`:

```text
bridge 192.168.1.20: Lutron RA2 Select Project, LEAP 01.124
bridge certificate: checked against lutron_caseta-192.168.1.20-ca.pem
session role: Admin
38 devices, 27 zones, 12 rooms, 2 schedules
pairing mode: off
WARN Basement / Wireless Repeater: settings not delivered (14 failed attempts); check power and range
AutoProgrammer: Enabled
done, with warnings
```

Environment variables `LEAP_HOST`, `LEAP_CERT`, `LEAP_KEY`, `LEAP_CA` and `LEAP_BACKUP_DIR` override
the saved settings (`setup` says so when one is set).

### Without Home Assistant

leapctl doesn't need Home Assistant to run, only a LEAP client certificate signed by your bridge.
[pylutron-caseta](https://github.com/gurumitts/pylutron-caseta)'s `lap-pair` makes one. It needs Python
3.10 or newer: run `pipx install 'pylutron-caseta[cli]'`, then `lap-pair <bridge IP>`, and press the
button on the back of the bridge when asked. Then run `leapctl setup --from-pylutron`, or give any
certificate and key with `leapctl setup --host=<bridge IP> --cert=<file> --key=<file>` (plus
`--ca=<file>` with the bridge's CA, if you have it).

## Quick start

```bash
leapctl programming                      # what every remote button does in Lutron
leapctl programming "Kitchen / Pico"     # one remote
leapctl schedules                        # Lutron's own schedules
leapctl level "Kitchen / Main Lights" 60
```

Names can be the full "Room / Device" label, the device name alone, a unique fragment, or an href
such as `/zone/12`. `leapctl help` lists every command, and `leapctl <command> --help` explains one.

## Making changes safely

Every command that changes the system needs `--yes` and saves a backup first
(`~/.local/share/leapctl/backups`, or `--backup-dir`); a change refused before it sent anything
leaves none. `leapctl diff` compares the system with the latest backup, and `leapctl restore --yes`
goes back to the backup taken before the latest change. Both use only backups of the bridge you're
connected to, and cover which lights (with level, fade and delay) each existing button, template,
scene and schedule controls. They don't cover names, rooms, moves, schedule times, days or on/off,
trim, or anything added or deleted since the backup: undo those with the matching command.

```bash
leapctl assign "Pico 1" "Family Room / Floor Lamp" --yes   # a 3-button raise/lower Pico: all buttons
leapctl assign /button/139 "Kitchen / Sink" 50 --yes       # one button, level 50%
leapctl unassign all "Den / Grow Light" --yes             # off every remote, schedule and scene
leapctl clear-button /button/150 --yes                    # no Lutron action (engraved Picos: also their template); the press still reaches Home Assistant
leapctl schedule-add "Porch" daily sunset-15 --yes
leapctl assign "Porch" "Exterior / Porch Lights" --yes
```

### Adding a remote or device

```bash
leapctl pair "Office" --name="Desk Pico" --no-auto-program --yes
```

Then press and hold the device's button until its light flashes rapidly (for a Pico, the bottom
button for about 10 seconds). Lutron's **AutoProgrammer** always runs after a device is added, so
decide first whether to keep what it assigns:

* `--auto-program` keeps it, and reports what it also changed on other remotes;
* `--no-auto-program` waits 30 seconds for it, then clears the new device's programming and any new
  templates, and puts every other remote back the way it was.

`move-device` asks the same question, because moving a device to another room also runs the
AutoProgrammer. `pair` has been tested with Picos; for dimmers, switches, shades and sensors, keep the
Lutron app as the fallback.

## With Home Assistant

Home Assistant's Lutron Caséta integration sees button presses and light levels live, but reads
devices, names and rooms only when it starts or is reloaded (Settings > Devices & services > Lutron
Caséta > ⋮ > Reload). leapctl prints what Home Assistant needs after each change:

* **New device** (`pair`): reload. It appears in the HA area named like its Lutron room. Give it its
  final name and room when pairing: Home Assistant creates the entity IDs from them the first time it
  sees the device.
* **Removed device** (`remove-device`): reload, then delete the device in Home Assistant (it refuses
  before the reload).
* **Renamed device or room, moved device**: reload to show the new names. Entity IDs and HA areas stay
  as they are. Home Assistant shows only the part of a device name after its last `_`.
* **Button programming and Lutron schedules**: nothing to do. Presses still reach Home Assistant.
* **Renamed light** (`rename-zone`): no effect in Home Assistant, which names Caséta and RA2 Select
  lights after their device.

A reload makes the Lutron entities unavailable for a moment, so automations that trigger on state
changes should ignore `unavailable` (`not_from: [unavailable, unknown]`). For Pico automations,
device triggers keep working after renames; event triggers that filter on `device_name` or
`area_name` don't.

leapctl handles the Lutron side only. For Claude Code to manage Home Assistant itself (automations,
reloads, removing old devices), give it a Home Assistant connection too, for example Home Assistant's
built-in [MCP Server](https://www.home-assistant.io/integrations/mcp_server/) integration or the
community [ha-mcp](https://github.com/homeassistant-ai/ha-mcp) server. Neither is affiliated with
leapctl.

## Use with Claude Code

The plugin runs leapctl's MCP server, which gives Claude a `lutron_*` tool for every command, plus a
skill with the safety rules. Claude asks you before every change, and Claude Code then shows its own
approval prompt for each one (also for setup), even in auto mode: that prompt is the safeguard, and
it can't be switched to "always allow". Claude asks the AutoProgrammer question before pairing or
moving a device, and knows how Lutron programs each kind of Pico. Things to ask:

* "Set up leapctl from my Home Assistant config folder."
* "What does the Kitchen Pico do in Lutron?"
* "Make the bottom button of the Bedside Pico do nothing in Lutron; Home Assistant handles it."
* "Add a new Pico to the Office without any Lutron actions."

The plugin and the command line share one set of settings (`~/.config/leapctl/config.json`). To
change the bridge or certificate later, ask Claude to set up leapctl again, or run `leapctl setup`.

**Claude Desktop** (chat): run `leapctl setup` first, then add this to `claude_desktop_config.json`
and restart Claude Desktop:

```json
{
  "mcpServers": {
    "leapctl": { "command": "/usr/bin/ruby", "args": ["/path/to/leapctl/exe/leapctl", "mcp"] }
  }
}
```

## How Lutron programming works

Read this before editing remotes by hand. More detail, with the raw requests, is in
[docs/leap-notes.md](docs/leap-notes.md).

* **3-button raise/lower Picos** ("Column" programming) have one list of lights for the whole remote:
  On, Favorite, Off, Raise and Lower all act on it. You can't edit a single button.
* **Engraved scene Picos** (Kitchen, Bedside, Home/Away, Relax/Entertain…) follow **templates** that
  belong to their room and engraving. Two remotes with the same engraving in one room share them. The
  AutoProgrammer re-copies templates onto the buttons, so leapctl edits the button, its template and
  every remote sharing it together. `doctor` warns about any button that has drifted from its template.
* **Custom-engraved and 2-button Picos without an engraving** are programmed button by button.
* **Schedules and scenes** are programmed the same way as buttons.

## Limits

* Turning the AutoProgrammer off: the bridge refuses (`/service/autoprog` doesn't accept updates).
* `programming` shows Lutron's preset assignments. Fan, shade and audio Picos may keep their actions in
  other lists that it doesn't show yet.
* Shades, occupancy sensors and Smart Away are read-only so far: they appear in backups, but no
  commands change them.
* Firmware updates, and cloud services (Alexa, Google Home, IFTTT, the Lutron account): use the app.

## What it runs, sends and stores

* **Runs:** one Ruby program (`exe/leapctl`) that uses only Ruby's standard library. It downloads and
  installs nothing and starts no other programs. The Claude Code plugin starts the same program as an
  MCP server (`ruby exe/leapctl mcp`); it doesn't change Claude's settings or permissions.
* **Reads:** the certificate, key and CA files you give it; at setup, in Home Assistant's config
  folder, the Lutron entry of `.storage/core.config_entries` (for the bridge's address); and its own
  backups (`diff` and `restore` accept nothing else).
* **Sends:** one TLS connection to the bridge address you configure (port 8081), with your client
  certificate; `pair` opens a second one to listen for new devices. When Home Assistant knows the
  bridge only by Lutron's ID for it, `setup` also looks up `lutron-<id>.local` on your network.
  Nothing else: no cloud, no telemetry, no update checks.
* **Stores:** its settings in `~/.config/leapctl/config.json` (file paths, never the key itself), and a
  backup before every change in `~/.local/share/leapctl/backups` (plus one copy without the time at
  `LEAP_SNAPSHOT`, if you set it, so a copy kept in git changes only with the programming). It makes
  both readable by you only. Backups hold what the bridge reports (rooms, devices and their serial
  numbers, button programming, schedules), not your certificate, key or network keys.

## Development

```bash
ruby test/test_leapctl.rb     # offline tests against a simulated bridge (test/fake_bridge.rb)
```

A release attaches `leapctl.tar.gz`, made with `git archive --format=tar.gz --prefix=leapctl/ -o
leapctl.tar.gz v<version>` (the install line above unpacks it into `leapctl/`).

The code is in `lib/leapctl/`: `client.rb` (the model and all operations), `commands.rb` (one
definition per command, shared by the CLI and the MCP server), `setup.rb`, `cli.rb`, `mcp.rb`,
`transport.rb` and `config.rb`.

## License and credits

MIT, see [LICENSE](LICENSE). Home Assistant's certificate comes from the pairing code of
[pylutron-caseta](https://github.com/gurumitts/pylutron-caseta), the library behind its Lutron
integration, whose authors first documented much of LEAP. Thanks also to the add-device script in
[pylutron-caseta issue #77](https://github.com/gurumitts/pylutron-caseta/issues/77) and to
[alxgmpr's LEAP reference](https://github.com/alxgmpr/leap-api). Related projects:
[lutron-cli](https://github.com/omarshahine/lutron-cli) (control, renames and rooms, with a Claude
Code plugin) and [tron](https://github.com/tessro/tron) (a command-line tool for Caséta).

Lutron, Caséta, RadioRA and Pico are trademarks of Lutron Electronics Co., Inc.
