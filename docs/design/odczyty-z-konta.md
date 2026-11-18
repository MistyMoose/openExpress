# Design: readings from the Garmin Connect account

Status: waiting for review; nothing is implemented. Each decision of section 7 (D1–D10) has the
option proposed. What the read-only check on the account (section 6) showed is in section 2, and
D1, D2 and D5–D7 follow it; D4 waits for what the check has yet to show.

## 1. Scope

Three readings from the account the user is signed in to, shown in the window and printed by the
command line. Sensors and solar charging only read; a report is made on Garmin's side and fetched
(section 5). Nothing is changed on the account or on a device.

1. **Sensor batteries**: the battery of the sensors on the account (a Varia radar or light, a heart
   rate strap, a power meter, a speed or cadence sensor).
2. **Solar charging** of a device that charges from the sun (a fēnix 8 Solar, an Instinct Solar, an
   Edge Solar): the activity time it gained today and in the last 7 days.
3. **Reports from Garmin Connect as PDF files**: a kind of report and a period, saved to a file.

Out of scope: any change of a sensor or its pairing, the solar intensity over a day and its chart,
the transfer of a device's settings to a new device, and anything Garmin Connect shows only on a
phone through Bluetooth.

## 2. What is known of Garmin's servers

Facts about the interface only, as Garmin Connect asks them; nothing of its code (section 9). The
last column says what the check found for openExpress's own sign-in.

| Reading | Request | Its answer for openExpress's sign-in |
|---|---|---|
| Sensors | `GET /device-service/sensors` | a list, one item per sensor on the account: `deviceName`, `sensorType`, `batteryLevel`, `batteryStatus`, `lastConnected`, `lastLowBatteryNotification`, `rechargeableSensorCapable`, `prioritySensor`, `manufacturer`, `productId`, `partNumber`, `softwareVersion`, `serialNumber`, `imageUrl`. No field names the device a sensor is paired with. |
| Which device charges from the sun | `GET /device-service/deviceregistration/devices` (the account's devices, asked already) | `solarChargeCapable` and `solarPanelUtilizationCapable`, truth values, for each device; `solarChargeCapable` is false for every device of the account, a fēnix 8 Solar among them, so it does not mark a model that charges from the sun; the device's `deviceId` is what the solar requests take |
| Solar gain | `GET /device-service/devicemonitoring/solargain/{deviceId}/{start}/{end}` | one item per day of the period, days without gain too: `localConnectDate`, `totalActivityTimeGainedMs` |
| Solar, the phone's day view | `GET /mobile-gateway/solar/{deviceId}/{localStartDate}/{localEndDate}` | the solar input of each day, together with the user's sleep of each day and a list of activities |
| Reports | `POST /reportexport-service/export/init/{reportCategory}/{fromDate}/{toDate}?locale=` (`reportSubCategory`, `reportFormat`, `contentToSkip`, `requestedDateFormatKey`) → `reportId`; `GET …/export/reportStatus/{reportId}`; `GET …/export/reportContent/{reportId}` (the PDF); `DELETE …/export/ack/{reportId}` | the status of a report that does not exist: 400 with `error` and `message`, not a refusal: the sign-in passes the service. Formats `Daily`, `SevenDays`, `FourWeeks`, `Yearly`; categories among them `bloodpressure`, `wellnessactivity` |

Values seen of `batteryStatus`: `GOOD`, `NEW`, `OK`, `UNKNOWN`; of `sensorType`: `BIKE_LIGHT_MAIN`,
`BIKE_POWER`, `BIKE_SPEED`, `HEART_RATE`. `batteryLevel` is none or a whole number from 0 to 100;
`lastConnected` is text of the form `YYYY-MM-DDThh:mm:ss.f`, with no time zone;
`lastLowBatteryNotification` is none or the same form with milliseconds; `rechargeableSensorCapable`
is none or a truth value. Still not known: which flag, if any, marks a device that charges from the
sun; whether `lastConnected` is in UTC or local time; what kind of value the solar gain holds; and
the whole list of report categories. The program uses only fields seen in an answer for its own
sign-in, and reads values whose kind is not known as not there.

The sensors of an activity are also in the activity's FIT file: each `device_info` message (public
FIT profile) of a connected sensor carries its type and its battery status (new, good, OK, low,
critical, charging, unknown). That source needs no account and no network, but holds only the
sensors of that activity (D1).

## 3. Sensor batteries

The account keeps one list of sensors, without the device each is paired with, and a sensor is
often paired with more than one device. The list is shown as the account's, on the page of each
device of the account (D2):

```
Account Sensors                             5 sensors · 1 with a low battery   ›
  Varia RTL515            Battery low · last connected 2 days ago      (warning colour)
  HRM-Pro Plus            Battery 80% · last connected today
  Speed Sensor 2          Battery good · last connected 5 days ago
```

- An expander row **Account Sensors** / **Czujniki na koncie**, after the rows of the account: its
  subtitle says how many and, when there are any, how many have a low or critical battery
  (`ngettext`); open, a row for each sensor, its name as the account names it (`deviceName`).
