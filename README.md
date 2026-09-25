# groundcontrol

**Nothing touches the radio without clearance.**

A single-screen TUI for running the ADS-B stack on a [ClockworkPi uConsole](https://www.clockworkpi.com/uconsole)
fitted with a **HackerGadgets AIOv2** board. It handles the two things that make that combination
annoying: the SDR and GPS sit behind GPIO power rails that must be switched on in the right order,
and only one process at a time can hold the RTL-SDR.

```
╔══════════════════════════════════════════════╗
║  uConsole AIOv2 — ADS-B Control              ║
╚══════════════════════════════════════════════╝
 SDR ● ON    GPS ● ON    BATT 87% ▲ Charging
 readsb ● active     tar1090 ● active
 gpsd   ● active     fix: 3D 49.19472,-123.18250 (9 sats)
 position: yvr 49.19472,-123.18250 (preset)
────────────────────────────────────────────────
   1) Start ADS-B receiver + web map
   2) Stop ADS-B receiver
   3) viewadsb        (CLI table, runs alongside readsb)
   4) ACARS decoder   (acarsdec — takes the radio)
   5) VDL Mode 2      (dumpvdl2 — takes the radio)
   6) rtl_adsb raw    (takes the radio)
   7) Kismet ADS-B    (takes the radio)
   8) GPS / location manager  ▸
   9) Power rails             ▸
   f) Frequency reference     ▸  (ADS-B / ACARS / VDL2)
   s) Full status                          q) Quit
────────────────────────────────────────────────
  Select:
```

## The problems it solves

**Power rails come first.** The AIOv2 puts the RTL-SDR and the GPS behind GPIO rails switched by
`aiov2_ctl`. `readsb.service` is enabled at boot, so if the SDR rail is off, readsb sits in a
restart loop — exit 1, every 15 seconds — because the RTL device simply doesn't exist. `groundcontrol`
enforces the ordering: **rail on → wait for USB enumeration → start services.** Turning the SDR rail
*off* while readsb is running warns you and offers to stop readsb and tar1090 first, which is the
other half of the same footgun.

**One radio, many decoders.** readsb, `acarsdec`, `dumpvdl2`, `rtl_adsb` and Kismet all want
exclusive access to the RTL. Picking any of them prompts to stop readsb first, then restores it when
the tool exits — **including on Ctrl-C**.

`viewadsb` is the deliberate exception: it reads Beast data over TCP `:30005` rather than touching
the radio, so it runs happily alongside readsb.

**GPS never conflicts.** It's on `/dev/ttyAMA0` (serial) while the SDR is USB, so the GPS rail can
be left on permanently.

## Requirements

Built for one specific machine. It will not do anything useful without:

| | |
|---|---|
| Hardware | ClockworkPi uConsole + HackerGadgets AIOv2, RTL-SDR, serial GPS on `/dev/ttyAMA0` |
| Rail control | `aiov2_ctl` |
| Core | `readsb`, `tar1090` (web map on `:8504`), `bash` 4+, `systemd`, `sudo` |
| Optional | `viewadsb`, `acarsdec`, `dumpvdl2`, `rtl_adsb`, `kismet`, `gpsd` + `jq` (GPS features) |

`sudo` will prompt — rail toggles and `systemctl` need root.

## Install

```sh
git clone https://github.com/DFIR-Life/groundcontrol.git
cd groundcontrol
chmod +x groundcontrol.sh
./groundcontrol.sh
```

No arguments, no flags — it's a menu.

## Live status header

Redrawn on every loop, so you can see the state of the stack before choosing anything:

- **SDR / GPS rails** — filled dot for on, hollow for off
- **Battery** — percentage with charge direction, amber under 40%, red under 15%
- **`readsb` / `tar1090` / `gpsd`** — systemd unit state
- **GPS fix** — mode, position to 5 decimals, satellite count; a truncated reason when there's no fix
- **Active position** — the location currently in effect and where it came from

The GPS fix line only costs time when `gpsd` is actually running.

## GPS and locations

`groundcontrol` keeps a small location store so you can move the receiver around without hand-editing
config:

- Save the current GPS fix as a named location
- Save an arbitrary lat/lon by hand
- Pick a saved location as active
- Push the active position into `/etc/default/readsb` — **the only system file this script writes**

State lives in `~/.config/adsb-menu/`:

| File | |
|---|---|
| `locations.tsv` | `name<TAB>lat<TAB>lon<TAB>source<TAB>timestamp` — plain TSV, hand-editable |
| `active-location` | the currently selected entry, same format |

> The config directory keeps the project's old `adsb-menu` name deliberately, so saved locations
> survive the rename. It's flagged in the source — don't "tidy" it.

Two public reference points ship as presets: **YVR** airport and **Burnaby Fraser Foreshore Park**.
A `home` entry is seeded *only* if `/etc/default/readsb` already has a `--lat`/`--lon` configured on
your machine — there is no hardcoded fallback, because a receiver position is personal data.

## Frequency reference

The `f` menu carries offline tables for ADS-B/Mode S, ACARS, and VDL Mode 2, with region and decoder
notes for each entry, plus explanatory notes on what's actually decodable with this hardware. It can
write the whole reference out to a file.

## Notes

Receiver coordinates are your home address to five decimal places. If you feed a public aggregator or
share screenshots, be deliberate about which position is active — the header always shows you which
one is in effect, which is much of why it's there.

The GPS module ships with a firmware quirk worth knowing: a cold or jammed unit can report a
plausible-looking `30.0000N/120.0000E` (Zhejiang, CN) with no satellites listed and no GSV sentences.
The fix logic rejects it; the reason shows in the header.

## License

MIT — see [LICENSE](LICENSE).

