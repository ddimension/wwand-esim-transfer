// The TS.43 session against a fake entitlement server that runs a real
// EAP-AKA exchange (it builds the challenge with a correct AT_MAC and checks
// AT_RES and the client's AT_MAC), then answers the ODSA operations the way
// each scenario asks.

'use strict';

import { eq, ok, done } from './lib/check.uc';

import * as S from 'wwand.esim_transfer.sha1';
import * as A from 'wwand.esim_transfer.aka';
import * as T from 'wwand.esim_transfer.ts43';

const IMSI = '262011234567890', IMEI = '351234567890123';
const EID = '89049032000000000000000000012345';
const RAND = S.h2b('00112233445566778899AABBCCDDEEFF');
const AUTN = S.h2b('FFEEDDCCBBAA99887766554433221100');
const RES = S.h2b('0102030405060708');
const CK = S.h2b('A0A1A2A3A4A5A6A7A8A9AAABACADAEAF');
const IK = S.h2b('B0B1B2B3B4B5B6B7B8B9BABBBCBDBEBF');
const ID = A.nai(IMSI, 2);

let bin = (b) => chr(...b);
let bytes = (s) => map(split(s ?? '', ''), (c) => ord(c));

// the challenge a network would send: AT_RAND, AT_AUTN, AT_MAC (RFC 4187 9.3)
function challenge(eap_id)
{
	let p = [ 1, eap_id, 0, 0, 23, 1, 0, 0,
	          1, 5, 0, 0, ...RAND, 2, 5, 0, 0, ...AUTN, 11, 5, 0, 0 ];
	let at = length(p);

	for (let i = 0; i < 16; i++) push(p, 0);

	p[3] = length(p);

	let kaut = A.k_aut(ID, CK, IK);
	let mac = slice(S.hmac_sha1(kaut, p), 0, 16);

	for (let i = 0; i < 16; i++) p[at + i] = mac[i];

	return p;
}

let query_of = (url) => {
	let q = {};

	for (let kv in split(split(url, '?')[1] ?? '', '&')) {
		let p = split(kv, '=');

		q[p[0]] = replace(p[1] ?? '', /%([0-9A-F]{2})/g, (m, h) => chr(hex(h)));
	}

	return q;
};

let app_xml = (parms, inner) => sprintf('<?xml version="1.0"?><wap-provisioningdoc version="1.1">' +
	'<characteristic type="APPLICATION"><parm name="AppID" value="ap2009"/>%s%s</characteristic></wap-provisioningdoc>',
	join('', map(keys(parms), (k) => sprintf('<parm name="%s" value="%s"/>', k, parms[k]))), inner ?? '');