- A sensor's line: the battery (`batteryLevel` as a percentage when it is a number, else
  `batteryStatus` in words), then when it was last connected (`relative_time`), joined by
  `caption()`. A low or critical battery takes the theme's warning colour, as an update does, and
  such sensors come first; the rest by the last connection, the newest first.
- Only on the page of a device on the signed-in account; no sensor: the row is not shown.
- **Signed out:** the row with "Sign in to see" (the words of the other rows of the account), not
  expandable. **No answer and nothing kept:** "Could not check". **No network, an answer kept:** the
  kept answer, as for the other readings of the account.
- Not shown, not kept, not logged: the serial number, part number, product, software version and
  picture of a sensor.

**Texts** (English by GNOME's guidelines, Polish in sentence case):

| Where | English | Polish |
|---|---|---|
| Row title | Account Sensors | Czujniki na koncie |
| Its subtitle | {count} sensor(s) · {low} with a low battery | {count} czujnik(i/ów) · {low} ze słabą baterią |
| Battery, by percentage | Battery {percent}% | Bateria {percent}% |
| Battery, by status | Battery good / Battery new / Battery OK / Battery low / Battery critical / Charging / Battery status unknown | Bateria dobra / Bateria nowa / Bateria w porządku / Bateria słaba / Bateria krytyczna / Ładowanie / Stan baterii nieznany |
| Last connected | last connected {when} | ostatnio połączony {when} |

`LOW`, `CRITICAL` and `CHARGING` are not yet seen; their words follow the FIT profile's battery
status. A status not known is shown as it comes.

**Command line:** `openexpress sensors`: a line for each sensor, its name, battery and last
connection; exit code 1 when not signed in or without an answer, as the other commands of the
account.

**Kept answers:** a kind `SENSORS` in `answers`, 30 minutes; on disk only the name, type, battery
level and status, last connection and whether it is rechargeable. Refresh in the header, a sync of
a device (it may have brought new batteries) and another sign-in forget it.

## 4. Solar charging

**What the user sees** (device page, beside the device's storage), only for a device that charges
from the sun (D4), its entry on the account found by its unit ID as the ownership check finds it:

```
Solar Charging        Activity time gained: today 35 min · last 7 days 4 h 10 min
```

The figure is the one the account keeps per day: how much activity time the sun added to the
battery (D5). "Today" is the day whose date is today's on this computer; a day without gain counts
0, so the row shows "0 min" rather than nothing.

| Where | English | Polish |
|---|---|---|
| Row title | Solar Charging | Ładowanie słoneczne |
| Its subtitle | Activity time gained: today {today} · last 7 days {week} | Zyskany czas aktywności: dziś {today} · ostatnie 7 dni {week} |

Times by `duration_text`, which learns hours ("4 h 10 min"). Signed out, no answer, no network: as
the sensors. **Command line:** `openexpress solar [--days N]` (7 by default): a line for each day.
**Kept answers:** a kind `SOLAR`, 60 minutes; on disk only the date and the time gained of each
day; refresh, a sync of the device and another sign-in forget it.

## 5. Reports from Garmin Connect

**What the user sees:** in the main menu, **Garmin Connect Reports…** / **Raporty Garmin Connect…**,
which opens a dialog:

```
        Save a Report from Garmin Connect
  Report     [ Wellness Activity        ▾ ]
  Period     [ 7 Days                   ▾ ]
  Ending     [ today                    ▾ ]
             [ Cancel ]          [ Save… ]
```

- **Save…** opens the save dialog in `Documents/Garmin/Reports` (beside the backups), with the name
  `garmin-<kind>-<from>-<to>.pdf`; the report is made while the window says "Making the Report…",
  then a toast "Report saved" with **Open**.
- The kinds offered: those the first export shows to work (D7); the periods: Day, 7 Days,
  4 Weeks, Year (the four formats).
- A report with no data in it, or a server that does not finish it in a minute, is said in a
  message; nothing is saved.
- Signed out: the menu item asks to sign in first. Without a network: the network error, as
  anywhere else.

| Where | English | Polish |
|---|---|---|
| Menu item | Garmin Connect Reports… | Raporty Garmin Connect… |
| Dialog heading | Save a Report from Garmin Connect | Zapisz raport z Garmin Connect |
| Fields | Report, Period, Ending | Raport, Okres, Koniec okresu |
| Periods | Day, 7 Days, 4 Weeks, Year | Dzień, 7 dni, 4 tygodnie, Rok |
| Button | Save… | Zapisz… |
| While it runs | Making the Report… | Przygotowywanie raportu… |
| Toast | Report saved | Zapisano raport |

**Command line:** `openexpress connect-report KIND --period day|7d|4w|year [--until DATE]
[--output FILE]`; without `--output` the file goes to `Documents/Garmin/Reports` under the name
above and is never written over (a number is added). It writes only a file on this computer, so it
takes no `--apply` (D8). **Kept answers:** none; the file is what is kept.

The export makes a report on Garmin's side and removes it after the download (`ack`): no data of
the account changes, but these requests are not reads, so the window offers reports only once an
export on a real account has gone through all four requests.

## 6. The check on the account

A short script outside the repository, run with openExpress's own sign-in (inside the Flatpak
when that is where the sign-in is). Only GET requests, past the program's kept answers and with no
log; it prints each request's HTTP status and the shape of its answer (key names, item counts, the
distinct values of `batteryStatus` and `sensorType`, and what kind of value a field holds: a
number, text with digits as 9, or none), never a name, a number, a date or an identifier. It asks
the sensors, the account's devices, the solar gain of the device that charges from the sun, and the
status of a report that does not exist. What it showed is in section 2.

