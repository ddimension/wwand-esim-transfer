// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// A GSMA TS.43 (Service Entitlement Configuration) ODSA client for one
// eSIM subscription transfer: the router's own SIM proves the subscription
// with EAP-AKA, the operator's entitlement server answers with an activation
// code for the target eUICC.
//
// The wire facts (operation names, parameters, response characteristics,
// the EAP relay) follow GSMA TS.43 v13.0 (2026-02) as the open clients use it:
// AOSP frameworks/libs/service_entitlement (Apache-2.0) and damonto/ts43-go
// (GPL-3.0, read at 3bb3910, 2026-11-19 — facts only, no code). Every
// operator runs its own server and its own subset; what one of them accepts
// is only known by trying it, which is why every decision point below is
// reported to the caller as it happens.
//
// The router presents itself as what it is (terminal_vendor / model /
// sw_version from the config, an OpenWrt User-Agent). Servers that admit
// only phones refuse that; the caller can configure other values, at the
// user's own risk — nothing here pretends to be a phone by default.
//
// An ES module, precompiled to bytecode; exports { session, parse_body, … }.

'use strict';

import * as S from 'wwand.esim_transfer.sha1';
import * as A from 'wwand.esim_transfer.aka';

const APP_ODSA = 'ap2009';

// TS.43 values (v13.0 6.5.x tables)
const OP_RESULT_SUCCESS = '1';
const SUB = { WEBSHEET: '1', DOWNLOAD: '2', DONE: '3', DELAYED: '4', DISMISS: '5',
              DELETE_PROFILE: '6', REDOWNLOAD_MANDATORY: '7', USER_INPUT: '8' };
const SERVICE = { ACTIVATED: '1', ACTIVATING: '2', DEACTIVATED: '3', DEACTIVATED_NO_REUSE: '4' };

const CT_EAP_RELAY = 'application/vnd.gsma.eap-relay.v1.0+json';
const ACCEPT_ODSA = 'text/vnd.wap.connectivity-xml';
const ACCEPT_JSON = 'application/json, text/vnd.wap.connectivity-xml';

// at most this many EAP relay rounds: one challenge plus a resync and a
// second challenge, with room for one more (ts43-go stops at 4 too)
const RELAY_ROUNDS = 4;

// transfer types that authenticate later steps with a temporary token
// (AcquireTemporaryToken) instead of IMSI + token
const TEMP_TOKEN_TYPES = [ 2, 9, 11 ];

// --- response parsing ------------------------------------------------------

let xml_unescape = (s) => replace(replace(replace(replace(replace(s ?? '',
	/&lt;/g, '<'), /&gt;/g, '>'), /&quot;/g, '"'), /&apos;/g, "'"), /&amp;/g, '&');

// A provisioning document (`wap-provisioningdoc`, OMA CP) as a tree of
// { type, parms: { name: value }, children: [ node ] }. Tolerant on purpose:
// unknown elements are skipped, `param` is taken for `parm`, attribute order
// does not matter. null when nothing parsed.
function parse_xml(body)
{
	let root = { type: '', parms: {}, children: [] };
	let stack = [ root ];
	let n = 0;

	for (let m in (match(body ?? '', /<(\/?)(characteristic|parm|param)\b([^>]*?)(\/?)>/g) ?? [])) {
		let attr = (name) => {
			let a = match(m[3], regexp(name + '\\s*=\\s*"([^"]*)"'));

			return a ? xml_unescape(a[1]) : null;
		};

		n++;

		if (m[2] == 'characteristic') {
			if (m[1] == '/') {
				if (length(stack) > 1)
					pop(stack);
				continue;
			}

			let node = { type: attr('type') ?? '', parms: {}, children: [] };

			push(stack[length(stack) - 1].children, node);

			if (m[4] != '/')
				push(stack, node);

			continue;
		}

		if (m[1] == '/')
			continue;

		let name = attr('name');

		if (name != null)
			stack[length(stack) - 1].parms[name] = attr('value') ?? '';
	}

	return n ? root : null;
}

