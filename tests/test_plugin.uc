// The plugin: its entry points load the way wwand loads them (require() of
// the shims), and the engine's release / delivery / TS.43 start against a
// fake modem_esim.

'use strict';

import { eq, ok, done } from './lib/check.uc';
import * as P from 'wwand.esim_transfer.plugin';
import * as C from 'wwand.esim_transfer.ctl';

// --- the shims, as plugins.uc and wwandctl reach them ------------------------

let shim = require('wwand.plugins.esim_transfer');

eq(shim?.name, 'esim_transfer', 'shim: plugins.uc gets the plugin object');
eq(type(shim?.create), 'function', 'shim: with create()');
ok('esim_transfer_server' in shim.options, 'shim: options listed');

let cmd = require('wwand.ctl.transfer');

eq(type(cmd?.run), 'function', 'shim: wwandctl gets run()');
ok(length(cmd.help) > 5, 'shim: and its help lines');

// --- a fake card behind modem_esim -------------------------------------------

const ICCID = '89490200001234567890';
let card, calls, files, timers, clock, token;

let reset = (notif_ack) => {
	card = {
		profiles: [ { iccid: ICCID, state: 'enabled', provider: 'Telekom' }, { iccid: '89490200009999999999', state: 'disabled' } ],
		notifications: [],
		seq: 10,
	};
	calls = [];
	files = {};
	timers = [];
	clock = 1000;
	token = 'tok-1';
	card.ack = notif_ack ?? true;
};

let esim = (ref, op, params, cb) => {
	push(calls, op + (params?.iccid ? ':' + params.iccid : '') + (params?.seq != null ? ':' + params.seq : ''));

	switch (op) {
	case 'profiles': return cb(null, { profiles: card.profiles });
	case 'disable':
		for (let p in card.profiles) if (p.iccid == params.iccid) p.state = 'disabled';
		return cb(null, {});
	case 'delete':
		card.profiles = filter(card.profiles, (p) => p.iccid != params.iccid);
		push(card.notifications, { seqNumber: card.seq++, profileManagementOperation: 'delete', iccid: params.iccid,
		                           notificationAddress: 'smdp.example' });
		return cb(null, {});
	case 'notifications':
		return cb(null, { ok: true, log: 'result: code=0 success\ndata: ' + sprintf('%J', card.notifications) });
	case 'notify':
		card.notified = params.seq;
		return cb(null, { started: true });
	case 'download_status':
		if (card.ack)
			card.notifications = filter(card.notifications, (n) => n.seqNumber != card.notified);
		return cb(null, { state: card.ack ? 'done' : 'failed', log: card.ack ? '' : 'result: code=-1 es9p_handle_notification' });
	case 'discovery':
		return cb(null, { servers: [ 'rsp.example.org' ] });
	case 'download':
		return cb(null, { started: true });
	}

	cb({ error: 'invalid_op' });
};

let eng_of = (extra) => P.engine({
	esim: (...a) => esim(...a),   // late-bound: a test may swap the fake
	card: extra?.card ?? ((ref, args, cb) => cb({ error: 'no card in this test' })),
	modem: () => ({ imsi: '262011234567890', iccid: ICCID, imei: '351234567890123', model: 'RG650E', eid: '89049032000000000000000000012345' }),
	online: () => token,
	http: extra?.http ?? ((req, cb) => cb({ error: 'offline' })),
	timer: (ms, fn) => push(timers, fn),
	now: () => clock,
	log: () => null,
	read: (p) => files[p],
	write: (p, t) => { files[p] = t; },
	state_dir: '/st',
});

let flush = () => { while (length(timers)) shift(timers)(); };

// --- release: disable, delete, notification delivered ------------------------

reset();
let eng = eng_of();
let res = null;

eng.release('m0', ICCID, false, (e, r) => res = [ e, r ]);
flush();

eq(res, [ null, { released: ICCID, state: 'delivering' } ], 'release: answered when deleted');
eq(calls, [ 'profiles', 'disable:' + ICCID, 'delete:' + ICCID, 'notifications', 'notify:10', 'download_status' ],
	'release: disable before delete, then the ONE delete notification by seq');
eq(eng.status('m0').releases[0].state, 'delivered', 'release: delivered once the card no longer lists it');
ok(match(files['/st/releases.json'] ?? '', /"delivered"/), 'release: kept in the state file');

