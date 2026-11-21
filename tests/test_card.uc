// esim-transfer-card against a scripted host (the answers lpac's stdio
// protocol would get from esim_bridge, fed in order), and the profile-list
// parser behind its `profiles` command.

'use strict';

import * as fs from 'fs';
import { eq, ok, done } from './lib/check.uc';

import * as M from 'wwand.esim_transfer.meta';
import * as S from 'wwand.esim_transfer.sha1';

let card = getenv('ESIM_TRANSFER_CARD');
let ucode = getenv('ESIM_TRANSFER_UCODE');

// run the helper with these host answers; its stdout as lines of JSON text
function run(args, answers)
{
	let dir = '/tmp/esim-transfer-test.' + getenv('USER');

	fs.mkdir(dir);

	let inf = dir + '/in';

	fs.writefile(inf, join('\n', map(answers, (a) => (type(a) == 'string') ? a :
		sprintf('{"type":"apdu","payload":{"ecode":%d,"data":"%s"}}', a[0], a[1] ?? ''))) + '\n');

	let p = fs.popen(sprintf("%s %s %s < %s; echo \"__EXIT:$?\"", ucode, card, args, inf));
	let out = p.read('all');

	p.close();
	fs.unlink(inf);
	fs.rmdir(dir);

	let lines = filter(split(trim(out), '\n'), (l) => length(l));
	let ec = +(match(lines[length(lines) - 1] ?? '', /__EXIT:([0-9]+)/)?.[1] ?? -1);

	return { lines: slice(lines, 0, length(lines) - 1), ec: ec };
}

let field = (l, re) => match(l, re)?.[1];
let funcs = (r) => map(r.lines, (l) => field(l, /"func": *"([a-z_]+)"/) ?? field(l, /"event": *"([a-z_]+)"/));
let result = (r) => filter(r.lines, (l) => index(l, 'card_result') >= 0)[0];
let params = (r) => map(filter(r.lines, (l) => index(l, '"transmit"') >= 0), (l) => field(l, /"param": *"([0-9A-F]*)"/));

const RAND = '00112233445566778899AABBCCDDEEFF', AUTN = 'FFEEDDCCBBAA99887766554433221100';
const DB = 'DB0801020304050607081000000000000000000000000000000000100000000000000000000000000000000000';

// --- aka: logical channel 2, a T=0 61xx follow-up -----------------------------

let r = run('aka ' + RAND + ' ' + AUTN, [
	[ 0 ],                     // connect
	[ 2 ],                     // logic_channel_open -> channel 2
	[ 0, '6131' ],             // AUTHENTICATE -> 61 31
	[ 0, DB + '9000' ],        // GET RESPONSE
	[ 0 ],                     // logic_channel_close
	'{"type":"event","payload":{}}',
	[ 0 ],                     // disconnect
]);

eq(funcs(r), [ 'connect', 'logic_channel_open', 'transmit', 'transmit', 'logic_channel_close', 'card_result', 'disconnect' ],
	'aka: the protocol sequence');
eq(field(r.lines[1], /"param": *"([0-9A-F]*)"/), 'A0000000871002', 'aka: opens the USIM by its partial AID');
eq(params(r), [ '0288008122' + '10' + RAND + '10' + AUTN + '00', '02C0000031' ],
	'aka: AUTHENTICATE on channel 2, then GET RESPONSE with the channel in the CLA');
eq(field(r.lines[5], /"response": *"([0-9A-F]*)"/), DB, 'aka: the DB answer reaches the host');
eq(r.ec, 0, 'aka: exit 0');

// the network failed the MAC check on the card: 9862
r = run('aka ' + RAND + ' ' + AUTN, [ [ 0 ], [ 1 ], [ 0, '9862' ], [ 0 ], '{"type":"event","payload":{}}', [ 0 ] ]);

eq(field(r.lines[4], /"sw": *"([0-9A-F]*)"/), '9862', 'aka: 9862 is reported');
eq(r.ec, 1, 'aka: refused -> exit 1');

// no USIM channel
r = run('aka ' + RAND + ' ' + AUTN, [ [ 0 ], [ -1 ], '{"type":"event","payload":{}}', [ 0 ] ]);