// The same tree from the JSON form: scalars are parms, objects children named
// by their key, arrays several children of that name.
function json_node(ntype, obj)
{
	let node = { type: ntype, parms: {}, children: [] };

	for (let k, v in obj) {
		if (type(v) == 'object')
			push(node.children, json_node(k, v));
		else if (type(v) == 'array')
			for (let e in v)
				(type(e) == 'object') ? push(node.children, json_node(k, e)) : null;
		else if (v != null)
			node.parms[k] = '' + v;
	}

	return node;
}

// ucode's json() raises on bad input, so only a body that looks like JSON is
// handed to it, and inside a try
function parse_json(body)
{
	let t = trim(body ?? '');

	if (substr(t, 0, 1) != '{')
		return null;

	try {
		let o = json(t);

		return (type(o) == 'object') ? o : null;
	}
	catch (e) {
		return null;
	}
}

let child = (node, t) => filter(node?.children ?? [], (c) => c.type == t)[0];

function parm_ci(node, name)
{
	for (let k, v in node?.parms ?? {})
		if (lc(k) == lc(name))
			return v;

	return null;
}

// A response body (XML or JSON) as the flat view the flow decides on:
// { token, validity, app: { parms… }, primary: {…}, download: {…}, msg: {…} }
// The application is the APPLICATION whose AppID is ap2009, or the only one
// there is (some servers leave AppID out). DownloadInfo at the application
// level wins over the one inside PrimaryConfiguration (ts43-go
// response.go:662-668), ServiceStatus is read only from PrimaryConfiguration.
function parse_body(body)
{
	let root;
	let j = parse_json(body);

	if (j) {
		root = json_node('', {});

		for (let k, v in j)
			if (type(v) == 'object')
				push(root.children, json_node((k == APP_ODSA) ? 'APPLICATION' : k, v));

		// an application at the root itself
		if (!child(root, 'APPLICATION') && (j.OperationResult != null || j.SubscriptionResult != null))
			push(root.children, json_node('APPLICATION', j));
	}
	else
		root = parse_xml(body);

	if (!root)
		return null;

	let token = child(root, 'TOKEN') ?? child(root, 'Token') ?? child(root, 'token');
	let apps = filter(root.children, (c) => c.type == 'APPLICATION');
	let app = filter(apps, (c) => c.parms.AppID == APP_ODSA)[0] ?? ((length(apps) == 1) ? apps[0] : null);
	let primary = child(app, 'PrimaryConfiguration') ?? child(child(app, 'PrimaryConfigurations'), 'PrimaryConfiguration');

	return {
		token: parm_ci(token, 'token'),
		validity: +(parm_ci(token, 'validity') ?? '') || 3600,
		app: app?.parms ?? {},
		primary: primary?.parms ?? {},
		download: (child(app, 'DownloadInfo') ?? child(primary, 'DownloadInfo'))?.parms ?? {},
		msg: (child(app, 'MSG') ?? child(primary, 'MSG'))?.parms ?? null,
	};
}

// `encodedValue=<base64>` is how servers send values that would not survive a
// query string or XML; plain values stay as they are (decoding anything that
// HAPPENS to be valid base64 would mangle a plain matching id)
function decoded(v)
{
	if (type(v) != 'string')
		return null;

	return (substr(v, 0, 13) == 'encodedValue=') ? (b64dec(substr(v, 13)) ?? '') : v;
}

