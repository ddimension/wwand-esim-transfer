# wwand-esim-transfer — status

Last updated 2026-11-21. Pushed: this repo (main) and the core commits it
needs (wwand main 832dbf6: modem_esim dep, discovery, notify seq). Feed:
committed on feed main, NOT pushed.

## Decisions (user, 2026-11-21)

- Scope: Tier 1 + 2 + 3.
- Packaging: its own plugin repo.
- ucode ships as **bytecode** (user, 2026-11-21).
- TS.43 identity: honest by default, overridable. This was my
  recommendation, not a decision; the user has not answered.

## Done

### This repo

Host tests: 4 suites × source/bytecode, all green
(`WWAND_SRC=<wwand> sh tests/run_tests.sh`).

- `esim_transfer/*.uc` are ES modules compiled to bytecode by `CMakeLists.txt`:
  - the wwand rules (probe + source fallback, explicit lists with a drift
    check, namespaced imports, no `-`);
  - checked with the host ucode and the SDK host ucode;
  - `plugins/esim_transfer.uc` and `ctl/transfer.uc` are source shims (they
    are require()d);
  - `libexec/esim-transfer-card` is compiled as a program.
- `sha1.uc`: SHA-1 (+compression), HMAC, FIPS 186-2 PRF.
- `aka.uc`: EAP-AKA. The server AT_MAC is verified; `lax` for synthetic
  vectors.
- `ts43.uc`: the full ODSA session with a fake-server test.
- `meta.uc`: GetProfilesInfo incl. DeviceChangeConfiguration (BF20).
- `hints.uc` + docs/operators.md: DE operators with sources.
- `http.uc`: uclient. Limit: only one Set-Cookie survives.
- `plugin.uc`:
  - release with a guaranteed delete notification (retried per session /
    5 min, persisted in /etc/wwand/esim-transfer/releases.json);
  - import, discovery, meta, `usim_check`;
  - TS.43 start/resume/install/cancel;
  - `qr` (qrencode SVG).
- `ctl.uc`: `wwandctl transfer …`.
- LuCI page + menu + ACL (`node --check` ok; not tried in a browser).
- `packaging/Makefile`: feed DRAFT (placeholders for commit and hash).

### Hardware (2026-11-21)

- **NR7101** (192.168.5.202, RG502Q-EA, Telekom SIM, AT APDU backend):
  - Plugin deployed additively as bytecode compiled on the device (ucode
    2026.07.09).
  - `wwandctl transfer check`: USIM channel by partial AID ok, MNC length 2,
    GID1 01, AUTHENTICATE 9862. A HW bug was fixed: the event field `gid1`
    never arrived (event_payload takes only `[a-z_]+`), now `group_id`.
  - The connection (READY, ping) and IMS over VoWiFi were unaffected.
  - **The plugin is still installed there:**
    /usr/share/ucode/wwand/{esim_transfer/,plugins/esim_transfer.uc,ctl/transfer.uc},
    /usr/libexec/wwand/esim-transfer-card.
  - The core changes are NOT on the device.

## Since the first handover

- Debug trace per modem (200 lines, masked): `wwandctl transfer log`, LuCI.
- Progress: release steps, live download, TS.43 step bar + timeline.
- Pre-flight check `check` (SIM, USIM, eUICC, server, login, eligibility;
  stops before ManageSubscription). `usim` is the read-only probe.
- Review fixes:
  - the guarded eSIM path (dep modem_esim);
  - an unreadable notification list no longer counts as delivered;
  - pacing after a failed list;
  - F-padded ICCIDs;
  - install without a ProfileIccid;
  - `\s` in brackets (cookie parser).

## Hardware, Chateau (2026-11-21)

RG650E-EU, QMI; slot 1 physical Telekom SIM, slot 2 eUICC with a Vodafone
prepaid profile.
- **Telekom:** login (strict AT_MAC) and token; CheckEligibility refuses
  that number ("nicht für einen Transfer freigeschaltet").
- **Vodafone DE:** login only with the curl transport (Imperva sets four
  cookies, uclient keeps one → relay 400); token; CheckEligibility
  `PrimaryAppEligibility=0`. Probably the device identity: Vodafone names
  phone models, and we are honest.
- **Conversion check** with the physical SIM active: the eUICC in slot 2 was
  found through the slot list.
- **Bugs found on the device and fixed:**
  - no /etc/wwand → no state directory, writes lost silently;
  - transfer type by source;
  - uclient's cookies → curl transport (wwand-lpac-curl);
  - the event field `gid1` (NR7101).
- **Restored:**
  - slot 2 active, wwand0 + wwims CONNECTED;
  - the temporary uclient.so and curl removed;
  - plugin and LuCI page remain (additive);
  - /etc/wwand/esim-transfer/carriers.json remains.
- **Config note:** the Chateau has `option sim_slot '1'`, but slot 2 was
  active. Every wwand restart switches it to slot 1.

## Second Chateau round (2026-11-21, after its firmware update)

- New image r0-6c8f101b: its wwand core already has the modem_esim dep,
  discovery and notify seq.
- Installed:
  - `wwand-lpac-curl` (local SDK build, unsigned, `apk add
    --allow-untrusted`): static curl 8.21.0 / wolfSSL 5.9.2;
  - the plugin as bytecode, compiled on the device.
- Vodafone 262 02 eSIM profile:
  - login ok;
  - CheckEligibility `PrimaryAppEligibility=0` (type 3), no other field.
- Fixes from it:
  - the source is an eSIM when the slot list says the eUICC is active (the
    profile list was still empty 90 s after the switch);
  - the refusal's answer goes into the trace;
  - the checklist shows PrimaryAppEligibility;
  - "onto this router" is refused when the source is already one of its
    profiles.
- Restored: slot 1 (config sim_slot 1), wwand0 + wwims CONNECTED. The plugin,
  LuCI page and wwand-lpac-curl stay installed.

## Open

1. A transfer past CheckEligibility: needs a subscription the operator
   enables (the two numbers tried are refused); whether Vodafone accepts a
   router identity is open.
2. HW: discovery, release + notify seq (only with a profile that may be
   deleted!), meta.
3. The feed commit (wwand-esim-transfer/Makefile) is on feed main, not
   pushed.
4. Not covered: EAP-AKA', embedded websheet, several Set-Cookie.
