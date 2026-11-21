// EAP-AKA and its SHA-1 / PRF underneath: standard vectors, and one
// AKA-Challenge exchange end to end.

'use strict';

import { eq, ok, done } from './lib/check.uc';

import * as S from 'wwand.esim_transfer.sha1';
import * as A from 'wwand.esim_transfer.aka';

let bytes = (s) => map(split(s, ''), (c) => ord(c));

// FIPS 180-4 / RFC 3174 test vectors
eq(S.b2h(S.sha1(bytes('abc'))), 'A9993E364706816ABA3E25717850C26C9CD0D89D', 'sha1: abc');
eq(S.b2h(S.sha1([])), 'DA39A3EE5E6B4B0D3255BFEF95601890AFD80709', 'sha1: empty');
eq(S.b2h(S.sha1(bytes('abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq'))),
	'84983E441C3BD26EBAAE4AA1F95129E5E54670F1', 'sha1: two blocks');

// RFC 2202 HMAC-SHA1 test case 2
eq(S.b2h(S.hmac_sha1(bytes('Jefe'), bytes('what do ya want for nothing?'))),
	'EFFCDF6AE5EB2FA2D27416D5F184DF9C259A7C79', 'hmac-sha1: RFC 2202 case 2');

// FIPS 186-2 change notice 1, appendix 3.3 example (XKEY bd029bbe..., XSEED
// 0): the first two outputs
eq(S.b2h(S.fips186_prf(S.h2b('bd029bbe7f51960bcf9edb2b61f06f0feb5a38b6'), 40)),
	'2070B3223DBA372FDE1C0FFC7B2E3B498B2606143C6C18BACB0F6C55BABB13788E20D737A3275116',
	'prf: FIPS 186-2 appendix 3.3 vector');

// identity (3GPP TS 23.003 19.3.2)
eq(A.nai('234101234567890', 2), '0234101234567890@nai.epc.mnc010.mcc234.3gppnetwork.org', 'nai: 2-digit MNC padded');
eq(A.nai('310260123456789', 3), '0310260123456789@nai.epc.mnc260.mcc310.3gppnetwork.org', 'nai: 3-digit MNC');
eq(A.nai('31026x', 3), null, 'nai: bad IMSI');
eq(A.nai('310260123456789', 4), null, 'nai: bad MNC length');

// A full AKA-Challenge with the USIM's answer, from AOSP's EAP-AKA test
// (frameworks/libs/service_entitlement, Apache-2.0; the same vector is in
// damonto/ts43-go aka_test.go, 2026-11-19)
let chal = b64dec('AQIAfBcBAAABBQAAXOZSkCjxysgE43GWqHJvgQIFAABrikWGrekAALNU4TxmCDPoCwUAAJT0nqXeAYlqzT0UGXINENWBBQAA7z3fhImkg+vcCKWIZBdvuYIJAAAPRUFp7KWFo+Thr78Qj9hEkB2zA0i6KakODsufBC+BJQ==');
let usim = b64dec('2wjHnwKln8mjjxDzMKJvLBzMHtm0X9SNBsUWEAbEiAdD7xeqqZ7nsXzukRkIhd6SDZ4bj7s=');
let id = '0234107813240779@nai.epc.mnc010.mcc234.3gppnetwork.org';

let st = A.step(bytes(chal));

ok(st.usim, 'step: a challenge asks the card');
eq(substr(st.usim, 0, 2), '10', 'step: AUTHENTICATE data starts with L(RAND)');
eq(length(st.usim), 68, 'step: L RAND L AUTN = 34 bytes');

// The vector's own AT_MAC is synthetic: it does not verify under RFC 4187
// 10.15, although the response it expects is computed exactly that way. So
// strict mode refuses it, and lax mode must produce the expected bytes.
eq(A.answer(st, id, S.b2h(bytes(usim))).error, 'server_mac', 'answer: the vector\'s synthetic server MAC is refused');

let ans = A.answer(st, id, S.b2h(bytes(usim)), true);

eq(ans.error, null, 'answer (lax): no error');
eq(S.b2h(ans.reply), '020200281701000003030040C79F02A59FC9A38F0B0500001C141BDDDE8BEF2E502FB6793808DE7C',
	'answer: the response packet of the vector');

// a challenge whose AT_MAC was computed with the right K_aut verifies
let usim_d = A.parse_usim(S.b2h(bytes(usim)));
let kaut = A.k_aut(id, usim_d.ck, usim_d.ik);
let good = bytes(chal);
for (let i = 0; i < 16; i++) good[st.req.mac_at + i] = 0;
let gp = A.parse(good);
let gm = slice(S.hmac_sha1(kaut, good), 0, 16);
for (let i = 0; i < 16; i++) good[gp.mac_at + i] = gm[i];
let st3 = A.step(good);
eq(A.answer(st3, id, S.b2h(bytes(usim))).error, null, 'answer: a correctly MACed challenge verifies');

// a tampered challenge (one RAND bit) fails the server MAC
let bad = bytes(chal);
bad[12] ^= 1;
let st2 = A.step(bad);   // the vector's challenge, tampered: refused either way
let ans2 = A.answer(st2, id, S.b2h(bytes(usim)));
eq(ans2.error, 'server_mac', 'answer: tampered challenge -> server_mac, no AT_RES');
eq(ans2.reply[5], 14, 'answer: a client error goes back instead');

// synchronisation failure: DC + AUTS
let sf = A.answer(st, id, 'DC0E0102030405060708090A0B0C0D0E');
eq(sf.resync, true, 'answer: AUTS -> resync');
eq(S.b2h(sf.reply), '0202001817040000040401020304050607080' + '90A0B0C0D0E', 'answer: sync failure packet');

// the card refused (no DB/DC): Authentication-Reject
let rj = A.answer(st, id, '9862');
eq(rj.error, 'usim_rejected', 'answer: refused AUTN -> usim_rejected');
eq(S.b2h(rj.reply), '0202000817020000', 'answer: reject packet');

// not a challenge
eq(A.step([ 1, 7, 0, 8, 23, 5, 0, 0 ]).error, 'aka_subtype_5', 'step: AKA-Identity is not answered');
eq(A.step([ 1, 7, 0, 6, 50, 1 ]).error, 'eap_type_50', 'step: EAP-AKA\' is refused');
eq(A.step([ 1, 7, 0, 9, 23 ]).error, 'length', 'step: bad length');

done('test_aka');
