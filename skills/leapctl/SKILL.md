---
name: leapctl
description: Manage a Lutron Caséta or RA2 Select lighting system with the lutron_* tools - what remote buttons and Picos do, schedules, rooms and names, adding or removing devices, backups and undo. Use when the user asks about or wants to change their Lutron setup.
---

# Working with a Lutron system through leapctl

The `lutron_*` tools talk to the user's Lutron bridge on their network. Reading is safe; changes
affect a real house.

## Rules

1. **Look before changing.** Use `lutron_programming`, `lutron_schedules` or `lutron_zones` to show
   the current state, then describe the exact change.
2. **Get the user's OK for every change**, then call the tool with `confirm: true`. Each change saves
   a backup first; mention that `lutron_diff` shows what changed and `lutron_restore` undoes it.
3. **Adding or moving a device: ask about the AutoProgrammer first.** Lutron's AutoProgrammer gives
   new remotes default actions and re-copies room templates onto other remotes. Ask: "Should Lutron's
   AutoProgrammer assign functions, or should the new device start with no Lutron actions?" Pass
   `auto_program: true` or `false`. Never choose for the user.
4. **Pairing needs the user at the device.** Before `lutron_pair`, tell them: "When I start, press and
   hold the device's button (bottom button on a Pico) for about 10 seconds, until its light flashes
   rapidly." The tool listens for 3 minutes by default.
5. **Don't operate lights or press buttons** (`lutron_level`, `lutron_fan`, `lutron_press`) unless the
   user asked for it. A button press runs that button's Lutron programming.

## How remotes are programmed

* **3-button raise/lower Picos** have one list of lights for all five buttons. Pass the Pico's name
  as the target to add or remove a light; you can't change a single button.
* **Engraved scene Picos** (Kitchen, Bedside, Home/Away, Relax...) follow per-room templates, and
  remotes with the same engraving in one room share them. `lutron_assign` and `lutron_unassign` on a
  button also update its template and every remote sharing it; say so to the user. If a result
  includes a WARNING about an unclear template, tell the user the AutoProgrammer may undo that change.
* **Custom-engraved remotes** are programmed button by button (targets look like `/button/123`).
* **Schedules and scenes** take lights like buttons: target a schedule by name.
* Making a button do nothing in Lutron (for example, because Home Assistant handles its presses):
  `lutron_clear_button`. The press still reaches Home Assistant and other integrations.

## Useful starting points

* "What does this remote do?" → `lutron_programming` with the remote's name.
* "Which buttons control the porch light?" → `lutron_programming` (all remotes) and
  `lutron_schedules`, then search the output for the light.
* "Is everything healthy?" → `lutron_doctor`. It reports devices that aren't receiving their settings
  and buttons that have drifted from their templates.
* "Undo that." → `lutron_diff`, then `lutron_restore` (with the user's OK).