eq(field(r.lines[2], /"error": *"([a-z_]+)"/), 'usim_channel', 'aka: no channel -> usim_channel');

r = run('aka 00 11', [ [ 0 ], '{"type":"event","payload":{}}', [ 0 ] ]);

eq(field(r.lines[1], /"error": *"([a-z_]+)"/), 'arguments', 'aka: malformed RAND refused before any APDU');

// --- identity: EF_AD and EF_GID1, with a 6Cxx Le correction --------------------

r = run('identity', [
	[ 0 ], [ 1 ],
	[ 0, '6120' ], [ 0, '62' + '1E' + '00' + '9000' ],   // SELECT 6FAD -> 61 20, FCP
	[ 0, '6C04' ], [ 0, '00000002' + '9000' ],            // READ BINARY -> 6C 04, AD: MNC length 2
	[ 0, '9000' ],                                         // SELECT 6F3E
	[ 0, 'BA01FFFF9000' ],                                 // GID1
	[ 0 ], '{"type":"event","payload":{}}', [ 0 ],
]);

eq(params(r), [ '01A40004026FAD00', '01C0000020', '01B0000000', '01B0000004', '01A40004026F3E00', '01B0000000' ],
	'identity: SELECT by FID under the USIM, GET RESPONSE, Le corrected by 6Cxx');
eq(field(result(r), /"mnc_len": *"([0-9]*)"/), '2', 'identity: MNC length from EF_AD');
eq(field(result(r), /"group_id": *"([0-9A-F]*)"/), 'BA01', 'identity: GID1, F padding stripped');
eq(r.ec, 0, 'identity: exit 0');

// --- profiles ------------------------------------------------------------------

// two profiles: an enabled v2 one, and one with usingStoredAc + deleteOldProfile
let tlv = (tag, hexval) => sprintf('%s%02X%s', tag, length(hexval) / 2, hexval);
let str = (s) => join('', map(split(s, ''), (c) => sprintf('%02X', ord(c))));
let p1 = tlv('E3', tlv('5A', '98940200001032547698') + tlv('9F70', '01') + tlv('91', str('Telekom')));
let p2 = tlv('E3', tlv('5A', '98940200001132547698') + tlv('9F70', '00') + tlv('91', str('Example')) +
	tlv('BF20', tlv('A1', tlv('0C', str('LPA:1$dc.example$DC1')) + '0500')));
let p3 = tlv('E3', tlv('5A', '98940200001232547698') + tlv('9F70', '00') +
	tlv('BF20', tlv('A0', tlv('0C', str('dp.example')) + '0500')));
let resp = tlv('BF2D', tlv('A0', p1 + p2 + p3));

r = run('profiles', [ [ 0 ], [ 1 ], [ 0, resp + '9000' ], [ 0 ], '{"type":"event","payload":{}}', [ 0 ] ]);

eq(field(r.lines[1], /"param": *"([0-9A-F]*)"/), 'A0000005591010FFFFFFFF8900000100', 'profiles: opens the ISD-R');
// 8 tag bytes: 5A, 9F70, 91, 92, 90, BF20
eq(params(r), [ '81E291000DBF2D0A5C085A9F70919290BF20' ],
	'profiles: STORE DATA GetProfilesInfo with the v3 tag list, channel 1');

let got = M.parse_profiles(field(r.lines[4], /"response": *"([0-9A-F]*)"/));

eq(length(got.profiles), 3, 'parse: three profiles');
eq(got.profiles[0], { iccid: '89492000000123456789', enabled: true, provider: 'Telekom', name: null, nickname: null, dc: null },
	'parse: an enabled v2 profile, no Device Change');
eq(got.profiles[1].dc, { method: 'stored_ac', activation_code: 'LPA:1$dc.example$DC1', delete_old_profile: true },
	'parse: usingStoredAc with deleteOldProfile');
eq(got.profiles[2].dc, { method: 'request_to_dp', smdp: 'dp.example', eid_required: true, tac_required: false },
	'parse: requestToDp, EID required');

eq(M.parse_profiles(tlv('BF2D', tlv('81', '01'))).error, 'profile_info_error', 'parse: the card\'s error answer');
eq(M.parse_profiles('BF2D05').error, 'response', 'parse: truncated -> response');

done('test_card');
