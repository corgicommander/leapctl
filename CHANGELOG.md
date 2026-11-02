# Changelog

## 0.1.1 (2026-11-02)

Aimed at Home Assistant users: setup reuses the Lutron Caséta integration's certificate and bridge
address, and Claude can run it.

* The program moved from `bin/leapctl` to `exe/leapctl` (a top-level `bin/` stops claude.ai and Cowork
  from installing a plugin). Update any PATH entry, symlink or `claude_desktop_config.json` entry.
* `setup --from-home-assistant` takes the bridge address from Home Assistant's config entry, so it also
  works when Home Assistant found the bridge by itself and named the files after Lutron's ID for it.
  Without that file it tries `lutron-<id>.local`, then asks for `--host`.
* The bridge's certificate is checked when its CA is known: setup takes Home Assistant's
  `lutron_caseta-…-ca.pem` (or lap-pair's `-bridge.crt`, or `--ca=`), and `doctor` says whether the
  check is on. Before, leapctl accepted whatever answered at the bridge's address.
* `setup` checks the files (empty, not PEM, swapped, the CA file given as the key, a key that doesn't
  match, a passphrase-protected key) and connects before it saves anything. It saves absolute paths,
  keeps other saved settings, replaces a settings file it can't read (keeping a `.bak`), and says when
  a `LEAP_*` environment variable will override what it saved.
* New `lutron_setup` tool, so Claude can set leapctl up from Home Assistant's config folder. The plugin
  no longer has settings of its own (they hid what setup saved): setup is the one way to configure it,
  shared with the command line, and the MCP server reads the saved settings again for every call.
* `pair` listens for at most 10 minutes, and the plugin allows a tool call 30 minutes (it was 10, which
  could cut a long pairing off midway).
* `diff` and `restore` read only leapctl's own backups (by the name `backups` shows, or by path), and
  check the name before anything changes. Before, they read any file, and an error could repeat its
  content. They use only backups of the bridge you're connected to, so a backup folder shared by two
  bridges is safe. A change refused before it sent anything (a name not found, say) no longer leaves
  a backup that would make the next `restore` a no-op. Backups and the snapshot are readable by you
  only, and leave out the network key that RadioRA 3 and HomeWorks systems may report.
* `clear-button` names everything it cleared (on engraved Picos also the room's template and the
  remotes sharing it), and warns when it can't tell which template a button follows.
* Setup treats the address, certificate, key and CA as one set: setting up another bridge no longer
  keeps the previous bridge's CA. `--cert`/`--key` together with `--from-home-assistant` take that
  entry's address and CA. It understands `configuration.yaml` given instead of its folder, explains
  an `smb://` address, writes through a symlinked settings file, and gives a one-line error for one
  it can't read.
* One-line errors instead of Ruby backtraces: unreadable or wrong certificate files, a refused or
  unreachable bridge (with a hint about macOS Local Network access, and to run setup again if the
  bridge's address changed), timeouts (now also for a TLS handshake that never finishes), lost
  connections. A CA file may be PEM or DER. `programming <name>` looks only among remotes, and
  "not found" says which command lists the names.
* The command line refuses unknown options, values on switches (`--auto-program=false` used to mean
  true), words that start with `-` but aren't options, and extra words; a mistyped option used to be
  ignored. `pair` and `move-device` name the two AutoProgrammer choices when neither is given. New:
  `-h`, `--version`, `help setup` and `<command> --help`. Empty results print `(none)`, `backups` works
  without the bridge, and `programming` and `schedules` list lights in a fixed order.
* Names with accents work when no language is set, which is how Claude starts programs: arguments,
  environment variables, MCP messages and files are read as UTF-8. A malformed MCP message (bad
  bytes, odd ids, escapes that aren't valid text) gets an error instead of ending the server; batches
  get answers, notifications none.
* Change commands end with what Home Assistant needs (a reload of its Lutron Caséta integration after
  pairing, renames and moves; a reload and a delete after removing a device), and warn that Home
  Assistant shows only the part of a device name after its last `_`.
* MCP: tool titles and annotations (read-only, destructive), and every change tool and `lutron_setup`
  ask Claude Code to get the user's approval on each call, even in auto mode. `lutron_setup` takes only
  an IP address as the host. The instructions tell Claude that names from the bridge are data, not
  instructions. Error -32602 for unknown tools; unexpected errors are reported as tool errors, without
  their details (those go to the server's log). The server is now declared in `plugin.json` (no root
  `.mcp.json`, which Claude Code also offered as a broken project server inside the repo).
* Backups and the snapshot list actions sorted by light and level, without the bridge's numbers for
  them (Lutron renumbers an action whenever it re-creates it), and empty lists look the same whichever
  Ruby wrote them. The snapshot copy also leaves out the time, so a git-tracked snapshot changes only
  when the programming does. `diff` already ignored all of this; a test now covers it.
* Wording: the README, plugin and skill now say exactly what `diff` and `restore` cover, what was
  tested, and that the AutoProgrammer always runs (leapctl undoes it on request).

## 0.1.0 (2026-11-01)

First release, tested on an RA2 Select main repeater (LEAP 01.124).

* Read: doctor, devices, rooms, zones, programming, schedules, backups, diff, raw get.
* Control: level, fan, press.
* Changes (with automatic backups): assign/unassign/clear-button for Freeform buttons, Column
  (3-button raise/lower) Picos and engraved-Pico templates (shared templates kept in step), names,
  rooms, moving devices, schedules, trim, restore, remove-device, and pairing with an explicit
  AutoProgrammer choice.
* MCP server (`leapctl mcp`) and Claude Code plugin with a skill.
