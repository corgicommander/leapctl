# leapctl

**See and change everything your Lutron Caséta / RA2 Select system does, from the command line or from
Claude**: what every remote button does, schedules, rooms and names, adding and removing devices.
Backups are automatic and every change can be undone.

leapctl talks to your bridge directly over **LEAP**, the local protocol the Lutron app uses. Nothing goes
through the cloud. It is unofficial and not affiliated with Lutron Electronics; use it at your own risk.

## Why

The Lutron app hides a lot. Two examples that this tool was built to fix:

* **Hidden button actions.** When you add a remote, Lutron's *AutoProgrammer* quietly gives its buttons
  default actions, and later *re-copies* them from per-room templates, undoing your edits. If you
  trigger your remotes from Home Assistant, you may not notice until someone asks why a light is on.
  `leapctl programming` shows what every button does, and `leapctl pair --no-auto-program` adds a
  remote with no Lutron actions at all.
* **No overview, no undo.** The app has no list of everything, no export and no undo. leapctl takes
  a backup before every change, can `diff` any two states, and can `restore` a backup.

## What it can do

| Area | Commands | Tested on real hardware |
|---|---|---|
| Overview and health | `doctor`, `devices`, `rooms`, `zones`, `programming`, `schedules` | yes |
| Control | `level`, `fan`, `press` | yes |
| Remote programming | `assign`, `unassign`, `clear-button` (any remote type, including templates) | yes |
| Names and rooms | `rename-device`, `rename-zone`, `rename-room`, `room-add`, `room-delete`, `move-device` | yes |
| Schedules | `schedule-add`, `-time`, `-days`, `-rename`, `-enable`, `-disable`, `-delete` | yes |
| Adding and removing devices | `pair`, `remove-device` | yes (Pico remote) |
| Safety | `backup`, `backups`, `diff`, `restore` | yes |
| Dimmer trim | `trim` | read and no-op write only |

Tested with an **RA2 Select main repeater** (LEAP 01.124). Caséta Smart Bridge (Pro) uses the same
protocol and should work, but it hasn't been tested yet. Reports are welcome. RadioRA 3, HomeWorks QSX
and Athena use different programming and pairing flows; read-only commands may work there, changes
probably won't.

## Install

You need Ruby 2.6 or newer (macOS includes it; on Linux, `apt install ruby` or similar). There are no
gems to install.

```bash
git clone https://github.com/corgicommander/leapctl.git
cd leapctl
bin/leapctl help
```

Add `bin/` to your PATH, or symlink `bin/leapctl` somewhere on it.

## Connect to your bridge

LEAP uses a client certificate that the bridge signs once, after you press its button. If you already
have one, reuse it.

**Home Assistant users** already have one: the Lutron Caséta integration stores it in Home Assistant's
config folder. Copy or mount that folder, then:

```bash
leapctl setup --from-home-assistant=/path/to/homeassistant/config
```

