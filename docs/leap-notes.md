# LEAP notes: RA2 Select programming, schedules and pairing

What leapctl relies on, as observed on an RA2 Select main repeater (LEAP `01.124`, product type
"Lutron RA2 Select Project") with Home Assistant's client certificate (made by pylutron-caseta's pairing
code, the same as `lap-pair`; session role `Admin`). Caséta bridges share most of this. Status codes and error texts are quoted exactly. Corrections and reports
from other hardware are welcome.

## Transport

* TLS on port 8081 with a client certificate; the bridge's certificate is self-signed.
* One JSON object per line, ending in `\r\n`:
  `{"CommuniqueType":"ReadRequest","Header":{"Url":"/device","ClientTag":"c1"}}`.
* Verbs: `ReadRequest`, `CreateRequest`, `UpdateRequest`, `DeleteRequest`, `SubscribeRequest`.
  Answers carry `Header.StatusCode` (`200 OK`, `201 Created`, `204 NoContent`, `400 BadRequest`,
  `404 NotFound`, `405 MethodNotAllowed`, `500 InternalServerError`) and echo `ClientTag`.
* The bridge also sends unsolicited messages (subscriptions, zone level changes), so match answers on
  `ClientTag`.
* Validation errors name the missing field, which makes the API discoverable:
  `"The body is missing a required property : InAssociationMode"`.
* `ReadRequest /clientsetting` shows the session's permissions: `{"Permissions":{"SessionRole":"Admin"}}`.

## The programming model

```
/device/N ─ ButtonGroups ─ /buttongroup/N ─ Buttons ─ /button/N ─ ProgrammingModel ─ /programmingmodel/N
     └─ Preset (or Presets, PressPreset/ReleasePreset, ...) ─ /preset/N ─ /preset/N/presetassignment
```

A preset assignment is `{"AffectedZone":{"href":"/zone/3"},"Level":100,"Fade":2,"Delay":0}` (Fade and
Delay in whole seconds). Programming model types seen: `SingleActionProgrammingModel` (buttons,
schedules, scenes), `SingleSceneRaiseProgrammingModel` / `SingleSceneLowerProgrammingModel`
(raise/lower), `DualActionProgrammingModel` (occupancy groups, with `DualActionProperties`).

### Freeform buttons (4-button and 2-button Picos)

| Action | Request | Result |
|---|---|---|
| add a light | `CreateRequest /preset/N/presetassignment` `{"PresetAssignment":{"AffectedZone":{"href":"/zone/8"},"Level":0,"Fade":2,"Delay":0}}` | `201 Created` |
| change the level | `UpdateRequest /presetassignment/N` `{"PresetAssignment":{"Level":1}}` | `200 OK` |
| remove a light | `DeleteRequest /presetassignment/N` | `204 NoContent` |

### Column button groups (3-button raise/lower Picos)

`/buttongroup/N` has `"ProgrammingType":"Column"` and a list of affected zones; Lutron derives every
button (On 100 %, Favorite 50 %, Off 0 %, Raise, Lower) from it.

| Action | Request | Result |
|---|---|---|
| list | `ReadRequest /buttongroup/8/affectedzone` | `200 OK` |
| add a light | `CreateRequest /buttongroup/8/affectedzone` `{"AffectedZone":{"Zone":{"href":"/zone/42"}}}` | `201 Created`, href `/buttongroup/8/affectedzone/42` |
| remove a light | `DeleteRequest /buttongroup/8/affectedzone/42` | `204 NoContent`, all five buttons updated |
| delete one button's assignment | `DeleteRequest /presetassignment/N` | `500` `{"Message":"An unknown error occurred","ErrorCode":5}` |

### Templates of engraved Picos

`ReadRequest /virtualbutton` returns scenes (`/virtualbutton/N`, with names such as "Arriving Home")
and templates (`/vbutton/N`):

```json
{"href":"/vbutton/15","ButtonNumber":2,"ProgrammingModel":{"href":"/programmingmodel/217"},
 "Parent":{"href":"/area/23"},"IsProgrammed":true,"Category":{"Type":"HomeAway","SubType":"Away"}}
```

* A template belongs to a room (`Parent`), an engraving (`Category.Type`, the device's
  `EngravingKit`: AnyRoomRelax, Kitchen, Bedside, HomeAway, ...) and a `ButtonNumber`. A button of an
  engraved Pico follows the template with its room, engraving and `ButtonNumber`. This was checked on
  18 of 18 buttons. Two remotes with the same engraving in the same room share templates.
* Editing a template's assignments changes every button that follows it immediately.
* Editing a button directly does **not** change its template. The next time the AutoProgrammer runs,
  the template is copied back onto the button and the edit disappears.
* `Custom` engravings and Picos without an `EngravingKit` have no templates.

### The AutoProgrammer

`ReadRequest /service` lists `{"href":"/service/autoprog","Type":"AutoProgrammer","AutoProgrammerProperties":{"EnabledState":"Enabled"}}`.
`UpdateRequest /service/autoprog` returns `405 MethodNotAllowed`, so it can't be switched off over LEAP.
It ran in two situations:

* **Moving a device to another room** (`UpdateRequest /device/N` with a new `AssociatedArea`, even when
  moved back): it added the moved light to whole-room templates (Bedside GoodNight and Alert), then copied
  templates onto all engraved Picos. That undid earlier direct button edits.
* **Adding an engraved Pico**: it created four new templates for the room (Kitchen engraving: Off,
  Dining, Cooking, Bright), each with the room's lights. The new Pico's buttons were empty at first.

Turning association mode on and off, renaming, creating and deleting rooms, and editing schedules did
not trigger it.

