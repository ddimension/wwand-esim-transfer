// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// The profile list as esim-transfer-card reads it (ES10c GetProfilesInfo
// with the SGP.22 v3 tags), parsed down to what a transfer needs: the ICCID,
// whether the profile is enabled, its provider name, and its Device Change
// configuration (SGP.22 v3.1 2.4a.1.9).
//
// A v2 eUICC (all we have on the bench, 2026-11) leaves BF20 out: `dc` is
// then null, which is the common case and not an error. With one:
//   { method: 'request_to_dp', smdp, eid_required, tac_required }
//     the old device asks that SM-DP+ (ES9+ device change, SGP.22 3.11.1.2)
//     — not implemented here, no SM-DP+ offers it yet (lpac#130, 2024-07)
//   { method: 'stored_ac', activation_code, delete_old_profile }
//     the profile carries its own activation code for the new device
//     (3.11.1.1): hand it over, and delete this profile first when asked
//
// An ES module, precompiled to bytecode; exports { parse_profiles, ber }.

'use strict';

import * as S from 'wwand.esim_transfer.sha1';

// BER TLV list over a byte array: [ { tag (hex), val (bytes) } ]; null when
// the encoding is broken
function ber(b, from, to)
{
	let out = [];
	let i = from ?? 0, end = to ?? length(b);

	while (i < end) {
		let t0 = i;

		if (b[i] == 0x00 || b[i] == 0xFF) { i++; continue; }   // padding

		if ((b[i++] & 0x1F) == 0x1F)
			while (i < end && (b[i++] & 0x80)) ;

		if (i >= end)
			return null;

		let tag = S.b2h(slice(b, t0, i));
		let len = b[i++];

		if (len & 0x80) {
			let n = len & 0x7F;

			if (n < 1 || n > 3)
				return null;

			len = 0;

			for (let k = 0; k < n; k++)
				len = (len << 8) | b[i++];
		}

		if (i + len > end)
			return null;

		push(out, { tag: tag, val: slice(b, i, i + len) });
		i += len;
	}

	return out;
}

let find = (l, tag) => filter(l ?? [], (x) => x.tag == tag)[0];
let utf8 = (b) => chr(...(b ?? []));

// the ICCID is BCD with the nibbles swapped, F padded (ITU-T E.118)
function iccid_of(b)
{
	let s = '';

	for (let x in b ?? [])
		s += sprintf('%X%X', x & 0x0F, x >> 4);

	return replace(s, /F+$/, '');
}

function dc_of(b)
{
	let l = ber(b);
	let rq = find(l, 'A0'), st = find(l, 'A1');

	if (rq) {
		let f = ber(rq.val) ?? [];
		let nulls = filter(f, (x) => x.tag == '05');

		// eidRequired and tacRequired are both untagged NULLs, told apart
		// only by order (SGP.22 v3.1 2.4a.1.9): one NULL is the first
		return { method: 'request_to_dp', smdp: utf8(find(f, '0C')?.val),
		         eid_required: length(nulls) >= 1, tac_required: length(nulls) >= 2 };
	}

	if (st) {
		let f = ber(st.val) ?? [];

		return { method: 'stored_ac', activation_code: utf8(find(f, '0C')?.val),
		         delete_old_profile: !!find(f, '05') };
	}

	return { method: 'unknown' };
}

// response hex (BF2D …, the SW already stripped) → { profiles } | { error }
function parse_profiles(hexstr)
{
	let top = ber(S.h2b(hexstr ?? ''));
	let bf2d = find(top, 'BF2D');

	if (!bf2d)
		return { error: 'response' };

	let inner = ber(bf2d.val);
	let ok = find(inner, 'A0');

	if (!ok)
		return { error: 'profile_info_error', code: S.b2h(find(inner, '81')?.val ?? find(inner, '80')?.val ?? []) };

	let res = [];

	for (let e in filter(ber(ok.val) ?? [], (x) => x.tag == 'E3')) {
		let f = ber(e.val) ?? [];
		let dc = find(f, 'BF20');

		push(res, {
			iccid: iccid_of(find(f, '5A')?.val),
			enabled: (find(f, '9F70')?.val?.[0] == 1),
			provider: utf8(find(f, '91')?.val) || null,
			name: utf8(find(f, '92')?.val) || null,
			nickname: utf8(find(f, '90')?.val) || null,
			dc: dc ? dc_of(dc.val) : null,
		});
	}

	return { profiles: res };
}

export { ber, parse_profiles, iccid_of };
