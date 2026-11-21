// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// EAP-AKA (RFC 4187) for a TS.43 entitlement server: the identity, the
// AKA-Challenge it sends, the USIM AUTHENTICATE that answers it, and the
// response packet. Pure functions, bytes as arrays (sha1.uc h2b / b2h).
//
// Only method 23 (EAP-AKA). A server that insists on EAP-AKA' (50, RFC 9048:
// AT_KDF, CK'/IK') is answered with an Authentication-Reject: the TS.43
// entitlement servers seen so far use 23 (GSMA TS.43 v13.0 2.8.1 names
// EAP-AKA; AOSP service_entitlement EapAkaApi implements only it, checked
// 2026-11-21).
//
// An ES module (precompiled to bytecode with the rest of the package).

'use strict';

import * as S from 'wwand.esim_transfer.sha1';

const EAP_REQUEST = 1, EAP_RESPONSE = 2, EAP_TYPE_AKA = 23;
const SUB_CHALLENGE = 1, SUB_REJECT = 2, SUB_SYNC_FAILURE = 4, SUB_CLIENT_ERROR = 14;
const AT_RAND = 1, AT_AUTN = 2, AT_RES = 3, AT_AUTS = 4, AT_MAC = 11;

// The permanent identity: '0' + IMSI @ the 3GPP EPC realm (3GPP TS 23.003
// 19.3.2, 19.3.3: the leading 0 selects EAP-AKA, the MNC in the realm always
// three digits). mnc_len is the MNC's length INSIDE the IMSI (2 or 3), which
// the IMSI cannot tell: it comes from EF_AD (TS 31.102 4.2.18) or the
// operator — a wrong one names a realm the server does not know.
function nai(imsi, mnc_len)
{
	if (!match(imsi ?? '', /^[0-9]{6,15}$/) || !(mnc_len in [ 2, 3 ]))
		return null;

	let mcc = substr(imsi, 0, 3), mnc = substr(imsi, 3, mnc_len);

	if (mnc_len == 2)
		mnc = '0' + mnc;

	return sprintf('0%s@nai.epc.mnc%s.mcc%s.3gppnetwork.org', imsi, mnc, mcc);
}

let str_bytes = (s) => map(split(s, ''), (c) => ord(c));

// An EAP request as { code, id, type, subtype, attrs: { <type>: value bytes } }
// or { error }. An attribute is type, length in 4-byte words, then its body;
// AT_RAND / AT_AUTN / AT_MAC keep two reserved bytes before the value
// (RFC 4187 10.6, 10.7, 10.15).
function parse(pkt)
{
	let n = length(pkt);

	if (n < 4)
		return { error: 'short' };

	let len = (pkt[2] << 8) | pkt[3];

	if (len != n)
		return { error: 'length' };

	let r = { code: pkt[0], id: pkt[1], type: (n > 4) ? pkt[4] : null,
	          subtype: (n > 5) ? pkt[5] : null, attrs: {}, mac_at: null };

	// requests and responses alike (a server-side check reads AT_RES and
	// AT_MAC from a response); step() refuses anything but a request
	if ((r.code != EAP_REQUEST && r.code != EAP_RESPONSE) || r.type != EAP_TYPE_AKA)
		return r;

	for (let i = 8; i + 2 <= n; ) {
		let t = pkt[i], l = pkt[i + 1] * 4;

		if (l == 0 || i + l > n)
			return { ...r, error: 'attribute' };

		r.attrs[sprintf('%d', t)] = slice(pkt, i + 2, i + l);

		if (t == AT_MAC)
			r.mac_at = i + 4;

		i += l;
	}

	return r;
}

// The USIM AUTHENTICATE command data for the 3G context (TS 31.102 7.1.2.1):
// L RAND L AUTN, as hex.
function auth_data(rand, autn)
{
	return sprintf('10%s10%s', S.b2h(rand), S.b2h(autn));
}

// The USIM's answer (TS 31.102 7.1.2.1): 'DB' L RES L CK L IK [L Kc] on
// success, 'DC' L AUTS on a synchronisation failure. Returns { res, ck, ik },
// { auts } or { error }.
function parse_usim(hexstr)
{
	let b = S.h2b(hexstr);
	let p = 1;
	let take = () => {
		if (p >= length(b))
			return null;

		let l = b[p];
		let v = slice(b, p + 1, p + 1 + l);

		p += 1 + l;

		return (length(v) == l) ? v : null;
	};

	if (b[0] == 0xDB) {
		let res = take(), ck = take(), ik = take();

		return (res && length(ck ?? []) == 16 && length(ik ?? []) == 16)
			? { res: res, ck: ck, ik: ik } : { error: 'usim_response' };
	}

	if (b[0] == 0xDC) {
		let auts = take();

		return (length(auts ?? []) == 14) ? { auts: auts } : { error: 'usim_response' };
	}

	return { error: 'usim_response' };
}

// K_aut from the master key (RFC 4187 7): MK = SHA1(Identity | IK | CK), the
// FIPS 186-2 PRF over MK, K_encr the first 16 bytes, K_aut the next 16.
function k_aut(identity, ck, ik)
{
	let mk = S.sha1([ ...str_bytes(identity), ...ik, ...ck ]);

	return slice(S.fips186_prf(mk, 32), 16, 32);
}