// a second engine (daemon restart) reads it back
eq(eng_of().status('m0').releases[0].iccid, ICCID, 'state: survives a restart');

// --- not delivered: retried on a new data session, and on the timer ---------

reset(false);
eng = eng_of();
eng.release('m0', ICCID, false, () => null);
flush();

let r0 = eng.status('m0').releases[0];

eq(r0.state, 'delivering', 'refused ack: still delivering');
eq(r0.error, 'result: code=-1 es9p_handle_notification', 'refused ack: lpac\'s own verdict as the reason');
eq(map(r0.steps, (x) => [ x.step, x.ok ]), [ [ 'disable', true ], [ 'delete', true ], [ 'notify', false ] ],
	'refused ack: the steps as the page shows them');
ok(length(filter(eng.log('m0'), (l) => index(l.msg, 'NOT delivered') >= 0)) == 1, 'refused ack: in the trace');
eq(r0.tries, 1, 'refused ack: one try');

calls = [];
eng.tick('m0');
flush();
eq(length(filter(calls, (c) => c == 'notifications')), 1, 'tick: the first tick sees a fresh session token and retries');

calls = [];
eng.tick('m0');
flush();
eq(calls, [], 'tick: same session, before the retry interval: nothing');

clock += 301;
eng.tick('m0');
flush();
eq(length(filter(calls, (c) => c == 'notifications')), 1, 'tick: retried after the interval');

card.ack = true;
token = 'tok-2';
eng.tick('m0');
flush();
eq(eng.status('m0').releases[0].state, 'delivered', 'tick: a new session delivers it');

// --- an unreadable list is not an empty one ------------------------------------

// lpac's ES10 call failed (code=-1, exit 0): no data line. The release must
// stay `delivering`, not flip to delivered because nothing is "listed".
reset();
eng = eng_of();
let list_fails = true;
let real_esim = esim;

esim = (ref, op, params, cb) => (op == 'notifications' && list_fails)
	? cb(null, { ok: true, log: 'result: code=-1 es10b_list_notification' })
	: real_esim(ref, op, params, cb);
eng = eng_of();
eng.release('m0', ICCID, false, () => null);
flush();
eq(eng.status('m0').releases[0].state, 'delivering', 'list unreadable (code=-1): not marked delivered');

// the same for a wwand whose log never carries the array (before data_json)
esim = (ref, op, params, cb) => (op == 'notifications')
	? cb(null, { ok: true, log: 'result: code=0 success' }) : real_esim(ref, op, params, cb);
eng.deliver('m0');
flush();
eq(eng.status('m0').releases[0].state, 'delivering', 'no data line (old wwand): not marked delivered');
esim = real_esim;

eq(P.notifications_of('result: code=0 success\ndata: []'), [], 'list: empty is empty');
eq(P.notifications_of('result: code=0 success\ndata: [{"seqNumber":1}]'), [ { seqNumber: 1 } ], 'list: entries');
eq(P.notifications_of('result: code=0 success'), null, 'list: no data line -> null');
eq(P.notifications_of('result: code=-1 x\ndata: []'), null, 'list: failed run -> null');

// a failing list counts as a try: the next tick on the same session waits
reset();
eng = eng_of();
eng.release('m0', ICCID, false, () => null);   // delivered at once (ack true)
card.ack = false;
reset(false);
esim = (ref, op, params, cb) => (op == 'notifications')
	? (push(calls, op), cb(null, { ok: true, log: 'result: code=-1 es10b_list_notification' }))
	: real_esim(ref, op, params, cb);
eng = eng_of();
eng.release('m0', ICCID, false, () => null);
flush();
eq(eng.status('m0').releases[0].state, 'delivering', 'failing list: still delivering');
calls = [];
eng.tick('m0');   // the first tick on this session token: a retry
flush();
eq(length(calls), 1, 'failing list: the first tick tries');
calls = [];
eng.tick('m0');
eng.tick('m0');
flush();
eq(calls, [], 'failing list: not retried on every tick');
clock += 301;
eng.tick('m0');
flush();
eq(length(calls), 1, 'failing list: retried after the interval');
esim = real_esim;

// --- a refused delete stays visible -------------------------------------------------

