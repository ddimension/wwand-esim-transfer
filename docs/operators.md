# Operators: how an eSIM moves (Germany first)

Checked 2026-11-21. "verified" means read on the operator's own page;
"reported" means a third-party source. Operators change these flows
without notice. The hints the plugin shows (`esim_transfer/hints.uc`) are
taken from this table, so update both together.

| Network (MCC+MNC) | New code from | Code reusable? | TS.43 transfer | Fee |
|---|---|---|---|---|
| Telekom (26201) | MeinMagenta / Kundencenter → Meine SIMs → Einstellungen → Aktivierungscode | no: single-use profiles (reported, teltarif 2020-06-13) | yes: "based on GSMA TS.43", Android ↔ iOS since 2025-10 (verified, telekom.com press release 2025-10-07) | not stated (reported: none) |
| Vodafone (26202) | MeinVodafone → SIM-Karte tauschen → Wechsel des Geräts (QR + 6-digit ePIN); prepaid via hotline | yes, once the old device is decoupled from its EID (verified, vodafone.de/privat/hilfe-support/esim.html) | iPhone 11+ / iOS 17+, Galaxy, Pixel 9a+; not OneNumber (verified, same page) | 9.90 € (reported) |
| o2 (26203) | Mein O2 → SIM verwalten | no (reported, teltarif 2020) | iPhone (iOS 18.5+); Android since 2026-07-20, prepaid only (verified, hilfe.o2online.de) | free (reported) |
| 1&1 (26223) | Control-Center → Einstellungen und Services → Neue SIM anfordern → eSIM | no: a new profile each time (reported) | listed for Android → iPhone (verified, support.apple.com/123878, 2026-11-19) | free at the Drillisch brands (reported, 2025) |

Brands share their host network's MCC+MNC, but they issue codes their own way:
- congstar (Telekom network): re-issued through the account or app (reported);
- Aldi Talk (o2 network): "a QR can be used only once", 9.99 € (reported).

No reliable information was found for fraenk, freenet or Lebara/Lyca.

## Elsewhere (a sample)

- **Android → iPhone transfer** carriers (verified, support.apple.com/123878,
  2026-11-19):
  - US: AT&T, T-Mobile, Verizon
  - UK: EE
  - FR: Orange, SFR, Free
  - AT: A1, Magenta
  - CH: Swisscom
  - NL: KPN
- **Travel eSIMs** (Airalo, Holafly): not transferable (reported). A deleted
  profile is gone.

## Mechanisms behind it

- **A new or reusable activation code** (portal, app, hotline). This is plain
  SGP.22 download, and every operator offers it.
- **GSMA TS.43 ODSA.** This is what Apple Quick Transfer and Android "Transfer
  eSIM" run on (source.android.com esim-transfer-carrier-integration):
  - EAP-AKA against the source SIM, then CheckEligibility, then
    ManageSubscription;
  - the result is an activation code.
- **SGP.22 v3 Device Change** (§3.11). It is in the standard but not deployed;
  it needs a v3 eUICC, v3 profile metadata and an operator-configured SM-DP+
  (lpac#130, 2024-07).