// AT_MAC = HMAC-SHA1-128(K_aut, the packet with the MAC value zeroed)
// (RFC 4187 10.15; no extra data for a challenge, 9.3 / 9.4)
function mac_of(kaut, pkt, at)
{
	let z = [ ...pkt ];

	for (let i = 0; i < 16; i++)
		z[at + i] = 0;

	return slice(S.hmac_sha1(kaut, z), 0, 16);
}

// does the server's AT_MAC prove it knew the same keys? A challenge without
// one, or with a wrong one, must not be answered (RFC 4187 9.3: the peer
// verifies AT_MAC before sending AT_RES)
function verify(req_bytes, req, kaut)
{
	if (req.mac_at == null)
		return false;

	let want = mac_of(kaut, req_bytes, req.mac_at);

	return S.b2h(want) == S.b2h(slice(req_bytes, req.mac_at, req.mac_at + 16));
}

let header = (id, sub, len) => [ EAP_RESPONSE, id, (len >> 8) & 255, len & 255, EAP_TYPE_AKA, sub, 0, 0 ];

// AKA-Challenge response: AT_RES (its length in BITS, RFC 4187 10.8) + AT_MAC
function challenge_response(id, kaut, res)
{
	let body = [ ...res ];

	while (length(body) % 4)
		push(body, 0);

	let at_res = [ AT_RES, (4 + length(body)) / 4, ((length(res) * 8) >> 8) & 255, (length(res) * 8) & 255, ...body ];
	let at_mac = [ AT_MAC, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 ];
	let len = 8 + length(at_res) + length(at_mac);
	let pkt = [ ...header(id, SUB_CHALLENGE, len), ...at_res, ...at_mac ];
	let at = 8 + length(at_res) + 4;
	let mac = mac_of(kaut, pkt, at);

	for (let i = 0; i < 16; i++)
		pkt[at + i] = mac[i];

	return pkt;
}

// the USIM refused the network's sequence number: hand back AUTS (10.9)
let sync_failure = (id, auts) => [ ...header(id, SUB_SYNC_FAILURE, 24), AT_AUTS, 4, ...auts ];

// the network failed to authenticate (a bad AUTN / AT_MAC) — 9.5
let reject = (id) => header(id, SUB_REJECT, 8);

// a packet we cannot process (10.20: AT_CLIENT_ERROR_CODE 0, unable to process)
let client_error = (id) => [ ...header(id, SUB_CLIENT_ERROR, 12), 22, 1, 0, 0 ];

// One relay round: the server's EAP request (bytes) → what to do.
//   { usim: <AUTHENTICATE data hex>, id, req, raw }   ask the card, then answer()
//   { reply: bytes }                                   send this back as it is
function step(pkt)
{
	let r = parse(pkt);

	if (r.error || r.code != EAP_REQUEST)
		return { reply: client_error(r.id ?? 0), error: r.error ?? 'not_a_request' };

	if (r.type != EAP_TYPE_AKA)
		return { reply: client_error(r.id), error: sprintf('eap_type_%d', r.type) };

	if (r.subtype != SUB_CHALLENGE)
		return { reply: client_error(r.id), error: sprintf('aka_subtype_%d', r.subtype) };

	let rand = r.attrs[sprintf('%d', AT_RAND)], autn = r.attrs[sprintf('%d', AT_AUTN)];

	// AT_RAND / AT_AUTN: 2 reserved bytes, then 16 (RFC 4187 10.6 / 10.7)
	rand = rand ? slice(rand, 2) : null;
	autn = autn ? slice(autn, 2) : null;

	if (length(rand ?? []) != 16 || length(autn ?? []) != 16)
		return { reply: client_error(r.id), error: 'challenge_attributes' };

	return { usim: auth_data(rand, autn), id: r.id, req: r, raw: pkt };
}

// The card answered step()'s AUTHENTICATE: the response packet, or an error
// that says why the exchange cannot go on (and the packet that tells the
// server so). { reply, error? }
// lax: answer a challenge whose AT_MAC does not verify. Off by default: RFC
// 4187 9.3 makes the peer check it first. The option exists because the
// only published end-to-end vector (AOSP service_entitlement) carries a
// server MAC that does NOT verify under 10.15 while its expected response
// does — so a test server that hand-builds challenges the same way would
// fail here and nowhere else.
function answer(st, identity, usim_hex, lax)
{
	let u = parse_usim(usim_hex);

	if (u.auts)
		return { reply: sync_failure(st.id, u.auts), resync: true };

	if (u.error)
		return { reply: reject(st.id), error: 'usim_rejected' };

	let kaut = k_aut(identity, u.ck, u.ik);

	if (!lax && !verify(st.raw, st.req, kaut))
		return { reply: client_error(st.id), error: 'server_mac' };

	return { reply: challenge_response(st.id, kaut, u.res) };
}

export { nai, parse, parse_usim, auth_data, k_aut, verify, challenge_response, step, answer, reject };