reset();
real_esim = esim;
esim = (ref, op, params, cb) => (op == 'disable')
	? cb({ error: 'sim_in_use', detail: 'interface wan is bound to the card in use' }) : real_esim(ref, op, params, cb);
eng = eng_of();
eng.release('m0', ICCID, false, (e) => res = e);
esim = real_esim;
eq(res.error, 'sim_in_use', 'refused: the caller gets the reason');
eq(eng.status('m0').releases[0].state, 'failed', 'refused: the record says failed');
eq(eng.status('m0').releases[0].error, 'interface wan is bound to the card in use', 'refused: and why');
eng.release('m0', ICCID, true, () => null);
flush();
eq(length(eng.status('m0').releases), 1, 'refused: a new attempt replaces the failed record');
eq(eng.status('m0').releases[0].state, 'delivered', 'refused: forced, then delivered');

// --- F-padded ICCIDs on one side --------------------------------------------------

reset();
card.profiles[0].iccid = ICCID + 'F';
eng = eng_of();
eng.release('m0', ICCID, false, (e, r) => res = e);
flush();
eq(res, null, 'iccid: a padded profile ICCID is found by the plain one');
eq(eng.status('m0').releases[0]?.state, 'delivered', 'iccid: and its notification matched');

// --- release refusals ----------------------------------------------------------

reset();
eng = eng_of();
eng.release('m0', '123', false, (e) => res = e);
eq(res.error, 'invalid_argument', 'release: malformed ICCID');
eng.release('m0', '89490200001111111111', false, (e) => res = e);
eq(res.error, 'not_found', 'release: unknown profile');

// --- import / discovery -------------------------------------------------------

eng.import('m0', 'LPA:1$smdp.example$X', null, (e) => res = e);
eq(res, null, 'import: a code goes to the download');
eng.import('m0', 'https://example', null, (e) => res = e);
eq(res.error, 'invalid_argument', 'import: not an activation code');
eng.discovery('m0', {}, (e, r) => res = r);
eq(res.servers, [ 'rsp.example.org' ], 'discovery: servers');
eq(eng.status('m0').discovery.servers, [ 'rsp.example.org' ], 'discovery: kept for the status');

// --- TS.43 start: what has to be known before anything is sent ---------------

reset();
eng = eng_of({ card: (ref, args, cb) => cb(null, { mnc_len: '2', group_id: '' }) });
eng.ts43_start('m0', P.cfg_of({}), { target: 'external', target_eid: '123', target_imei: '1' }, (e) => res = e);
eq(res.detail, 'target_eid', 'ts43: target EID checked');
eng.ts43_start('m0', P.cfg_of({}), { target: 'router' }, (e) => res = e);
eq(res.error, 'no_entitlement_server', 'ts43: no server configured, no entitlement.json');

let reqs = [];
eng = eng_of({ card: (ref, args, cb) => cb(null, { mnc_len: '2', group_id: '' }),
               http: (req, cb) => { push(reqs, req); cb(null, { status: 403, headers: {}, body: '' }); } });
eng.ts43_start('m0', P.cfg_of({ esim_transfer_server: 'https://es.example/ts43' }), { target: 'router' }, (e, r) => res = [ e, r ]);
eq(res[0], null, 'ts43: started with the configured server');
ok(match(reqs[0]?.url ?? '', /EAP_ID=0262011234567890%40nai\.epc\.mnc001\.mcc262\.3gppnetwork\.org/),
	'ts43: the identity from IMSI + EF_AD MNC length');
ok(match(reqs[0]?.url ?? '', /terminal_vendor=OWRT/), 'ts43: the router, honestly');
eq(eng.status('m0').ts43.state, 'error', 'ts43: a refused auth ends in error');

// --- usim_check: the read-only probe ------------------------------------------

let seen = [];

eng = eng_of({ card: (ref, args, cb) => {
	push(seen, join(' ', args));
	(args[0] == 'identity') ? cb(null, { mnc_len: '2', group_id: 'BA' }) : cb({ error: 'lpac', code: 1 }, { response: '', sw: '9862' });
} });
eng.usim_check('m0', (e, r) => res = r);
eq(seen[1], 'aka 00000000000000000000000000000000 00000000000000000000000000000000', 'check: a zero AUTN, so the MAC must fail');
eq(res.verdict, 'ok: the USIM answers AUTHENTICATE over this modem', 'check: 9862 is the good answer');
eq([ res.mnc_len, res.gid1 ], [ '2', 'BA' ], 'check: EF_AD and GID1');