// server(scenario) → fx.http. `answers` maps an operation to the body it
// returns (a function of the query, or a string); the EAP leg is shared.
function server(answers, log)
{
	let eap_ok = false;

	return (req, cb) => {
		push(log, req);

		let reply = (status, body, headers) => cb(null, { status: status, body: body, headers: headers ?? {} });

		if (req.method == 'POST' && req.headers['Content-Type'] == 'application/vnd.gsma.eap-relay.v1.0+json') {
			let pkt = bytes(b64dec(match(req.body, /"eap-relay-packet":"([^"]*)"/)[1]));
			let r = A.parse(pkt);

			ok(req.headers.Cookie == 'sessionid=abc', 'server: the relay POST carries the session cookie');

			// check AT_RES and the client's AT_MAC (RFC 4187 9.4)
			let res = r.attrs['3'];
			let kaut = A.k_aut(ID, CK, IK);
			let mac_ok = A.verify(pkt, { mac_at: r.mac_at }, kaut);

			eap_ok = (r.subtype == 1) && S.b2h(slice(res ?? [], 2, 10)) == S.b2h(RES) && mac_ok;

			return eap_ok
				? reply(200, '<wap-provisioningdoc><characteristic type="TOKEN"><parm name="token" value="tok1"/><parm name="validity" value="7200"/></characteristic></wap-provisioningdoc>')
				: reply(403, '');
		}

		let q = (req.method == 'POST') ? json(req.body) : query_of(req.url);

		if (q.EAP_ID) {
			eq(q.EAP_ID, ID, 'server: EAP_ID is the IMSI NAI');
			ok(index(req.headers.Accept, 'application/vnd.gsma.eap-relay.v1.0+json') == 0, 'server: relay type accepted first');

			return reply(200, sprintf('{"eap-relay-packet":"%s"}', b64enc(bin(challenge(9)))), { 'set-cookie': 'sessionid=abc; Path=/' });
		}

		let a = answers[q.operation];

		if (type(a) == 'function')
			a = a(q, req);

		return (type(a) == 'array') ? reply(a[0], a[1]) : reply(200, a ?? app_xml({ OperationResult: '0' }));
	};
}

let cfg = (extra) => ({
	server: 'https://es.example.net/ts43', post: false, app: 'ap2009', vers: '0', entitlement_version: '9.0',
	app_name: 'wwand', app_version: '0.1.0', client_ts43: 'client-Primary-ODSA', os: 'OpenWrt',
	terminal: { id: IMEI, vendor: 'WWND', model: 'RG650E', sw: 'wwand-1.10.0' },
	imsi: IMSI, mnc_len: 2, source_iccid: '89490200001234567890',
	target: { eid: EID, imei: '359999999999999' }, transfer_type: 0,
	poll_interval: 1, poll_timeout: 600, lax_mac: false, ...(extra ?? {}),
});

let clock = 1000;

let fx_of = (http) => ({
	http: http,
	aka: (data, cb) => {
		eq(data, '10' + S.b2h(RAND) + '10' + S.b2h(AUTN), 'aka: the card gets L RAND L AUTN');
		cb(null, 'DB08' + S.b2h(RES) + '10' + S.b2h(CK) + '10' + S.b2h(IK));
	},
	timer: (ms, fn) => { clock += int(ms / 1000) + 1; fn(); },
	now: () => clock,
	log: () => null,
});

let run = (answers, extra, input) => {
	let log = [], evs = [];
	let s;

	s = T.session(cfg(extra), fx_of(server(answers, log)), (ev) => {
		push(evs, ev);

		if (input?.[ev.state])
			input[ev.state](s, ev);
	});
	s.start();

	return { evs: evs, log: log, states: map(evs, (e) => e.state), last: evs[length(evs) - 1], s: s };
};

let eligible = app_xml({ OperationResult: '1', PrimaryAppEligibility: '1' });

// --- the straight case: an activation code for the target ------------------

let r = run({
	CheckEligibility: eligible,
	ManageSubscription: (q) => {
		eq(q.operation_type, '3', 'manage: a transfer (type 3)');
		eq(q.IMSI, IMSI, 'manage: IMSI + token');
		eq(q.token, 'tok1', 'manage: the token from the EAP leg');
		eq(q.target_terminal_eid, EID, 'manage: the target EID');
		eq(q.terminal_eid, EID, 'manage: terminal_eid is the target');
		eq(q.old_terminal_iccid, '89490200001234567890', 'manage: the source ICCID');
		eq(q.terminal_vendor, 'WWND', 'manage: the router as terminal');

		return app_xml({ OperationResult: '1', SubscriptionResult: '2' },
			'<characteristic type="DownloadInfo"><parm name="ProfileActivationCode" value="encodedValue=' +
			b64enc('1$smdp.example.net$MATCH-1') + '"/><parm name="ProfileIccid" value="8949020000999"/></characteristic>');
	},
});

eq(r.states, [ 'authenticating', 'eligibility', 'subscribing', 'download' ], 'flow: auth, eligibility, subscribe, download');
eq(r.last.activation_code, 'LPA:1$smdp.example.net$MATCH-1', 'flow: decoded activation code, LPA: prefixed');
eq(r.last.iccid, '8949020000999', 'flow: the new ICCID');
ok(match(r.log[0].headers['User-Agent'], /^PRD-TS43 term-WWND\/RG650E client-Primary-ODSA\/0\.1\.0 OS-OpenWrt\/wwand-1\.10\.0$/),
	'request: an honest TS.43 User-Agent');

// --- not eligible ----------------------------------------------------------

r = run({ CheckEligibility: app_xml({ OperationResult: '1', PrimaryAppEligibility: '0' }) });
eq(r.last.state, 'denied', 'eligibility: refused -> denied');
eq(r.last.reason, 'CheckEligibility', 'eligibility: names the step');

// --- delayed: polling AcquireConfiguration ---------------------------------

let polls = 0;

r = run({
	CheckEligibility: eligible,
	ManageSubscription: app_xml({ OperationResult: '1', SubscriptionResult: '4' }),
	AcquireConfiguration: () => (++polls < 3)
		? app_xml({ OperationResult: '1' }, '<characteristic type="PrimaryConfiguration"><parm name="ServiceStatus" value="2"/><parm name="PollingInterval" value="5"/><parm name="PollingIntervalUnit" value="1"/></characteristic>')
		: app_xml({ OperationResult: '1' }, '<characteristic type="PrimaryConfiguration"><parm name="ServiceStatus" value="3"/><characteristic type="DownloadInfo"><parm name="ProfileSmdpAddress" value="https://rsp.example.org/x"/><parm name="MatchingID" value="M2"/></characteristic></characteristic>'),
});

eq(polls, 3, 'delayed: polled until the download appeared');
eq(r.last.activation_code, 'LPA:1$rsp.example.org$M2', 'delayed: SM-DP+ address + matching id');

// --- a prompt, answered ----------------------------------------------------

let manages = 0;

r = run({
	CheckEligibility: eligible,
	ManageSubscription: (q) => (++manages == 1)
		? app_xml({ OperationResult: '1', SubscriptionResult: '8' }, '<characteristic type="MSG"><parm name="Message" value="Move it?"/><parm name="Accept_btn" value="1"/></characteristic>')
		: (q.MSG_btn == '1' ? app_xml({ OperationResult: '1', SubscriptionResult: '3' }) : app_xml({ OperationResult: '1', SubscriptionResult: '5' })),
}, null, { message: (s, ev) => {
	eq(ev.message, 'Move it?', 'message: the prompt reaches the caller');
	eq(s.resume('websheet'), { error: 'not_waiting', waiting: 'message' }, 'message: only the asked input continues');
	s.resume('message', { response: '', accepted: true });
} });

eq(r.states, [ 'authenticating', 'eligibility', 'subscribing', 'message', 'subscribing', 'done' ], 'message: answered, then done');

// --- a websheet, then the caller says the page finished --------------------

r = run({
	CheckEligibility: eligible,
	ManageSubscription: app_xml({ OperationResult: '1', SubscriptionResult: '1', SubscriptionServiceURL: 'https://portal.example.net/odsa' }),
	AcquireConfiguration: app_xml({ OperationResult: '1' }, '<characteristic type="DownloadInfo"><parm name="ProfileActivationCode" value="LPA:1$a.example$B"/></characteristic>'),
}, null, { websheet: (s, ev) => {
	eq(ev.url, 'https://portal.example.net/odsa', 'websheet: the URL to open');
	s.resume('websheet', 'AcquireConfiguration');
} });

eq(r.last.activation_code, 'LPA:1$a.example$B', 'websheet: then polled to the download');

// --- the source profile must go first ---------------------------------------

r = run({
	CheckEligibility: eligible,
	ManageSubscription: app_xml({ OperationResult: '1', SubscriptionResult: '6' }),
	AcquireConfiguration: app_xml({ OperationResult: '1' }, '<characteristic type="DownloadInfo"><parm name="ProfileActivationCode" value="LPA:1$c.example$D"/></characteristic>'),
}, null, { delete_source: (s, ev) => {
	eq(ev.iccid, '89490200001234567890', 'delete_source: names the source profile');
	s.resume('source_deleted');
} });

eq(r.last.activation_code, 'LPA:1$c.example$D', 'delete_source: continues after the release');

// --- temporary token transfer type -------------------------------------------

r = run({
	CheckEligibility: eligible,
	AcquireTemporaryToken: (q) => {
		eq(q.operation_targets, 'ManageSubscription,AcquireConfiguration', 'temp token: both targets');
		return app_xml({ OperationResult: '1', TemporaryToken: 'TT', TemporaryTokenExpiry: '2026-11-22T00:00:00Z' });
	},
	ManageSubscription: (q) => {
		eq(q.temporary_token, 'TT', 'temp token: later steps use it');
		eq(q.token, null, 'temp token: not the IMSI token');
		return app_xml({ OperationResult: '1', SubscriptionResult: '3' });
	},
}, { transfer_type: 2 });

eq(r.last.state, 'done', 'temp token: flow done');

// --- 511: the token expired, re-authenticated once ---------------------------

let checks = 0;

r = run({ CheckEligibility: () => (++checks == 1) ? [ 511, '' ] : eligible,
          ManageSubscription: app_xml({ OperationResult: '1', SubscriptionResult: '3' }) });

eq(checks, 2, '511: CheckEligibility repeated after a new token');
eq(r.last.state, 'done', '511: flow continues');

// --- POST variant -------------------------------------------------------------

r = run({ CheckEligibility: (q, req) => {
	ok(true, 'post: reached');
	return eligible;
} }, { post: true });

let post = filter(r.log, (q) => q.method == 'POST' && q.headers['Content-Type'] == 'application/json');

ok(length(post) >= 1, 'post: JSON bodies');
ok(length(filter(post, (q) => match(q.body, /"operation": *"CheckEligibility"/))) == 1, 'post: the operation in the body');
eq(r.last.state, 'denied', 'post: flow reached ManageSubscription (default answer: refused)');

// --- after the install on this router: type 4, then active ------------------

r = run({
	CheckEligibility: eligible,
	ManageSubscription: (q) => (q.operation_type == '4')
		? (eq(q.terminal_iccid, '8949020000999', 'installed: the new ICCID'), eq(q.app_name, null, 'installed: no app_name on type 4'),
		   app_xml({ OperationResult: '1', SubscriptionResult: '3' }))
		: app_xml({ OperationResult: '1', SubscriptionResult: '2' }, '<characteristic type="DownloadInfo"><parm name="ProfileActivationCode" value="LPA:1$e.example$F"/></characteristic>'),
	AcquireConfiguration: app_xml({ OperationResult: '1' }, '<characteristic type="PrimaryConfiguration"><parm name="ServiceStatus" value="1"/></characteristic>'),
}, null, { download: (s) => s.installed('8949020000999') });

eq(r.states, [ 'authenticating', 'eligibility', 'subscribing', 'download', 'activating', 'polling', 'done' ],
	'installed: reported and confirmed active');

// --- parsing -------------------------------------------------------------------

let pj = T.parse_body('{"Token":{"token":"J1","Validity":"60"},"ap2009":{"OperationResult":1,"SubscriptionResult":2,"DownloadInfo":{"ProfileActivationCode":"1$x.example$Y"}}}');

eq(pj.token, 'J1', 'json: token');
eq(pj.validity, 60, 'json: validity');
eq(T.download_of(pj).activation_code, 'LPA:1$x.example$Y', 'json: download');
eq(T.parse_body('<wap-provisioningdoc><characteristic type="APPLICATION"><parm name="OperationResult" value="1"/><parm name="GeneralErrorText" value="a &amp; b"/></characteristic></wap-provisioningdoc>').app.GeneralErrorText,
	'a & b', 'xml: entities, single APPLICATION without AppID');
eq(T.parse_body('not a body'), null, 'parse: neither form -> null');
eq(T.download_of({ download: { ProfileActivationCode: 'QUJD' } }).activation_code, 'LPA:QUJD',
	'download: plain value is not base64-decoded');

// --- the trace: readable, and nothing that identifies the subscriber ---------

eq(T.mask('EAP_ID 0262011234567890@nai.epc.mnc001.mcc262.3gppnetwork.org'),
	'EAP_ID 02620…90@nai.epc.mnc001.mcc262.3gppnetwork.org', 'mask: the IMSI in the NAI');
eq(T.mask('token=abcdefghij&IMSI=262011234567890'), 'token=abcd…&IMSI=26201…90', 'mask: query token and IMSI');
eq(T.mask('{"token":"abcdefgh","TemporaryToken":"TT123456"}'), '{"token":"abcd…","TemporaryToken":"TT12…"}', 'mask: JSON tokens');
eq(T.mask('<parm name="token" value="secret-token-1"/>'), '<parm name="token" value="secr…"/>', 'mask: XML token');

let traced = [];
let tr_fx = fx_of(server({
	CheckEligibility: eligible,
	ManageSubscription: app_xml({ OperationResult: '1', SubscriptionResult: '3' }),
}, []));

tr_fx.log = (lvl, msg) => push(traced, msg);
T.session(cfg(), tr_fx, () => null).start();

let tr = join('\n', traced);

ok(index(tr, 'ts43: → GET authenticate (EAP_ID 02620…90@') >= 0, 'trace: the auth request, IMSI masked');
ok(index(tr, 'ts43: EAP round 1: AKA-Challenge') >= 0, 'trace: the EAP round and its subtype');
ok(index(tr, 'ts43: USIM: RES/CK/IK → AT_RES + AT_MAC sent') >= 0, 'trace: what the card answered and what went back');
ok(index(tr, 'ts43: authentication answer: HTTP 200, token (valid 7200 s)') >= 0, 'trace: the token, without its value');
ok(index(tr, 'ts43: CheckEligibility: OperationResult=1 PrimaryAppEligibility=1') >= 0, 'trace: the server\'s verdict per step');
ok(index(tr, 'ts43: ManageSubscription: OperationResult=1 SubscriptionResult=3') >= 0, 'trace: the subscription result');
ok(!match(tr, /262011234567890|tok1/), 'trace: neither the IMSI nor the token appears in full');

// a refusal's answer goes into the trace (Vodafone answers PrimaryAppEligibility
// 0 with no text; whatever else it sends is the only clue)
traced = [];
tr_fx = fx_of(server({ CheckEligibility: app_xml({ OperationResult: '1', PrimaryAppEligibility: '0', VendorHint: 'device-not-supported' }) }, []));
tr_fx.log = (lvl, msg) => push(traced, msg);
T.session(cfg(), tr_fx, () => null).start();
ok(length(filter(traced, (l) => index(l, 'CheckEligibility refused, the answer:') >= 0 && index(l, 'device-not-supported') >= 0)) == 1,
	'trace: the refused answer\'s body, so an operator\'s own field is seen');

// --- the entitlement record --------------------------------------------------

let recs = [
	{ mccmnc: '26201', entitlementServer: 'https://a.example/' },
	{ mccmnc: '26201', gid1: 'BA', entitlementServer: 'https://b.example/' },
	{ mccmnc: '26202', entitlementServer: 'https://c.example/' },
];

eq(T.pick_record(recs, { mccmnc: '26201', imsi: IMSI }).record.entitlementServer, 'https://a.example/', 'record: mccmnc');
eq(T.pick_record(recs, { mccmnc: '26201', imsi: IMSI, gid1: 'ba01' }).record.entitlementServer, 'https://b.example/', 'record: gid1 wins');
eq(T.pick_record(recs, { mccmnc: '23410' }).reason, 'not_found', 'record: none');
eq(T.pick_record([ recs[0], { mccmnc: '26201', entitlementServer: 'https://d.example/' } ], { mccmnc: '26201' }).reason,
	'ambiguous', 'record: two servers tie');

done('test_ts43');