## Schedules (timeclock)

| Action | Request |
|---|---|
| list | `ReadRequest /timeclockevent`; enable states: `ReadRequest /timeclockevent/status` |
| create | `CreateRequest /timeclock/1/timeclockevent` (`CreateRequest /timeclockevent` returns `405`) |
| change | `UpdateRequest /timeclockevent/N` with any of the fields below |
| enable/disable | `UpdateRequest /timeclockevent/N/status` `{"TimeclockEventStatus":{"EnableState":"Disabled"}}` |
| delete | `DeleteRequest /timeclockevent/N` (`204`) |

```json
{"TimeclockEvent":{"Name":"Porch Lights On","ScheduleType":"DayOfWeek",
  "Sunday":true,"Monday":true,"Tuesday":true,"Wednesday":true,"Thursday":true,"Friday":true,"Saturday":true,
  "TimeclockEventType":"Astronomic","AstronomicEventType":"Sunset","AstronomicTimeOffset":"-30:00"}}
```

Fixed times use `"TimeclockEventType":"FixedTime","TimeOfDay":{"Hour":6,"Minute":0}`. The offset is
minutes:seconds (`"-30:00"` means 30 minutes before; `"0"` means no offset). A create needs at least one day:
`"Must specify at least one day of the week for a DayOfWeek event."`. Each event gets its own
programming model and preset, and lights are added to it like to a button.

## Rooms, names, devices

| Action | Request | Result |
|---|---|---|
| create a room | `CreateRequest /area` `{"Area":{"Name":"Office","Parent":{"href":"/area/1"}}}` | `201` (also creates an occupancy group) |
| rename a room / device / zone | `UpdateRequest /area/N` `{"Area":{"Name":"..."}}`, likewise `Device`, `Zone` | `200` |
| delete a room | `DeleteRequest /area/N` | `204` |
| move a device | `UpdateRequest /device/N` `{"Device":{"AssociatedArea":{"href":"/area/M"}}}` | `200`; runs the AutoProgrammer |
| remove a device | `DeleteRequest /device/N` | `204` |

`CreateRequest /area/1/childarea` returns `400`. A device and its zone have separate names; the app shows
the device name.

## Control

* Level: `CreateRequest /zone/N/commandprocessor` `{"Command":{"CommandType":"GoToLevel","Parameter":[{"Type":"Level","Value":60}]}}`
* Fan: `{"Command":{"CommandType":"GoToFanSpeed","FanSpeedParameters":{"FanSpeed":"Low"}}}`; zone status shows `"FanSpeed"`.
* Button press: `CreateRequest /button/N/commandprocessor` `{"Command":{"CommandType":"PressAndRelease"}}`

## Pairing (adding a device)

1. `UpdateRequest /system/status` `{"SystemStatus":{"InAssociationMode":true}}`. Both `/system/status`
   and `/link/1/status` then report `Association` mode.
2. `SubscribeRequest /device/status/deviceheard`.
3. The user holds the device's button until it flashes rapidly. The bridge reports:
   ```json
   {"DeviceStatus":{"DeviceHeard":{"DiscoveryMechanism":"UserInteraction","ModelNumber":"PJ2-4B-GXX-P02",
     "DeviceType":"Pico4ButtonScene","SerialNumber":12345678,"EngravingKit":"Kitchen",
     "DeviceClass":{"HexadecimalEncoding":"1070225"},"Link":{"href":"/link/1"},"ProductId":"17236005"}}}
   ```
4. The bridge does **not** add the device by itself. The client creates it, during the same association
   session: `CreateRequest /device` with the heard fields (without `Link`) plus `Name` and
   `AssociatedArea`. The answer is `201 Created` with the new device and its buttons.
5. `UpdateRequest /system/status` `{"SystemStatus":{"InAssociationMode":false}}`.

Errors seen:
* `CreateRequest /device` without `Name` returns `400` `"The body is missing a required property : Name"`.
* `CreateRequest /device` for a device not heard in the current session (or an invented serial) returns
  `500` `{"Message":"Device could not be added.","ErrorCode":11}`.
* A device heard again after it was added is reported with `"ErrorCode":7`.
* `CacheDeviceHeard` on `/link/1/commandprocessor` (used by newer systems) returns `400`
  `"Unsupported link type provided of 9"`. `AddressDevice` and `ActivateDevice` return
  `"This command is not supported"`.

## Health and system

* `ReadRequest /device/status`: per device `ConfigurationTransferStatus` (`NotRequired`, `Required`) and
  `FailedTransfers.Count`. A device stuck at `Required` with a growing count (for example an unplugged
  wireless repeater) isn't getting its settings. Picos report `BatteryStatus` `Unknown`.
* `/system`: `TimeZone`, `Latitude`/`Longitude` (used for sunrise and sunset), and `Date`/`Time` in UTC.
* `/system/away` and `/system/away/1/status`: Smart Away hours and `EnabledState`.
* `/service`: Sonos, HomeKit (`BonjourServiceName`), Alexa, GoogleHome, IFTTT (each with a
  `/datasummary` of exposed devices), AutoProgrammer.
* `/networkinterface/1`: IP settings (`"Type":"DHCP"` means the bridge address can change unless the
  router reserves it).

Returned `400` "This request is not supported" on this repeater: `/area/summary`, `/zonegroup`,
`/zonescene`, `/areascene`, `/dailyschedule`, `/naturallightoptimization`, `/devicerule/N`,
`/buttongroup/expanded`, `/loadcontroller`, `/zonecontroller`. Returned `405`: `/project/masterdevicelist`,
`/controlstation`, `/shadegroup`.