**Everyone else** can create one with [pylutron-caseta](https://github.com/gurumitts/pylutron-caseta)
(the library behind Home Assistant's integration). Run `pip install 'pylutron-caseta[cli]'`, then
`lap-pair <bridge-ip>`, and press the button on the back of the bridge when asked. Then:

```bash
leapctl setup --from-pylutron
```

Or give the paths yourself: `leapctl setup --host=192.168.1.20 --cert=client.crt --key=client.key`.
The settings go to `~/.config/leapctl/config.json` (paths only). Environment variables `LEAP_HOST`,
`LEAP_CERT`, `LEAP_KEY` and `LEAP_BACKUP_DIR` override it. `setup` finishes by running `doctor`:

```text
bridge 192.168.1.20: Lutron RA2 Select Project, LEAP 01.124
session role: Admin
38 devices, 27 zones, 12 rooms, 2 schedules
pairing mode: off
WARN Basement / Wireless Repeater: settings not delivered (14 failed attempts); check power and range
AutoProgrammer: Enabled
done, with warnings
```

## Quick start

```bash
leapctl programming                      # what every remote button does
leapctl programming "Kitchen / Keypad"   # one remote
leapctl schedules                        # Lutron's own schedules
leapctl level "Kitchen / Main Lights" 60
```

Names can be the full "Room / Device" label, the device name alone, a unique fragment, or an href
such as `/zone/12`.

## Making changes safely

Every command that changes the system:

1. needs `--yes`;
2. saves a full backup first (`~/.local/share/leapctl/backups`, or `--backup-dir`);
3. can be undone: `leapctl diff` shows what changed since the latest backup, and `leapctl restore --yes`
   puts programming back to the backup taken before the latest command.

```bash
leapctl assign "Pico 1" "Family Room / Floor Lamp" --yes   # a 3-button raise/lower Pico: all buttons
leapctl assign /button/139 "Kitchen / Sink" 50 --yes       # one button, level 50%
leapctl unassign all "Den / Grow Light" --yes             # off every remote, schedule and scene
leapctl clear-button /button/150 --yes                    # no Lutron action; the press still reaches Home Assistant
leapctl schedule-add "Porch" daily sunset-15 --yes
leapctl assign "Porch" "Exterior / Porch Lights" --yes
```

### Adding a remote or device

```bash
leapctl pair "Office" --name="Desk Pico" --no-auto-program --yes
```

Then press and hold the device's button until its light flashes rapidly (for a Pico, the bottom
button for about 10 seconds). Before pairing, decide whether Lutron's **AutoProgrammer** may assign
functions:

* `--auto-program` keeps whatever Lutron assigns, and reports what it also changed elsewhere;
* `--no-auto-program` clears the new device's programming and any new templates, and restores every
  other remote to how it was.

`move-device` asks the same question, because moving a device to another room also runs the
AutoProgrammer.

## Use with Claude

leapctl includes an MCP server (`leapctl mcp`) that gives Claude a `lutron_*` tool for every command.
Changes need the user's OK (`confirm: true`), and Claude is told to ask the AutoProgrammer question
before pairing or moving devices.

**Claude Code plugin** (MCP server + a skill with the safety rules):

```bash
claude plugin marketplace add corgicommander/leapctl
claude plugin install leapctl@leapctl
```

Run `leapctl setup` once first and the plugin needs no settings. Or give it the bridge address,
certificate and key directly (`claude plugin configure leapctl` shows what is set):

```bash
echo '{"host":"192.168.1.20","cert":"/path/to/client.crt","key":"/path/to/client.key"}' | claude plugin configure leapctl --values-stdin
```

**Claude Desktop**: add this to `claude_desktop_config.json` and restart Claude Desktop:

```json
{
  "mcpServers": {
    "leapctl": { "command": "ruby", "args": ["/path/to/leapctl/bin/leapctl", "mcp"] }
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

## Not supported

* Firmware updates, and cloud services (Alexa, Google Home, IFTTT, the Lutron account): use the app.
* Turning the AutoProgrammer off: the bridge refuses (`/service/autoprog` doesn't accept updates).
* Shades, occupancy sensors and Smart Away are read-only so far: they appear in backups, but no
  commands change them.

## Development

```bash
ruby test/test_leapctl.rb     # offline tests against a simulated bridge (test/fake_bridge.rb)
```

The code is in `lib/leapctl/`: `client.rb` (the model and all operations), `commands.rb` (one
definition per command, shared by the CLI and the MCP server), `cli.rb`, `mcp.rb`, `transport.rb`
and `config.rb`.

## License

MIT, see [LICENSE](LICENSE). Pairing certificates come from
[pylutron-caseta](https://github.com/gurumitts/pylutron-caseta), whose authors first documented much of
LEAP. Lutron, Caséta, RadioRA and Pico are trademarks of Lutron Electronics Co., Inc.
