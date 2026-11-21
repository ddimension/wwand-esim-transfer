// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// What the operator of a SIM does when its eSIM moves to another device:
// where the user gets a new activation code, whether that code works more
// than once, and what to do first. Shown next to a release and an import.
//
// Keyed by the IMSI's MCC+MNC. Brands share their host network's code
// (congstar on Telekom, Aldi Talk on o2), so a hint names the network and
// says when its brands differ. Operators change these flows without notice:
// every entry carries the date it was checked and its source, and the full
// table with links is docs/operators.md. "verified" means read on the
// operator's own page; "reported" means a third-party source.
//
// An ES module, precompiled to bytecode; exports { hint_for, HINTS }.

'use strict';

const HINTS = {
	'26201': {
		operator: 'Telekom Deutschland',
		code: 'MeinMagenta app / Kundencenter → Meine SIMs → Einstellungen → Aktivierungscode (QR)',
		reusable: false,
		reusable_source: 'reported (teltarif, 2020-06-13): single-use profiles',
		ts43: true,
		ts43_source: 'verified (telekom.com press release, 2025-10-07): transfer based on GSMA TS.43',
		note: 'Brands on this network (congstar) issue their own codes.',
		checked: '2026-11-21',
	},
	'26202': {
		operator: 'Vodafone Deutschland',
		code: 'MeinVodafone → SIM-Karte tauschen → Wechsel des Geräts: new profile (QR + 6-digit ePIN); prepaid via hotline',
		reusable: true,
		reusable_source: 'verified (vodafone.de/privat/hilfe-support/esim.html): a deleted profile can be downloaded again with the same code and ePIN once the old device is decoupled from its EID',
		ts43: true,
		ts43_source: 'verified (same page): transfer between iPhone 11+/iOS 17+, Galaxy, Pixel 9a+; not for OneNumber',
		note: 'Release the profile here first (delete + notification) so the old EID is decoupled.',
		checked: '2026-11-21',
	},
	'26203': {
		operator: 'o2 Telefónica Deutschland',
		code: 'Mein O2 → SIM verwalten → eSIM (QR)',
		reusable: false,
		reusable_source: 'reported (teltarif, 2020): single-use',
		ts43: true,
		ts43_source: 'verified (hilfe.o2online.de, 2026-07-20): Android quick transfer, prepaid only',
		note: 'Brands on this network (Aldi Talk) issue single-use QR codes of their own.',
		checked: '2026-11-21',
	},
	'26223': {
		operator: '1&1',
		code: 'Control-Center → Einstellungen und Services → Neue SIM anfordern → eSIM, or the hotline',
		reusable: false,
		reusable_source: 'reported (teltarif): a new profile each time',
		ts43: true,
		ts43_source: 'verified (support.apple.com/123878, 2026-11-19): listed for Android → iPhone transfer',
		note: null,
		checked: '2026-11-21',
	},
};

function hint_for(imsi)
{
	if (!match(imsi ?? '', /^[0-9]{6,}/))
		return null;

	return HINTS[substr(imsi, 0, 5)] ?? HINTS[substr(imsi, 0, 6)] ?? null;
}

export { hint_for, HINTS };