// The activation code the flow ends in, from a parsed body: the
// ProfileActivationCode, or the SM-DP+ address (+ matching id) built into one
// (SGP.22 4.1). { activation_code, iccid } or null.
function download_of(p)
{
	let d = p?.download ?? {};
	let ac = decoded(d.ProfileActivationCode);

	if (length(ac ?? '')) {
		if (substr(ac, 0, 4) != 'LPA:')
			ac = 'LPA:' + ac;

		return { activation_code: ac, iccid: d.ProfileIccid ?? p.primary?.ICCID };
	}

	let smdp = decoded(d.ProfileSmdpAddress ?? d.SubscriptionServiceURL);

	if (!length(smdp ?? ''))
		return null;

	smdp = split(smdp, ',')[0];

	let h = match(smdp, /^[a-z]+:\/\/([^\/:]+(:[0-9]+)?)/);

	if (h)
		smdp = h[1];

	return { activation_code: sprintf('LPA:1$%s$%s', smdp, decoded(d.MatchingID) ?? ''),
	         iccid: d.ProfileIccid ?? p.primary?.ICCID };
}

// --- tracing -----------------------------------------------------------------

// A trace line that can be pasted into a bug report: digit runs of 10 or more
// (IMSI, ICCID, IMEI, EID) keep their first 5 and last 2 digits, a token or
// temporary token value its first 4 characters. What a first test needs from
// the log is the step and the server's verdict, never the identity.
function mask(s)
{
	s = replace('' + (s ?? ''), /[0-9]{10,}/g, (m) => substr(m, 0, 5) + '…' + substr(m, -2));

	// token=… (query), "token":"…" (JSON), name="token" value="…" (XML), and
	// the same for TemporaryToken / temporary_token
	return replace(s, /(token"? *[:=] *"?|token" value=")([^"&,<[:space:]]{4})[^"&,<[:space:]]*/gi,
		(m, pre, keep) => pre + keep + '…');
}

// the server's verdict in one line: the values the flow decides on
function verdict_of(p)
{
	let out = [];

	for (let k in [ 'OperationResult', 'PrimaryAppEligibility', 'SubscriptionResult' ])
		if (p?.app?.[k] != null)
			push(out, k + '=' + p.app[k]);

	if (p?.primary?.ServiceStatus != null)
		push(out, 'ServiceStatus=' + p.primary.ServiceStatus);

	if (p?.token)
		push(out, sprintf('token (valid %d s)', p.validity));

	if (length(p?.download ?? {}))
		push(out, 'DownloadInfo');

	if (p?.msg)
		push(out, 'MSG');

	if (p?.app?.GeneralErrorText)
		push(out, sprintf('GeneralErrorText=%J', p.app.GeneralErrorText));

	return length(out) ? join(' ', out) : '(nothing the flow knows)';
}

let snippet = (body) => mask(substr(replace(body ?? '', /\s+/g, ' '), 0, 300));

const AKA_SUBTYPES = { '1': 'AKA-Challenge', '2': 'Authentication-Reject', '4': 'Synchronization-Failure',
                       '5': 'AKA-Identity', '12': 'Notification', '14': 'Client-Error' };

// --- requests --------------------------------------------------------------

let urlenc = (s) => replace('' + s, /[^A-Za-z0-9_.~-]/g, (c) => sprintf('%%%02X', ord(c)));

// The User-Agent of TS.43 2.2: PRD-TS43 term-<vendor>/<model> <client>/<ver>
// OS-<os>/<os ver>. The OS token is the router's (OpenWrt), not Android's.
function user_agent(c)
{
	let t = c.terminal;

	return sprintf('PRD-TS43 term-%s/%s %s/%s OS-%s/%s', substr(t.vendor, 0, 4), substr(t.model, 0, 10),
		c.client_ts43, c.app_version, c.os ?? 'OpenWrt', substr(t.sw, 0, 20));
}

// --- the session -----------------------------------------------------------

// fx: { http(req, cb), aka(auth_data_hex, cb), timer(ms, fn), log(level, msg) }
//   http req = { method, url, headers, body } → cb(err, { status, headers, body })
//   aka → cb(err, usim response hex: DB… / DC… / an SW on refusal)
// c: see config_of() in the plugin. on(ev): every state change, the terminal
// ones included: { state: 'done' | 'download' | 'denied' | 'error' | … }.
function session(c, fx, on)
{
	let st = {
		state: 'idle', token: null, token_until: 0, temp_token: null, cookies: {},
		identity: A.nai(c.imsi, c.mnc_len), last: null, cancelled: false,
	};
	let wait = null;   // what an input op continues: { kind, fn }

	let emit = (state, extra) => {
		st.state = state;
		on({ state: state, ...(extra ?? {}) });
	};

	let fail = (state, why, extra) => {
		wait = null;
		emit(state, { reason: why, ...(extra ?? {}) });
	};

	let cookie_header = () => join('; ', map(keys(st.cookies), (k) => k + '=' + st.cookies[k]));

	let take_cookies = (headers) => {
		for (let k, v in headers ?? {}) {
			if (lc(k) != 'set-cookie')
				continue;

			for (let one in ((type(v) == 'array') ? v : [ v ])) {
				let m = match(one ?? '', /^[[:space:]]*([^=;[:space:]]+)=([^;]*)/);

				if (m) {
					st.cookies[m[1]] = m[2];
					// the NAME only: which session the server keeps is what a
					// failed relay is debugged by, its value is a credential
					fx.log('debug', sprintf('ts43: cookie %s set', m[1]));
				}
			}
		}
	};

	// the common parameters of every request (TS.43 2.4 / 2.6)
	let params_of = (auth, op) => {
		let p = [];
		let add = (k, v) => (v != null && v !== '') ? push(p, [ k, '' + v ]) : null;
		let t = c.terminal;

		if (auth == 'eap')
			add('EAP_ID', st.identity);
		else if (auth == 'temp')
			add('temporary_token', st.temp_token);
		else {
			add('IMSI', c.imsi);
			add('token', st.token);
		}

		// these four go even when empty (ts43-go request.go:205-221)
		push(p, [ 'terminal_id', t.id ?? '' ], [ 'app', c.app ],
		        [ 'terminal_vendor', substr(t.vendor ?? '', 0, 4) ],
		        [ 'terminal_model', substr(t.model ?? '', 0, 10) ],
		        [ 'terminal_sw_version', substr(t.sw ?? '', 0, 20) ],
		        [ 'vers', c.vers ], [ 'entitlement_version', c.entitlement_version ]);

		add('app_name', op?.no_app_name ? null : c.app_name);
		add('app_version', c.app_version);

		for (let kv in op?.fields ?? [])
			add(kv[0], kv[1]);

		return p;
	};

	let request = (auth, op, cb) => {
		if (st.cancelled)
			return;

		let p = params_of(auth, op);
		let accept = (c.app == APP_ODSA) ? ACCEPT_ODSA : ACCEPT_JSON;

		if (auth == 'eap')
			accept = CT_EAP_RELAY + ', ' + accept;

		let req = { headers: { 'Accept': accept, 'User-Agent': user_agent(c) } };

		if (length(st.cookies))
			req.headers.Cookie = cookie_header();

		if (c.post) {
			let o = {};

			for (let kv in p)
				o[kv[0]] = kv[1];

			req.method = 'POST';
			req.url = c.server;
			req.body = sprintf('%J', o);
			req.headers['Content-Type'] = 'application/json';
		}
		else {
			req.method = 'GET';
			req.url = c.server + ((index(c.server, '?') >= 0) ? '&' : '?') +
				join('&', map(p, (kv) => urlenc(kv[0]) + '=' + urlenc(kv[1])));
		}

		let opname = op?.fields?.[0]?.[1] ?? 'authenticate';

		fx.log('debug', sprintf('ts43: → %s %s (%s)', req.method, opname,
			(auth == 'eap') ? 'EAP_ID ' + mask(st.identity) : auth));

		fx.http(req, (err, res) => {
			if (st.cancelled)
				return;

			if (err) {
				fx.log('debug', sprintf('ts43: ← %s: transport error %J', opname, err));
				return cb(err, null);
			}

			fx.log('debug', sprintf('ts43: ← %s: HTTP %d, %d bytes%s', opname, res.status, length(res.body ?? ''),
				(res.status < 200 || res.status > 299) ? ': ' + snippet(res.body) : ''));

			take_cookies(res.headers);
			cb(null, res, accept);
		});
	};

	// the EAP relay: the server answers the EAP_ID request with an
	// eap-relay-packet, we POST the response back to the bare URL, until a
	// body that is not a relay packet arrives — the answer to the request
	let relay;
	relay = (res, accept, round, cb) => {
		let rp = parse_json(res.body);
		let pkt = rp?.['eap-relay-packet'];

		if (type(pkt) != 'string')
			return cb(null, res);

		if (round >= RELAY_ROUNDS)
			return cb({ error: 'eap_rounds' });

		let step = A.step(map(split(b64dec(pkt) ?? '', ''), (ch) => ord(ch)));

		fx.log('debug', sprintf('ts43: EAP round %d: %s%s', round + 1,
			AKA_SUBTYPES[sprintf('%d', step.req?.subtype ?? -1)] ?? 'packet',
			step.error ? ' — not answered: ' + step.error : ''));
		let send = (bytes, then) => {
			let headers = { 'Content-Type': CT_EAP_RELAY, 'Accept': accept, 'User-Agent': user_agent(c) };

			if (length(st.cookies))
				headers.Cookie = cookie_header();

			fx.log('debug', sprintf('ts43: → POST EAP relay (%d bytes EAP, cookies: %s)', length(bytes),
				length(st.cookies) ? join(', ', keys(st.cookies)) : 'none'));

			fx.http({ method: 'POST', url: split(c.server, '?')[0], headers: headers,
			          body: sprintf('{"eap-relay-packet":"%s"}', b64enc(chr(...bytes))) }, (err, r2) => {
				if (st.cancelled)
					return;

				if (err) {
					fx.log('debug', sprintf('ts43: ← EAP relay: transport error %J', err));
					return cb(err);
				}

				fx.log('debug', sprintf('ts43: ← EAP relay: HTTP %d, %d bytes%s', r2.status, length(r2.body ?? ''),
					(r2.status < 200 || r2.status > 299) ? ': ' + snippet(r2.body) : ''));
				take_cookies(r2.headers);
				then(r2);
			});
		};

		if (step.reply)
			return send(step.reply, () => cb({ error: 'eap', detail: step.error }));

		fx.aka(step.usim, (err, usim) => {
			if (st.cancelled)
				return;

			if (err) {
				fx.log('debug', sprintf('ts43: USIM AUTHENTICATE failed: %J', err));
				return send(A.reject(step.id), () => cb({ error: 'usim', detail: err }));
			}

			let a = A.answer(step, st.identity, usim, c.lax_mac);

			fx.log('debug', sprintf('ts43: USIM: %s → %s', (substr(usim ?? '', 0, 2) == 'DB') ? 'RES/CK/IK'
				: (substr(usim ?? '', 0, 2) == 'DC') ? 'AUTS (sequence resync)' : 'SW ' + (usim ?? '?'),
				a.error ? 'not answered: ' + a.error : a.resync ? 'Synchronization-Failure sent' : 'AT_RES + AT_MAC sent'));

			send(a.reply, (r2) => a.error ? cb({ error: 'eap', detail: a.error })
			                              : relay(r2, accept, round + 1, cb));
		});
	};

	let authenticate = (cb) => {
		if (!st.identity)
			return cb({ error: 'identity', detail: 'IMSI or MNC length unknown' });

		emit('authenticating');

		request('eap', null, (err, res, accept) => {
			if (err)
				return cb(err);

			if (res.status == 511 || res.status == 401 || res.status == 403)
				return cb({ error: 'http', status: res.status });

			relay(res, accept, 0, (err, fin) => {
				if (err)
					return cb(err);

				let p = parse_body(fin.body);

				fx.log('debug', sprintf('ts43: authentication answer: HTTP %d, %s', fin.status, verdict_of(p)));

				if (!p?.token)
					return cb({ error: 'no_token', status: fin.status, body: snippet(fin.body) });

				st.token = p.token;
				st.token_until = fx.now() + p.validity;
				cb(null);
			});
		});
	};

	// one ODSA operation with the current credential; a 511 (TS.43: the
	// token is no longer valid) re-authenticates ONCE and repeats it
	let call;
	call = (fields, cb, opts) => {
		let auth = st.temp_token ? 'temp' : 'token';

		request(auth, { fields: fields, no_app_name: opts?.no_app_name }, (err, res) => {
			if (err)
				return cb(err);

			if ((res.status == 511 || (res.status == 401 && auth == 'temp')) && !opts?.retried)
				return authenticate((aerr) => aerr ? cb(aerr)
					: call(fields, cb, { ...(opts ?? {}), retried: true }));

			if (res.status < 200 || res.status > 299)
				return cb({ error: 'http', status: res.status });

			let p = parse_body(res.body);

			if (!p) {
				fx.log('debug', sprintf('ts43: unreadable answer: %s', snippet(res.body)));
				return cb({ error: 'body', status: res.status });
			}

			fx.log('debug', sprintf('ts43: %s: %s', fields[0][1], verdict_of(p)));

			if (p.token) {
				st.token = p.token;
				st.token_until = fx.now() + p.validity;
			}

			st.last = p;
			st.last_body = res.body;
			cb(null, p);
		});
	};

	let target_fields = () => [
		[ 'target_terminal_id', c.target.imei ],
		[ 'target_terminal_eid', c.target.eid ],
	];

	let old_fields = () => [
		[ 'old_terminal_id', c.terminal.id ],
		[ 'old_terminal_iccid', c.source_iccid ],
	];

	// a refusal's answer may say more than the fields the flow reads (an
	// operator's own parms, a text in another place): its start goes into
	// the trace, masked
	let denied = (op, p) => {
		// from the application on: the head of the document is VERS and
		// TOKEN, the same in every answer, and would use up the snippet
		let b = st.last_body ?? '';
		let at = index(b, 'APPLICATION');

		at = (at < 0) ? index(b, APP_ODSA) : at;
		fx.log('debug', sprintf('ts43: %s refused, the answer: %s', op, snippet((at > 30) ? substr(b, at - 30) : b)));
		fail('denied', op, {
			operation_result: p?.app?.OperationResult, subscription_result: p?.app?.SubscriptionResult,
			eligibility: p?.app?.PrimaryAppEligibility, text: p?.app?.GeneralErrorText,
		});
	};

	let poll, manage, ask;

	// AcquireConfiguration until the profile is ready (ServiceStatus 1, or a
	// download in the answer), the server says no, or c.poll_timeout passes
	poll = (deadline, after_install) => {
		emit('polling', after_install ? { phase: 'activation' } : null);

		call([ [ 'operation', 'AcquireConfiguration' ], [ 'terminal_eid', c.target.eid ],
		       ...(after_install ? [] : [ ...target_fields(), ...old_fields() ]) ], (err, p) => {
			if (err)
				return fail('error', 'AcquireConfiguration', err);

			let opres = p.app.OperationResult;

			if (opres != null && opres != OP_RESULT_SUCCESS)
				return denied('AcquireConfiguration', p);

			let dl = after_install ? null : download_of(p);
			let ss = p.primary.ServiceStatus;

			if (dl)
				return emit('download', dl);

			if (ss == SERVICE.ACTIVATED)
				return after_install ? emit('done') : fail('error', 'activated_without_download');

			if (ss == SERVICE.DEACTIVATED || ss == SERVICE.DEACTIVATED_NO_REUSE)
				return denied('AcquireConfiguration', p);

			if (fx.now() >= deadline)
				return fail('error', 'poll_timeout');

			let iv = +(p.primary.PollingInterval ?? p.app.PollingInterval ?? '');
			let unit = p.primary.PollingIntervalUnit ?? p.app.PollingIntervalUnit;
			let ms = (iv != iv || p.primary.PollingInterval == null && p.app.PollingInterval == null)
				? c.poll_interval * 1000
				: (unit == '1') ? iv * 1000 : (unit == '2') ? iv * 100 : iv * 60000;

			if (ms <= 0)
				return emit('pending', { reason: 'the server will push the configuration later' });

			fx.timer(ms, () => poll(deadline, after_install));
		});
	};

	// ManageSubscription operation_type 3 (transfer) — and its answers
	manage = (msg_answer) => {
		emit('subscribing');

		let fields = [ [ 'operation', 'ManageSubscription' ], [ 'operation_type', '3' ],
		               [ 'terminal_eid', c.target.eid ], ...target_fields(), ...old_fields() ];

		if (msg_answer)
			push(fields, [ 'MSG_response', msg_answer.response ], [ 'MSG_btn', msg_answer.accepted ? '1' : '0' ]);

		call(fields, (err, p) => {
			if (err)
				return fail('error', 'ManageSubscription', err);

			// 104: the answer to the prompt was not accepted, ask again
			if (p.app.OperationResult == '104' && p.msg)
				return ask(p);

			if (p.app.OperationResult != OP_RESULT_SUCCESS)
				return denied('ManageSubscription', p);

			let deadline = fx.now() + c.poll_timeout;

			switch (p.app.SubscriptionResult) {
			case SUB.DOWNLOAD: {
				let dl = download_of(p);

				return dl ? emit('download', dl) : denied('ManageSubscription', p);
			}

			case SUB.DONE:
				return emit('done');

			case SUB.DISMISS:
				return fail('denied', 'dismissed');

			case SUB.USER_INPUT:
				return ask(p);

			case SUB.WEBSHEET: {
				let url = decoded(p.app.SubscriptionServiceURL);

				if (!length(url ?? ''))
					return denied('ManageSubscription', p);

				wait = { kind: 'websheet', fn: (next) => (next == 'ManageSubscription') ? manage() : poll(fx.now() + c.poll_timeout) };

				return emit('websheet', { url: url, user_data: decoded(p.app.SubscriptionServiceUserData),
				                          content_type: p.app.SubscriptionServiceContentsType });
			}

			case SUB.DELETE_PROFILE:
				// the server wants the source profile gone before it hands
				// out the new one: the caller releases it (disable, delete,
				// delete notification) and continues
				wait = { kind: 'source_deleted', fn: () => poll(fx.now() + c.poll_timeout) };

				return emit('delete_source', { iccid: c.source_iccid });

			case SUB.DELAYED:
				return poll(deadline);

			default:
				return denied('ManageSubscription', p);
			}
		});
	};

	ask = (p) => {
		wait = { kind: 'message', fn: (ans) => manage(ans) };

		emit('message', { title: p.msg?.Title, message: p.msg?.Message,
		                  accept_label: p.msg?.Accept_btn_label, reject_label: p.msg?.Reject_btn_label,
		                  freetext: p.msg?.Accept_freetext == '1', hint: p.msg?.Accept_freetext_hint });
	};

	let start = () => {
		authenticate((err) => {
			if (err)
				return fail('error', 'authenticate', err);

			emit('eligibility');

			let fields = [ [ 'operation', 'CheckEligibility' ] ];

			if (c.eligibility_target)
				push(fields, [ 'target_terminal_id', c.target.imei ]);

			call(fields, (err, p) => {
				if (err)
					return fail('error', 'CheckEligibility', err);

				if (p.app.OperationResult != OP_RESULT_SUCCESS || p.app.PrimaryAppEligibility != '1')
					return denied('CheckEligibility', p);

				// a pre-flight check ends here: the operator would transfer
				// this subscription, and nothing has been ordered yet —
				// ManageSubscription is the first step that changes anything
				// at the operator
				if (c.check_only)
					return emit('eligible');

				if (!(c.transfer_type in TEMP_TOKEN_TYPES))
					return manage();

				call([ [ 'operation', 'AcquireTemporaryToken' ],
				       [ 'operation_targets', 'ManageSubscription,AcquireConfiguration' ] ], (err, p) => {
					if (err)
						return fail('error', 'AcquireTemporaryToken', err);

					if (!length(p.app.TemporaryToken ?? ''))
						return denied('AcquireTemporaryToken', p);

					st.temp_token = p.app.TemporaryToken;
					manage();
				});
			});
		});
	};

	return {
		state: () => st.state,
		start: start,

		// the input a waiting state asked for: 'message' { response,
		// accepted }, 'websheet' next ('ManageSubscription' |
		// 'AcquireConfiguration'), 'source_deleted'
		resume: (kind, arg) => {
			if (wait?.kind != kind)
				return { error: 'not_waiting', waiting: wait?.kind };

			let w = wait;

			wait = null;
			w.fn(arg);

			return null;
		},

		// the profile is on the target and enabled: tell the server (operation
		// type 4) and wait until it reports the service active. Only for a
		// target this router downloads itself.
		installed: (iccid) => {
			emit('activating');

			call([ [ 'operation', 'ManageSubscription' ], [ 'operation_type', '4' ],
			       [ 'terminal_iccid', iccid ], [ 'terminal_eid', c.target.eid ], ...old_fields() ], (err, p) => {
				if (err)
					return fail('error', 'ManageSubscription(update)', err);

				if (p.app.OperationResult != OP_RESULT_SUCCESS || p.app.SubscriptionResult != SUB.DONE)
					return denied('ManageSubscription(update)', p);

				poll(fx.now() + c.poll_timeout, true);
			}, { no_app_name: true });
		},

		waiting: () => wait?.kind,
		cancel: () => { st.cancelled = true; wait = null; emit('cancelled'); },
	};
}

// The entitlement record for a SIM, from a ts43-go compatible entitlement.json
// (an array of records; GSMA does not publish operator URLs, users bring the
// file). The best match wins: imsiPrefixXpattern 128, gid1 32, gid2 16, spn 2
// (ts43-go identity.go:62-120 scores, which follow Android's CarrierResolver).
// A tie between two different servers is ambiguous → null + reason.
function pick_record(records, sim)
{
	let best = -1, hits = [];

	for (let r in ((type(records) == 'array') ? records : [])) {
		if (r?.mccmnc != sim.mccmnc || !length(r.entitlementServer ?? ''))
			continue;

		let score = 0, ok = true;
		let pre = (have, want) => (want == null) ? 0 : (substr(lc(have ?? ''), 0, length(want)) == lc(want)) ? 1 : -1;

		if (r.imsiPrefixXpattern != null) {
			let pat = '^' + replace(r.imsiPrefixXpattern, /[xX]/g, '[0-9]');

			if (match(sim.imsi ?? '', regexp(pat))) score += 128; else ok = false;
		}

		for (let f in [ [ 'gid1', 32 ], [ 'gid2', 16 ] ]) {
			let m = pre(sim[f[0]], r[f[0]]);

			if (m < 0) ok = false; else score += m * f[1];
		}

		if (r.spn != null) {
			if (r.spn == sim.spn) score += 2; else ok = false;
		}

		if (!ok || score < best)
			continue;

		if (score > best) {
			best = score;
			hits = [];
		}

		if (!length(filter(hits, (h) => h.entitlementServer == r.entitlementServer)))
			push(hits, r);
	}

	if (length(hits) == 1)
		return { record: hits[0] };

	return { record: null, reason: length(hits) ? 'ambiguous' : 'not_found' };
}

export { session, parse_body, parse_xml, download_of, pick_record, user_agent, mask, TEMP_TOKEN_TYPES };
