# wwand-esim-transfer

Moving an eSIM subscription off or onto an OpenWrt router that runs
[wwand](https://github.com/ddimension/wwand). A wwand plugin: it needs
`wwand-esim` and is not meant for wwand upstream.

An eUICC never hands a profile out. Moving a subscription always means: the
operator issues a **new** profile for the target device, and the old one is
deleted. This package does the parts a router can do.

| | What it does | Works with |
|---|---|---|
| **Release** | Disables and deletes a profile, then sends its delete notification to the operator's SM-DP+ until the SM-DP+ acknowledges it. Until it does, the operator may refuse to issue the profile elsewhere; Vodafone DE, for example, wants the old EID decoupled first. The card keeps the notification until an acknowledgement removes it, so "still listed" means "not delivered". wwand retries on every new data session and every 5 min. | every operator |
| **Import** | Downloads an activation code the operator issued (portal QR, ePIN). In LuCI the code can be read from a QR image. | every operator |
| **Discovery** | Asks the SM-DS (default `lpa.ds.gsma.com`) whether an operator queued a profile for this card's EID. | operators that push by EID |
| **Device Change** | Shows a profile's SGP.22 v3 Device Change settings (a stored code for the new device, or which SM-DP+ to ask). | SGP.22 v3 cards only, none on the market yet (2026-11) |
| **Transfer possible?** | A pre-flight checklist: SIM read, USIM reachable for AUTHENTICATE, eUICC on this router, entitlement server known, the operator's login (EAP-AKA), its CheckEligibility. Stops before anything is ordered. | operators with a TS.43 server |
| **TS.43** (experimental) | The router's SIM proves the subscription with EAP-AKA to the operator's entitlement server (GSMA TS.43 ODSA), which issues a profile for this router's eUICC (physical SIM → eSIM) or for another device (shown as a QR). | operators with a TS.43 server that accepts a router |

Operator notes, with sources: [docs/operators.md](docs/operators.md). TS.43
details: [docs/ts43.md](docs/ts43.md).

## Use

```
wwandctl transfer                      # releases, discovery, TS.43, operator hint
wwandctl transfer check                # is a transfer possible? (orders nothing; exit 0 = yes)
wwandctl transfer usim                 # can this modem reach the USIM for EAP-AKA (read-only)
wwandctl transfer log                  # the debug trace
wwandctl transfer release <iccid> [--force]
wwandctl transfer import 'LPA:1$smdp.example$CODE' [ePIN]
wwandctl transfer discovery
wwandctl transfer meta                 # profiles + Device Change settings
wwandctl transfer ts43 start --router  # this SIM onto this router's eSIM
wwandctl transfer ts43 start <EID> <IMEI>   # a profile for another device
```

In LuCI: Network → eSIM Transfer (`luci-app-wwand-esim-transfer`). The page
shows every workflow as its steps:
- the check as a checklist with ✔ / ✘ / – and a verdict;
- each release as disable → delete → operator notified, with times, the
  reason of a failed step, and *Retry now*;
- a download's live lpac progress;
- a TS.43 transfer as a step bar and a timeline.

It polls every 3 s while something runs.

**Debug log.** The plugin keeps the last 200 lines of what it did, per modem:
- the TS.43 requests and the server's verdicts (OperationResult,
  SubscriptionResult, ServiceStatus, the HTTP status, the start of an error
  body);
- every EAP round and what the card answered;
- every delivery attempt with lpac's result line;
- the check's steps.

IMSI, ICCID, IMEI and EID are cut to their first 5 and last 2 digits, and
tokens to 4 characters, so the log can go into a report as it is. It is
shown in LuCI (*Debug log*, with *Copy*) and by `wwandctl transfer log`, and
it also goes to the syslog at debug level.

TS.43 needs the operator's entitlement server. GSMA does not publish these
servers, so wwand ships none. Set it per modem:

```
config wwand_modem 'wwmodem0'
	option esim_transfer_server 'https://…'   # the operator's TS.43 URL
	option esim_transfer_post '1'             # if it wants POST+JSON
```

or put records into `/etc/wwand/esim-transfer/entitlement.json` (an array in
the record format of damonto/ts43-go, matched by MCC+MNC, GID1, GID2, SPN or
IMSI pattern). The router identifies itself as what it is:
`terminal_vendor OWRT`, the modem model, an `OS-OpenWrt` User-Agent.
`esim_transfer_vendor` / `_model` / `_sw` change that, at your own risk:
operators' terms may not allow presenting another device.

Other options: `esim_transfer_mnc_len` (when EF_AD is unreadable),
`esim_transfer_type` (the operator's transfer type), `esim_transfer_smds`,
`esim_transfer_lax_mac` (answer a challenge whose AT_MAC does not verify; only
for broken test servers).

## Build

The ucode ships **precompiled to bytecode** (`CMakeLists.txt`). This follows
the wwand tree's rules: one compiler run per file, namespaced imports,
`dynlink=` for every module, no `-` in module paths, a capability probe that
falls back to shipping source on a ucode without `-cmodule`. Only the two
entry points wwand `require()`s by path, `plugins/esim_transfer.uc` and
`ctl/transfer.uc`, stay source. Each is a two-line shim in front of the
bytecode module. The feed package is drafted in `packaging/Makefile`.

## Tests

```
WWAND_SRC=../wwand sh tests/run_tests.sh
```

Every suite runs twice, on the source and on the bytecode the CMakeLists
builds with the same ucode:
- crypto against the FIPS 180 / RFC 2202 / FIPS 186-2 vectors and AOSP's
  EAP-AKA vector;
- the TS.43 session against a fake entitlement server that runs a real AKA
  exchange;
- the card helper against a scripted APDU host;
- the plugin engine against a fake card.

## Not verified on hardware yet

- Does each modem backend open a logical channel to the USIM by its partial
  AID (`A0000000871002`)? The TS.43 EAP-AKA depends on it.
- Which TS.43 servers accept a router. Telekom first.
- Several `Set-Cookie` headers: uclient keeps only the last one
  (`esim_transfer/http.uc`).

## License

GPL-2.0-only.