Before the core step it has yet to show: for each device of the account, whether its name says
Solar beside the truth values of both flags (D4); what kind of value the solar gain holds and
whether any day of it is more than 0; and whether any sensor's last connection read as UTC is later
than now (then it is local time). The phone's day view is not needed (D6). If the check cannot tell
the time zone, `lastConnected` is read as UTC: the account names its local times so (`…Local`), and
a wrong guess moves "today" or "yesterday" only near midnight.

## 7. Decisions

**D1. Where the sensor batteries come from.** (a) The account (section 2); (b) the newest activity
on the device (`device_info`, public FIT profile), with no account and no network; (c) the account,
and the activity when not signed in. *Proposed: (a)*: the account has every sensor with its
battery and last connection; an activity has only the sensors used in it.

**D2. Where the sensors are shown.** The account does not say which device a sensor is paired with.
(a) As the account's list, on the page of each device of the account, titled so; (b) on the start
page, under the tiles; (c) on a device's page only the sensors its newest activity names, matched
with the account's by serial number in memory. *Proposed: (a)*: a sensor is often paired with more
than one device, the start page is seldom seen once a device is connected, and (c) reads the
device and misses the sensors not used lately.

**D3. How often.** *Proposed:* kept 30 minutes (sensors) and 60 (solar); asked when the device page
is shown; Refresh, a sync of the device and another sign-in forget them. No timer.

**D4. Which devices have Solar Charging.** `solarChargeCapable` does not tell (false for a fēnix 8
Solar). (a) `solarPanelUtilizationCapable`, if it is true for the solar model and false for the
others; (b) the model's name on the account saying Solar; (c) a device whose solar gain is ever
more than 0. *Proposed: (a)* if the check on the account shows it, else (b); (c) would hide the
row of a solar device in a dark week.

**D5. What the solar row says.** (a) The activity time gained, today and in the last 7 days; (b) the
same a day at a time, in an expander row; (c) the solar intensity over a day, with a chart.
*Proposed: (a)*; the days one by one in the command line.

**D6. The solar request.** *Proposed:* `solargain`: it answers with the time gained per day and
nothing else. The phone's day view (`mobile-gateway`) also sends the user's sleep and activities,
which this reading does not need.

**D7. Which reports.** *Proposed:* only the kinds that the first export shows to work; at first
Wellness Activity (`wellnessactivity`), which every watch has, and Blood Pressure (`bloodpressure`)
only for an account with readings. The whole list is learnt from the interface before the dialog
(section 8).

**D8. The command line and `--apply`.** *Proposed:* no `--apply`: the command changes no device and
no account data, and writes only the file named or the one under Documents.

**D9. Where the reports go.** (a) The save dialog, starting in `Documents/Garmin/Reports`; (b) that
folder with no dialog. *Proposed: (a)* in the window; the folder in the command line.

**D10. What the log says.** One line per request, as for every request (method, address without its
query, status, time; the address of a request that names the device left out, as the program does
for such requests); the report's kind and period; never a sensor's name, a value or the file's
name.

## 8. Steps

Each step: tests that fail on the code before it, the texts with their Polish in the same commit,
the usual checks; each waits for acceptance.

1. The check on the account (section 6): what it has yet to show, the solar flag, the solar gain
   and the time zone, before step 2.
2. Sensors and solar, the core: the requests, the kinds of kept answers, the reading of the fields,
   hours in `duration_text`; tests on made-up answers.
3. The command line: `openexpress sensors`, `openexpress solar`; `docs/cli.md`.
4. The window: mockups of the device page in English and Polish at 900 and 360 px, for acceptance;
   then the rows.
5. Reports, the core and `openexpress connect-report`: the four requests, waiting for the report (at
   most a minute), the file; an export on a real account through all four requests before the
   window offers reports, after the list of categories is learnt from the interface.
6. Reports in the window: mockups of the dialog for acceptance, then the dialog.
7. Documents: the guide, the command line, privacy (what is asked of the account).

## 9. Clean room

The requests and fields of section 2 are facts about the interface, kept in private notes with
where each was learnt and whether an answer for openExpress's sign-in showed it; nothing of Garmin
Connect's code, its structure or its names is copied or paraphrased. A field is used only once it
is seen in such an answer. The reading of `device_info` follows the public FIT profile.