eng = eng_of({ card: (ref, args, cb) => cb({ error: 'lpac', code: 1 }, { error: 'usim_channel' }) });
eng.usim_check('m0', (e, r) => res = r);
eq(res.usim_channel, false, 'check: no channel to the USIM is said so');

// --- the pre-flight check: is a transfer possible? -------------------------------

let item_ids = (k) => map(k.items, (i) => [ i.id, i.ok ]);

reset();
eng = eng_of({ card: (ref, args, cb) => cb(null, { mnc_len: '2', group_id: '01' }) });
eng.check('m0', P.cfg_of({}), (e, r) => res = r);
let k = eng.status('m0').check;
eq(res, { started: true }, 'check: answers at once');
eq(item_ids(k), [ [ 'sim', true ], [ 'euicc', true ], [ 'usim', true ], [ 'server', false ] ], 'check: no server known');
eq(k.verdict, 'no entitlement server known for this operator', 'check: says what is missing');
eq(k.running, false, 'check: finished');

// a server that refuses the router's login
let check_reqs = [];
eng = eng_of({ card: (ref, args, cb) => cb(null, { mnc_len: '2', group_id: '01' }),
               http: (req, cb) => { push(check_reqs, req); cb(null, { status: 403, headers: {}, body: 'Forbidden' }); } });
eng.check('m0', P.cfg_of({ esim_transfer_server: 'https://es.example/ts43' }), () => null);
k = eng.status('m0').check;
eq(item_ids(k), [ [ 'sim', true ], [ 'euicc', true ], [ 'usim', true ], [ 'server', true ], [ 'login', false ] ],
	'check: server known, login refused');
eq(k.verdict, 'the server refused the login (it may not accept a router)', 'check: the likely reason');
ok(length(filter(eng.log('m0'), (l) => l.area == 'ts43' && index(l.msg, 'HTTP 403') >= 0)), 'check: the HTTP status in the trace');

// a server that would transfer it — the check stops BEFORE ManageSubscription
let ops_seen = [];
let fake_es = (req, cb) => {
	let q = {};
	for (let kv in split(split(req.url, '?')[1] ?? '', '&')) { let x = split(kv, '='); q[x[0]] = x[1]; }
	if (q.operation) push(ops_seen, q.operation);
	if (q.EAP_ID)   // skip the AKA leg: hand out the token directly
		return cb(null, { status: 200, headers: {}, body: '<wap-provisioningdoc><characteristic type="TOKEN"><parm name="token" value="T1"/></characteristic></wap-provisioningdoc>' });
	cb(null, { status: 200, headers: {}, body: '<wap-provisioningdoc><characteristic type="APPLICATION"><parm name="OperationResult" value="1"/><parm name="PrimaryAppEligibility" value="1"/></characteristic></wap-provisioningdoc>' });
};
eng = eng_of({ card: (ref, args, cb) => cb(null, { mnc_len: '2', group_id: '01' }), http: fake_es });
eng.check('m0', P.cfg_of({ esim_transfer_server: 'https://es.example/ts43' }), () => null);
k = eng.status('m0').check;
eq(k.verdict, 'possible', 'check: eligible -> possible');
eq(item_ids(k)[5], [ 'eligible', true ], 'check: the eligibility item');
eq(ops_seen, [ 'CheckEligibility' ], 'check: nothing after CheckEligibility is sent');

// --- the CLI formatter --------------------------------------------------------

let lines = C.status_lines({ releases: [ { iccid: ICCID, provider: 'Telekom', state: 'delivering', tries: 2 } ],
	hint: { operator: 'Telekom Deutschland', code: 'MeinMagenta', reusable: false, reusable_source: 'x' } }, 2000);

eq(lines[0], [ 'releasing', ICCID + ' (Telekom) — notification NOT delivered yet (2 tries)' ], 'ctl: what is not through first');
eq(lines[1][0], 'operator', 'ctl: the operator hint');
eq(C.status_lines({}, 0), [ [ 'transfer', 'nothing released, nothing running' ] ], 'ctl: empty');

done('test_plugin');
