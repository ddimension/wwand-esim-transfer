// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-esim-transfer — moving an eSIM subscription off or onto this router,
// as a wwand plugin. wwand plugins.uc require()s the plain shim
// plugins/esim_transfer.uc, which hands back this module's plugin object;
// everything here is precompiled to bytecode.
//
// An eUICC never exports a profile. Whatever the operator calls it, a
// "transfer" is always: the operator issues a NEW download for the target
// device, and the old profile goes. What a router can do around that:
//
// - RELEASE a profile it holds (disable, delete) and make sure the delete
//   notification reaches the operator's SM-DP+. Until it does, the operator
//   believes the profile is still installed here and may refuse to issue it
//   elsewhere (Vodafone DE says so: the old device must be decoupled from its
//   EID first). The card keeps that notification until an SM-DP+ has
//   acknowledged it (lpac `notification process -r`), so "still listed" is
//   the truth about delivery, and it is retried until it is gone.
// - IMPORT: download a code the operator issued (portal QR, ePIN), or ask an
//   SM-DS whether the operator queued a profile for this card's EID.
// - TS.43 (ODSA, esim_transfer/ts43.uc): let the router's own SIM prove the
//   subscription to the operator's entitlement server and get an activation
//   code for a target eUICC — this router's (physical SIM → eSIM) or another
//   device's (shown as a QR). Only operators that run such a server, and
//   only those that accept a router; experimental, off until configured.
// - show a profile's SGP.22 v3 Device Change configuration where the card
//   has one (esim_transfer/meta.uc).
//
// An ES module: exports PLUGIN (name, options, create — what plugins.uc
// expects) plus `engine`, the testable core.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import * as ts43 from 'wwand.esim_transfer.ts43';
import * as meta from 'wwand.esim_transfer.meta';
import * as hints from 'wwand.esim_transfer.hints';
import * as http from 'wwand.esim_transfer.http';

const VERSION = '0.1.0';
const CARD = '/usr/libexec/wwand/esim-transfer-card';
const STATE_DIR = '/etc/wwand/esim-transfer';
const ENTITLEMENT_FILE = STATE_DIR + '/entitlement.json';

// The operator list fetched on request (`wwandctl transfer carriers update`):
// NekokoLPA2's entitlement.json (github.com/iebb/NekokoLPA2, MIT;
// assets/ts43/entitlement.json, the record format of damonto/ts43-go), which
// its authors derived from Google's carrier configurations. Not shipped in
// the package — fetched by the user, from a PINNED commit, so what a router
// uses is a known list and an upstream change reaches it only when this pin
// moves (option esim_transfer_carriers_url overrides). Its data needs
// checking like any third-party list: it files 262 03 (o2) as "1&1"
// (read 2026-11-21).
const CARRIERS_FILE = STATE_DIR + '/carriers.json';
const CARRIERS_URL = 'https://raw.githubusercontent.com/iebb/NekokoLPA2/8c57763fd720ce342a63cbd2a34335b84f516ebb/assets/ts43/entitlement.json';

// lines of debug trace kept per modem (engine trace)
const TRACE_MAX = 200;

// TS.43 session states in which another transfer may start
const TS43_IDLE = [ 'done', 'denied', 'error', 'cancelled', 'download', 'eligible' ];

const OPTIONS = [ 'esim_transfer_server', 'esim_transfer_post', 'esim_transfer_type',
	'esim_transfer_vendor', 'esim_transfer_model', 'esim_transfer_sw', 'esim_transfer_app_name',
	'esim_transfer_mnc_len', 'esim_transfer_lax_mac', 'esim_transfer_smds', 'esim_transfer_carriers_url' ];

// seconds; overridable through deps.timing for the tests
const TIMING = {
	// a release whose notification did not get through: try again this often
	// (and at once whenever a new data session comes up)
	retry: 300,
	// how often a running lpac notify is looked at
	notify_poll: 2,
	// a notify that has not ended by then is given up for this round
	notify_max: 120,
	// TS.43 AcquireConfiguration: default poll interval and overall bound
	poll_interval: 60,
	poll_timeout: 600,
};

let truthy = (v) => (v === true || v == '1' || v == 'true' || v == 'on' || v == 'yes');
let str = (v) => (v != null && v != '') ? '' + v : null;

function cfg_of(ext)
{
	let n = (v) => { let x = +(v ?? ''); return (str(v) != null && x == x) ? x : null; };

	return {
		server: str(ext?.esim_transfer_server),
		post: truthy(ext?.esim_transfer_post),
		type: n(ext?.esim_transfer_type),
		vendor: str(ext?.esim_transfer_vendor),
		model: str(ext?.esim_transfer_model),
		sw: str(ext?.esim_transfer_sw),
		app_name: str(ext?.esim_transfer_app_name),
		mnc_len: n(ext?.esim_transfer_mnc_len),
		lax_mac: truthy(ext?.esim_transfer_lax_mac),
		smds: str(ext?.esim_transfer_smds),
		carriers_url: str(ext?.esim_transfer_carriers_url),
	};
}

// `lpac notification list`'s entries from the bridge log (its `data: [...]`
// line, wwand esim_bridge parse_lpac_line data_json), or NULL when the list
// could not be read: no successful result line, or no data line. The
// difference matters: the release record goes to `delivered` when its
// notification is no longer listed, so an unreadable list must never look
// like an empty one. That happens when lpac's ES10 call failed (result
// code=-1, still exit 0) and on a wwand older than data_json, whose log
// never carried the array at all. ucode's json() raises on bad input, hence
// the try.
function notifications_of(log)
{
	if (!match(log ?? '', /(^|\n)result: code=0( |\n|$)/))
		return null;

	let m = match(log, /(^|\n)data: (\[[^\n]*\])/);

	if (!m)
		return null;

	try {
		let a = json(m[2]);

		return (type(a) == 'array') ? filter(a, (x) => type(x) == 'object') : null;
	}
	catch (e) {
		return null;
	}
}

// ICCIDs compared without their F padding (ITU-T E.118 fills an odd length
// with F; lpac's notification list and wwand's profile parser need not agree
// on keeping it)
let iccid_eq = (a, b) => type(a) == 'string' && type(b) == 'string' &&
	replace(uc(a), /F+$/, '') == replace(uc(b), /F+$/, '');

// the pending delete notifications of one ICCID (lpac list fields:
// seqNumber, profileManagementOperation, iccid; src/applet/notification/
// list.c, lpac 2.3.0)
let delete_seqs = (list, iccid) => map(filter(list, (n) =>
	n.profileManagementOperation == 'delete' && iccid_eq(n.iccid, iccid) && n.seqNumber != null), (n) => n.seqNumber);

// An operator list as the plugin keeps it: the records a non-Samsung client
// can use. `channel: samsung` records describe Samsung's own request format
// (NekokoLPA2 lib/ts43/samsung_request.dart), which this client does not
// speak; a record without an https server or a numeric MCC+MNC is dropped.
// { records } or { error }.
function carriers_of(text)
{
	let a = null;

	try { a = json(text ?? ''); } catch (e) { return { error: 'not JSON' }; }

	if (type(a) != 'array')
		return { error: 'not a list of records' };

	let recs = filter(a, (r) => type(r) == 'object' && match('' + (r.mccmnc ?? ''), /^[0-9]{5,6}$/) &&
		match(r.entitlementServer ?? '', /^https:\/\/[A-Za-z0-9.-]+/) && r.channel != 'samsung');

	return length(recs) ? { records: recs } : { error: 'no usable record' };
}

let valid_iccid = (s) => type(s) == 'string' && match(s, /^[0-9]{18,20}F?$/);
let valid_eid = (s) => type(s) == 'string' && match(s, /^[0-9]{32}$/);
let valid_imei = (s) => type(s) == 'string' && match(s, /^[0-9]{14,16}$/);

// deps: {
//   esim(ref, op, params, cb)        wwand's modem_esim (the guarded path)
//   card(ref, args, cb)              one esim-transfer-card run → cb(err, payload)
//   modem(ref)                       { imsi, iccid, imei, model, eid, profiles } (null: no modem)
//   online(ref)                      the connection token, null while none
//   slots(ref, cb), switch_slot(ref, physical, cb)   the modem's SIM slots (optional)
//   http(req, cb), timer(ms, fn), now(), log(level, msg)
//   read(path), write(path, text)    the state file and entitlement.json
//   state_dir, timing
// }
function engine(deps)
{
	let timing = { ...TIMING, ...(deps.timing ?? {}) };
	let dir = deps.state_dir ?? STATE_DIR;
	let st = {};   // per modem ref

	let state = (ref) => (st[ref] ??= { releases: null, discovery: null, ts43: null, check: null,
	                                    delivering: false, token: null, trace: [] });

	// The debug trace a first test needs: every step, the card's status words,
	// the server's verdicts, in order, per modem — the last TRACE_MAX lines,
	// so `wwandctl transfer log` and the LuCI page show the story without a
	// syslog at debug level. Already masked where it carries identities
	// (ts43.uc mask); also sent to the syslog at debug.
	let trace = (ref, area, msg) => {
		let s = state(ref);

		push(s.trace, { at: deps.now(), area: area, msg: msg });

		if (length(s.trace) > TRACE_MAX)
			shift(s.trace);

		deps.log('debug', sprintf('esim-transfer[%s] %s: %s', ref, area, msg));
	};

	// releases survive a restart: the card still holds their notifications,
	// and the user still wants to see which ones went through
	let releases = (ref) => {
		let s = state(ref);

		if (s.releases == null) {
			let all = null;

			try { all = json(deps.read(dir + '/releases.json') ?? '{}'); } catch (e) { all = {}; }

			s.releases = (type(all?.[ref]) == 'array') ? all[ref] : [];
		}

		return s.releases;
	};

	let save = () => {
		let all = {};

		for (let ref, s in st)
			if (s.releases != null)
				all[ref] = s.releases;

		// the record is what tells, after a restart, which delete notification
		// is still owed; losing it silently would end the retries unseen
		if (!deps.write(dir + '/releases.json', sprintf('%J', all)))
			deps.log('warning', sprintf('esim-transfer: cannot write %s/releases.json — releases will not survive a restart', dir));
	};

	// a release's progress, for the page and the CLI: one entry per step,
	// `ok` true / false, or null while it runs
	let step = (r, name, ok, detail) => {
		let last = r.steps[length(r.steps) - 1];

		if (last?.step == name && last.ok == null) {
			last.ok = ok;
			last.detail = detail;
			last.done = deps.now();
		}
		else
			push(r.steps, { step: name, at: deps.now(), ok: ok, detail: detail });
	};

	let esim = (ref, op, params) => (cb) => deps.esim(ref, op, params ?? {}, cb);
	let why = (e) => e?.detail?.error ?? e?.detail ?? e?.error ?? 'failed';

	// lpac's own verdict line from a run's log ("result: code=-1
	// es9p_handle_notification"), the most telling thing a failure has
	let result_line = (log) => match(log ?? '', /result: code=[^\n]*/)?.[0];

	// run an async lpac notify of one seq to its end: cb(ok, detail)
	let notify_one = (ref, seq, cb) => {
		esim(ref, 'notify', { seq: seq })((err) => {
			if (err)
				return cb(false, why(err));

			let started = deps.now();
			let look;

			look = () => esim(ref, 'download_status')((e2, ds) => {
				if (!e2 && ds?.state == 'running' && deps.now() - started < timing.notify_max)
					return deps.timer(timing.notify_poll * 1000, look);

				let ok = !e2 && ds?.state == 'done';

				cb(ok, ok ? result_line(ds?.log) : (e2 ? why(e2) : (result_line(ds?.log) ?? ds?.state ?? 'no answer')));
			});
			deps.timer(timing.notify_poll * 1000, look);
		});
	};

	// one delivery round for every release of this modem that is not through
	let deliver = (ref, cb) => {
		let s = state(ref);
		let open = filter(releases(ref), (r) => r.state == 'delivering');

		if (s.delivering || !length(open))
			return cb?.(null);

		s.delivering = true;

		// counted as a try BEFORE anything can fail, so a failing list does
		// not make every 10 s tick a retry (the tick waits timing.retry from
		// last_try)
		for (let r in open) {
			r.tries = (r.tries ?? 0) + 1;
			r.last_try = deps.now();
		}

		let end = (err) => {
			s.delivering = false;

			if (err) {
				for (let r in open) {
					r.error = why(err);
					step(r, 'notify', false, r.error);
				}

				trace(ref, 'release', sprintf('delivery round failed: %s', why(err)));
			}

			save();
			cb?.(err);
		};

		trace(ref, 'release', sprintf('delivery round for %s', join(', ', map(open, (r) => r.iccid))));

		esim(ref, 'notifications')((err, res) => {
			if (err)
				return end(err);

			let list = notifications_of(res?.log);
			let todo = [];

			if (list == null)
				return end({ error: 'notification_list', detail: 'the card\'s notification list could not be read' +
					(result_line(res?.log) ? ' (' + result_line(res.log) + ')' : '') });

			trace(ref, 'release', sprintf('%d notification(s) on the card', length(list)));

			for (let r in open) {
				let seqs = delete_seqs(list, r.iccid);

				// nothing listed any more: it was delivered (by this round's
				// predecessor, or by whoever sent the card's notifications)
				if (!length(seqs)) {
					r.state = 'delivered';
					r.delivered = deps.now();
					delete r.error;
					step(r, 'notify', true, 'no longer on the card');
					trace(ref, 'release', sprintf('%s: nothing pending any more — delivered', r.iccid));
					continue;
				}

				for (let q in seqs)
					push(todo, { r: r, seq: q });
			}

			let next;
			next = (i) => {
				if (i >= length(todo))
					return end(null);

				let r = todo[i].r;

				step(r, 'notify', null, sprintf('seq %s', todo[i].seq));
				trace(ref, 'release', sprintf('%s: sending delete notification seq %s', r.iccid, todo[i].seq));

				notify_one(ref, todo[i].seq, (ok, detail) => {
					if (ok) {
						r.state = 'delivered';
						r.delivered = deps.now();
						delete r.error;
					}
					else
						r.error = detail;

					step(r, 'notify', ok, detail);
					trace(ref, 'release', sprintf('%s: seq %s %s (%s)', r.iccid, todo[i].seq,
						ok ? 'acknowledged by the SM-DP+' : 'NOT delivered', detail ?? '-'));
					next(i + 1);
				});
			};
			next(0);
		});
	};

	// RELEASE: disable when enabled, delete, then deliver the notification.
	// The record exists from the first step on, so a refusal on the way stays
	// visible with its reason (state `failed`), not just as a toast.
	let release = (ref, iccid, force, cb) => {
		if (!valid_iccid(iccid))
			return cb({ error: 'invalid_argument', detail: 'iccid' });

		esim(ref, 'profiles')((err, res) => {
			if (err)
				return cb(err);

			let p = filter(res?.profiles ?? [], (x) => iccid_eq(x.iccid, iccid))[0];

			if (!p)
				return cb({ error: 'not_found', detail: 'no such profile on this card' });

			let r = { iccid: iccid, provider: p.provider ?? p.nickname ?? null, released: deps.now(),
			          state: 'releasing', tries: 0, steps: [] };

			// a former failed attempt for the same profile is replaced
			let s = state(ref);
			s.releases = filter(releases(ref), (x) => !(iccid_eq(x.iccid, iccid) && x.state == 'failed'));
			push(s.releases, r);

			let fail = (stepname, e) => {
				r.state = 'failed';
				r.error = why(e);
				step(r, stepname, false, r.error);
				trace(ref, 'release', sprintf('%s: %s refused: %s', iccid, stepname, r.error));
				save();
				cb(e);
			};

			let del = () => {
				step(r, 'delete', null);
				trace(ref, 'release', sprintf('%s: deleting', iccid));

				esim(ref, 'delete', { iccid: iccid, force: !!force })((err) => {
					if (err)
						return fail('delete', err);

					step(r, 'delete', true);
					r.state = 'delivering';
					save();
					deps.log('notice', sprintf('esim-transfer: profile %s deleted, delivering its notification', iccid));
					trace(ref, 'release', sprintf('%s: deleted', iccid));
					cb(null, { released: iccid, state: 'delivering' });
					deliver(ref);
				});
			};

			if (p.state == 'enabled') {
				step(r, 'disable', null);
				trace(ref, 'release', sprintf('%s: enabled — disabling first', iccid));

				return esim(ref, 'disable', { iccid: iccid, force: !!force })((err) => {
					if (err)
						return fail('disable', err);

					step(r, 'disable', true);
					del();
				});
			}

			del();
		});
	};

	// --- TS.43 ----------------------------------------------------------------

	// the fetched operator list, cached until an update replaces it
	let carriers = null;

	let carriers_file = () => {
		if (carriers == null) {
			let c = null;

			try { c = json(deps.read(CARRIERS_FILE) ?? 'null'); } catch (e) { c = null; }

			carriers = (type(c?.records) == 'array') ? c : { records: [] };
		}

		return carriers;
	};

	// The user's own entitlement.json first — it says what this user knows
	// about their operator — then the fetched list. { record, reason, from }
	let record_for = (sim) => {
		let recs = null;

		try { recs = json(deps.read(ENTITLEMENT_FILE) ?? 'null'); } catch (e) { recs = null; }

		if (type(recs) == 'array') {
			let r = ts43.pick_record(recs, sim);

			if (r.record || r.reason == 'ambiguous')
				return { ...r, from: ENTITLEMENT_FILE };
		}

		let c = carriers_file();
		let r = ts43.pick_record(c.records, sim);

		return { ...r, from: length(c.records) ? sprintf('the operator list (%s)', c.label ?? 'fetched') : 'no operator list' };
	};

	// fetch, check and store the operator list (see CARRIERS_URL)
	let carriers_update = (ref, cfg, cb) => {
		let url = cfg.carriers_url ?? CARRIERS_URL;

		trace(ref, 'carriers', 'fetching ' + url);

		deps.http({ method: 'GET', url: url, headers: { 'Accept': 'application/json' } }, (err, res) => {
			if (err || res?.status != 200) {
				let why_ = err ? why(err) : sprintf('HTTP %d', res?.status ?? 0);

				trace(ref, 'carriers', 'update failed: ' + why_);
				return cb({ error: 'carriers_fetch', detail: why_ });
			}

			let c = carriers_of(res.body);

			if (c.error) {
				trace(ref, 'carriers', 'update refused: ' + c.error);
				return cb({ error: 'carriers_invalid', detail: c.error });
			}

			let label = (url == CARRIERS_URL) ? 'NekokoLPA2 ' + substr(split(CARRIERS_URL, '/')[5], 0, 8) : url;
			let doc = { source: url, label: label, fetched: deps.now(), records: c.records };

			if (!deps.write(CARRIERS_FILE, sprintf('%J', doc))) {
				trace(ref, 'carriers', 'cannot write ' + CARRIERS_FILE);
				return cb({ error: 'carriers_write', detail: 'cannot write ' + CARRIERS_FILE });
			}

			carriers = doc;
			trace(ref, 'carriers', sprintf('%d records stored (%s)', length(c.records), label));
			cb(null, { count: length(c.records), fetched: doc.fetched, label: label });
		});
	};

	// Everything a TS.43 session needs before its first request: the card's
	// identity (MNC length for the realm, GID1 for the record), the
	// entitlement server, the session config. cb(err, c, info); info says
	// what was found, for the pre-flight check's checklist.
	// eu: euicc_of()'s answer, when the caller has it
	let prepare = (ref, cfg, target, cb, eu) => {
		let m = deps.modem(ref);

		if (!m?.imsi)
			return cb({ error: 'no_sim', detail: 'the SIM in use is not read yet' });

		deps.card(ref, [ 'identity' ], (err, id) => {
			let mnc_len = cfg.mnc_len ?? (+(id?.mnc_len ?? '') || null);
			let info = { mnc_len: mnc_len, gid1: id?.group_id || null, usim: !(id?.error == 'usim_channel') };

			trace(ref, 'ts43', sprintf('card identity: MNC length %s, GID1 %s%s', mnc_len ?? '?', info.gid1 ?? '-',
				id?.error ? ', ' + id.error : ''));

			if (!(mnc_len in [ 2, 3 ]))
				return cb({ error: 'mnc_len', detail: 'EF_AD unreadable; set option esim_transfer_mnc_len' }, null, info);

			let sim = { mccmnc: substr(m.imsi, 0, 3 + mnc_len), imsi: m.imsi, gid1: info.gid1 };
			let rec = cfg.server ? { record: { entitlementServer: cfg.server, useHttpPost: cfg.post }, from: 'option' }
			                     : record_for(sim);

			info.mccmnc = sim.mccmnc;

			if (!rec.record)
				return cb({ error: 'no_entitlement_server', detail: sprintf('%s for %s in %s: fetch the operator list (`wwandctl transfer carriers update`), add %s, or set option esim_transfer_server',
					rec.reason, sim.mccmnc, rec.from, ENTITLEMENT_FILE) }, null, info);

			let r = rec.record;

			info.server = r.entitlementServer;
			info.server_from = rec.from;
			trace(ref, 'ts43', sprintf('entitlement server %s (from %s)', r.entitlementServer, rec.from));

			// The transfer type depends on what the SOURCE is: the record has
			// one for a physical SIM and one for an eSIM profile, and an
			// operator may support only one direction (ts43-go entitlement.go
			// toEntitlement). The SIM in use is an eSIM profile when its
			// ICCID is among the eUICC's profiles, or when the modem's slot
			// list says the eUICC is the active card: the profile list can
			// lag a slot switch by minutes (empty 90 s after one on the
			// Chateau, 2026-11-21), the slot list does not. (A bare EID in
			// status is no such word: it can outlive a switch away.)
			let esim_source = !!(eu?.from_slots && eu.active) || length(filter(m.profiles ?? [], (p) => iccid_eq(p.iccid, m.iccid))) > 0;
			let supported = esim_source ? r.supportEsimToEsimTransfer : r.supportPsimToEsimTransfer;

			info.source = esim_source ? 'esim' : 'psim';
			info.transfer_type = cfg.type ?? +((esim_source ? r.transferTypeEsim : r.transferTypePsim) ?? 0);

			if (supported === false)
				return cb({ error: 'unsupported_source', detail: sprintf('the operator\'s record allows no transfer from a%s',
					esim_source ? 'n eSIM profile' : ' physical SIM') }, null, info);

			cb(null, {
				server: r.entitlementServer, post: !!r.useHttpPost, app: r.app ?? 'ap2009',
				vers: r.requestVersion ?? '0', entitlement_version: r.entitlementVersion ?? '9.0',
				app_name: cfg.app_name ?? 'wwand-esim-transfer', app_version: VERSION,
				client_ts43: 'client-Primary-ODSA', os: 'OpenWrt',
				terminal: { id: m.imei, vendor: cfg.vendor ?? 'OWRT', model: cfg.model ?? m.model ?? 'router',
				            sw: cfg.sw ?? 'wwand-esim-transfer-' + VERSION },
				imsi: m.imsi, mnc_len: mnc_len, source_iccid: m.iccid,
				target: target, transfer_type: info.transfer_type,
				eligibility_target: !!r.setCheckEligibilityTargetTerminalId,
				poll_interval: 60 * +(r.acquireConfigurationPollingIntervalMinutes ?? 0) || timing.poll_interval,
				poll_timeout: 60 * +(r.acquireConfigurationPollingTimeoutMinutes ?? 0) || timing.poll_timeout,
				lax_mac: cfg.lax_mac,
			}, info);
		});
	};

	// The router's eUICC, active or not: { eid, physical, active } or null.
	// A one-executor modem reaches only the card in its active slot, so
	// status() knows an EID only while the eUICC is the active card; the
	// slot list names it from any slot (wwand modem_sim_slots, QMI GET SLOT
	// STATUS — slot 2 of the Chateau's RG650E while its physical SIM is in
	// use, 2026-11-21). That is the target of a physical SIM → eSIM move.
	let euicc_of = (ref, cb) => {
		let m = deps.modem(ref);

		if (type(deps.slots) != 'function')
			return cb(valid_eid(m?.eid) ? { eid: m.eid, physical: null, active: true } : null);

		deps.slots(ref, (err, res) => {
			let e = filter(res?.slots ?? [], (x) => x.is_euicc && valid_eid(x.eid))[0];

			// from_slots: `active` is the modem's own word, not an inference
			if (e)
				return cb({ eid: e.eid, physical: e.physical, active: !!e.active, from_slots: true });

			cb(valid_eid(m?.eid) ? { eid: m.eid, physical: null, active: true } : null);
		});
	};

	// the session's fx, shared by a transfer and a check
	let fx_of = (ref) => ({
		http: deps.http,
		timer: deps.timer,
		now: deps.now,
		log: (lvl, msg) => trace(ref, 'ts43', replace(msg, /^ts43: /, '')),
		aka: (data, acb) => deps.card(ref, [ 'aka', substr(data, 2, 32), substr(data, 36, 32) ], (err, res) => {
			if (err && !res?.sw)
				return acb(err);

			acb(null, length(res?.response ?? '') ? res.response : (res?.sw ?? '6F00'));
		}),
	});

	let ts43_start = (ref, cfg, args, cb) => {
		let s = state(ref);
		let m = deps.modem(ref);

		if (s.ts43?.session && !(s.ts43.state in TS43_IDLE))
			return cb({ error: 'busy', detail: 'a transfer is running (ts43_cancel)' });

		if (!m?.imsi)
			return cb({ error: 'no_sim', detail: 'the source SIM is not read yet' });

		let target = args?.target ?? 'external';

		euicc_of(ref, (eu) => {
		let teid = (target == 'router') ? eu?.eid : args?.target_eid;
		let timei = (target == 'router') ? m.imei : args?.target_imei;

		if (!valid_eid(teid))
			return cb({ error: 'invalid_argument', detail: (target == 'router') ? 'this router has no eUICC' : 'target_eid' });

		if (!valid_imei(timei))
			return cb({ error: 'invalid_argument', detail: 'target_imei' });

		trace(ref, 'ts43', sprintf('transfer requested, target %s%s', target,
			(target == 'router' && eu && !eu.active) ? sprintf(' (eUICC in slot %d, not active)', eu.physical) : ''));

		prepare(ref, cfg, { eid: teid, imei: timei }, (err, c, info) => {
			if (err)
				return cb(err);

			// the source already IS a profile of this eUICC: "onto this
			// router" would order a transfer onto the card it is on
			if (target == 'router' && info?.source == 'esim')
				return cb({ error: 'same_card', detail: 'the SIM in use is already a profile on this router\'s eUICC' });

			let t = { state: 'starting', target: target, target_eid: teid, server: c.server, events: [],
			          started: deps.now(), result: null, prompt: null,
			          euicc_slot: (target == 'router' && eu && !eu.active) ? eu.physical : null };

			s.ts43 = t;

			let on;
			on = (ev) => {
				t.state = ev.state;
				push(t.events, { at: deps.now(), ...ev });

				if (length(t.events) > 30)
					shift(t.events);

				deps.log((ev.state in [ 'error', 'denied' ]) ? 'warning' : 'notice',
					sprintf('esim-transfer: ts43 %s%s', ev.state, ev.reason ? ' (' + ev.reason + ')' : ''));
				trace(ref, 'ts43', sprintf('state %s%s', ev.state, ev.reason ? ' (' + ev.reason +
					(ev.error ? ': ' + ev.error : '') + (ev.status ? ', HTTP ' + ev.status : '') + ')' : ''));

				if (ev.state in [ 'message', 'websheet' ])
					t.prompt = ev;
				else if (ev.state != 'polling')
					t.prompt = null;

				if (ev.state == 'download')
					t.result = { activation_code: ev.activation_code, iccid: ev.iccid };

				// the server wants the source profile gone first: when it is an
				// eSIM on this card, release it; a physical SIM has nothing
				// to delete, and the server will not ask for it then
				if (ev.state == 'delete_source')
					release(ref, ev.iccid, true, (err) => {
						if (err && err.error != 'not_found')
							return on({ state: 'error', reason: 'release_source', detail: err });

						t.session.resume('source_deleted');
					});
			};

			t.session = ts43.session(c, fx_of(ref), on);
			cb(null, { started: true, server: c.server, target: target });
			t.session.start();
		}, eu);
		});
	};

	// "Is a transfer possible here?" — the pre-flight. Each step of the
	// checklist is recorded as it is decided: the SIM read, the USIM
	// reachable for AUTHENTICATE, an eUICC for a transfer onto this router,
	// an entitlement server known, the server's login, its CheckEligibility.
	// It stops before ManageSubscription, the first operation that orders
	// anything: the session runs with check_only. Asynchronous: the answer
	// is `started`, the result lands in status().check.
	let check = (ref, cfg, cb) => {
		let s = state(ref);
		let m = deps.modem(ref);

		if (s.check?.running)
			return cb({ error: 'busy', detail: 'a check is running' });

		let k = { running: true, started: deps.now(), items: [], verdict: null };
		let item = (id, ok, detail) => {
			push(k.items, { id: id, ok: ok, detail: detail });
			trace(ref, 'check', sprintf('%s: %s%s', id, (ok == null) ? 'n/a' : ok ? 'ok' : 'NO', detail ? ' — ' + detail : ''));
		};
		let finish = (verdict) => {
			k.running = false;
			k.verdict = verdict;
			k.finished = deps.now();
			trace(ref, 'check', 'verdict: ' + verdict);
		};

		s.check = k;
		cb(null, { started: true });

		if (!m?.imsi) {
			item('sim', false, 'no SIM read on this modem');
			return finish('no SIM');
		}

		item('sim', true, sprintf('IMSI %s…, ICCID %s…', substr(m.imsi, 0, 5), substr(m.iccid ?? '', 0, 7)));

		euicc_of(ref, (eu) => {
		item('euicc', eu ? true : null, !eu ? 'no eUICC on this modem: a transfer can only target another device'
			: eu.active ? sprintf('EID %s… — a profile can come onto this router', substr(eu.eid, 0, 8))
			: sprintf('EID %s… in slot %d (not active) — the install switches to it', substr(eu.eid, 0, 8), eu.physical));

		prepare(ref, cfg, { eid: eu?.eid, imei: m.imei }, (err, c, info) => {
			if (info?.usim === false) {
				item('usim', false, 'the modem does not open a channel to the USIM');
				return finish('not possible on this modem: the USIM cannot be reached for EAP-AKA');
			}

			if (info)
				item('usim', true, sprintf('MNC length %s%s', info.mnc_len ?? '?', info.gid1 ? ', GID1 ' + info.gid1 : ''));

			if (err?.error == 'mnc_len') {
				item('usim', false, err.detail);
				return finish('MNC length unknown: set option esim_transfer_mnc_len');
			}

			if (err?.error == 'unsupported_source') {
				item('server', true, sprintf('%s (from %s)', info.server, info.server_from));
				item('source', false, err.detail);
				return finish('the operator does not transfer from this kind of SIM');
			}

			if (err?.error == 'no_entitlement_server') {
				item('server', false, err.detail);
				return finish('no entitlement server known for this operator');
			}

			if (err) {
				item('prepare', false, why(err));
				return finish('could not prepare: ' + why(err));
			}

			item('server', true, sprintf('%s (from %s)', info.server, info.server_from));
			item('source', true, sprintf('%s, transfer type %d', (info.source == 'esim') ? 'eSIM profile' : 'physical SIM',
				info.transfer_type));

			let sess;
			let seen_auth = false;

			sess = ts43.session({ ...c, check_only: true }, fx_of(ref), (ev) => {
				if (ev.state == 'eligibility') {
					seen_auth = true;
					item('login', true, 'EAP-AKA accepted, token received');
				}

				if (ev.state == 'eligible') {
					item('eligible', true, 'CheckEligibility: this subscription can be transferred');
					finish('possible');
				}

				if (ev.state == 'denied') {
					item('eligible', false, sprintf('%s refused (OperationResult %s, PrimaryAppEligibility %s%s)', ev.reason,
						ev.operation_result ?? '-', ev.eligibility ?? '-', ev.text ? ', ' + ev.text : ''));
					finish('the operator says no for this subscription or device');
				}

				if (ev.state == 'error') {
					let d = sprintf('%s: %s%s', ev.reason, ev.error ?? '?', ev.status ? ' (HTTP ' + ev.status + ')' : '');

					item(seen_auth ? 'eligible' : 'login', false, d);
					finish(seen_auth ? 'the eligibility check failed' : (ev.status == 403 || ev.status == 401)
						? 'the server refused the login (it may not accept a router)' : 'the server could not be reached or logged into');
				}
			});
			sess.start();
		}, eu);
		});
	};

	let ts43_view = (t) => t ? { state: t.state, target: t.target, target_eid: t.target_eid, server: t.server,
		started: t.started, prompt: t.prompt, result: t.result, waiting: t.session?.waiting(),
		events: map(t.events, (e) => ({ at: e.at, state: e.state, reason: e.reason, error: e.error, status: e.status })) } : null;

	let ts43_fail = (ref, t, reason) => {
		t.state = 'error';
		push(t.events, { at: deps.now(), state: 'error', reason: reason });
		trace(ref, 'ts43', 'install failed: ' + reason);
	};

	// the code is for this router: download it onto the eUICC, enable it, and
	// report it to the entitlement server (ManageSubscription type 4)
	let ts43_install = (ref, cb) => {
		let t = state(ref).ts43;

		if (t?.state != 'download' || t.target != 'router')
			return cb({ error: 'not_ready', detail: 'no activation code for this router yet' });

		// on a one-executor modem the eUICC may sit in another slot: switch to
		// it, then wait until its ISD-R answers (the card is re-read after a
		// switch; wwand answers esim ops only once it is up)
		let on_euicc = (go) => {
			if (t.euicc_slot == null || type(deps.switch_slot) != 'function')
				return go();

			trace(ref, 'ts43', sprintf('install: switching to the eUICC in slot %d', t.euicc_slot));
			push(t.events, { at: deps.now(), state: 'switching', reason: sprintf('slot %d', t.euicc_slot) });

			deps.switch_slot(ref, t.euicc_slot, (err) => {
				if (err)
					return ts43_fail(ref, t, 'slot switch: ' + why(err));

				let started = deps.now();
				let wait;
				wait = () => esim(ref, 'profiles')((e, r) => {
					if (!e)
						return go();

					if (deps.now() - started > 90)
						return ts43_fail(ref, t, 'the eUICC did not answer after the slot switch');

					deps.timer(3000, wait);
				});
				wait();
			});
		};

		cb(null, { installing: true, switching_to_slot: t.euicc_slot });
		t.state = 'installing';
		push(t.events, { at: deps.now(), state: 'installing' });

		on_euicc(() => {
		// the profiles before, so the new one is known even when the server
		// named no ICCID (ProfileIccid is optional, TS.43 v13.0 DownloadInfo)
		esim(ref, 'profiles')((e0, before) => {
			let had = map(before?.profiles ?? [], (p) => p.iccid);

			trace(ref, 'ts43', 'install: downloading the profile');

			esim(ref, 'download', { activation_code: t.result.activation_code })((err) => {
				if (err)
					return ts43_fail(ref, t, 'download: ' + why(err));

				let look;
				look = () => esim(ref, 'download_status')((e2, ds) => {
					if (!e2 && ds?.state == 'running')
						return deps.timer(2000, look);

					if (e2 || ds?.state != 'done')
						return ts43_fail(ref, t, 'download: ' + (e2 ? why(e2) : (result_line(ds?.log) ?? ds?.state)));

					esim(ref, 'profiles')((e4, after) => {
						let fresh = filter(after?.profiles ?? [], (p) => !length(filter(had, (h) => iccid_eq(h, p.iccid))));
						let iccid = t.result.iccid ?? ((length(fresh) == 1) ? fresh[0].iccid : null);

						if (!iccid)
							return ts43_fail(ref, t, 'new_profile_unknown');

						t.result.iccid = iccid;
						trace(ref, 'ts43', sprintf('install: downloaded %s…, enabling', substr(iccid, 0, 7)));

						esim(ref, 'enable', { iccid: iccid, force: true })((e3) => {
							if (e3)
								return ts43_fail(ref, t, 'enable: ' + why(e3));

							// the daemon asserts option sim_slot at every
							// bring-up: left on the physical SIM's slot, the
							// next restart would go back to it
							if (t.euicc_slot != null)
								trace(ref, 'ts43', sprintf('install: set option sim_slot \'%d\' on this modem, or a restart returns to the physical SIM', t.euicc_slot));

							t.session.installed(iccid);
						});
					});
				});
				deps.timer(2000, look);
			});
		});
		});
	};

	return {
		release: release,
		deliver: deliver,
		check: check,
		carriers_update: carriers_update,

		discovery: (ref, cfg, cb) => {
			trace(ref, 'discovery', sprintf('asking SM-DS %s', cfg.smds ?? 'lpa.ds.gsma.com (default)'));

			esim(ref, 'discovery', cfg.smds ? { smds: cfg.smds } : {})((err, res) => {
				let s = state(ref);

				s.discovery = { at: deps.now(), servers: res?.servers ?? [], error: err ? why(err) : null };
				trace(ref, 'discovery', err ? 'failed: ' + why(err)
					: length(res?.servers ?? []) ? 'events at ' + join(', ', res.servers) : 'no event for this EID');
				cb(err, { servers: res?.servers ?? [] });
			});
		},

		import: (ref, code, cc, cb) => {
			if (!match(code ?? '', /^LPA:1\$[^$]+\$/))
				return cb({ error: 'invalid_argument', detail: 'activation code LPA:1$<SM-DP+>$<matching id>' });

			trace(ref, 'import', sprintf('download from %s%s', split(code, '$')[1], length(cc ?? '') ? ' (with confirmation code)' : ''));
			esim(ref, 'download', { activation_code: code, confirmation_code: cc })((err, res) => {
				trace(ref, 'import', err ? 'refused: ' + why(err) : 'started');
				cb(err, res);
			});
		},

		// the running download's state and live lpac log (wwand's own
		// download_status), for the page's progress view
		download_status: (ref, cb) => esim(ref, 'download_status')(cb),

		meta: (ref, cb) => deps.card(ref, [ 'profiles' ], (err, res) => {
			if (err && !res?.response)
				return cb(err);

			cb(null, meta.parse_profiles(res.response));
		}),

		// Can this modem reach the USIM the way TS.43 needs it? EF_AD/GID1,
		// then an AUTHENTICATE with an all-zero AUTN: a working USIM refuses
		// its MAC with 9862 (TS 31.102 7.3) and changes nothing — the MAC is
		// checked before the sequence number (TS 33.102 6.3.3), so no SQN
		// moves. A DB/DC answer would mean the MAC matched, which a zero AUTN
		// cannot. { mnc_len, gid1, usim_channel, aka_sw, verdict }
		usim_check: (ref, cb) => deps.card(ref, [ 'identity' ], (err, id) => {
			let out = { mnc_len: id?.mnc_len || null, gid1: id?.group_id || null,
			            usim_channel: !(id?.error == 'usim_channel'), identity_error: err ? (id?.error ?? err.error) : null };

			if (!out.usim_channel)
				return cb(null, { ...out, verdict: 'the modem does not open a channel to the USIM (partial AID)' });

			deps.card(ref, [ 'aka', '00000000000000000000000000000000', '00000000000000000000000000000000' ], (e2, a) => {
				out.aka_sw = a?.sw ?? null;
				out.aka_error = a?.error ?? e2?.error ?? null;
				out.verdict = (a?.sw == '9862') ? 'ok: the USIM answers AUTHENTICATE over this modem'
					: (a?.error == 'usim_channel') ? 'the modem does not open a channel to the USIM'
					: sprintf('unexpected answer (%s)', a?.sw ?? a?.error ?? e2?.error ?? '?');
				trace(ref, 'usim', sprintf('%s (EF_AD MNC %s, AUTHENTICATE SW %s)', out.verdict, out.mnc_len ?? '?', out.aka_sw ?? '-'));
				cb(null, out);
			});
		}),

		ts43_start: ts43_start,
		ts43_install: ts43_install,
		ts43_resume: (ref, args, cb) => {
			let t = state(ref).ts43;

			if (!t?.session)
				return cb({ error: 'not_running' });

			trace(ref, 'ts43', sprintf('user answer: %s%s', args?.kind ?? '?',
				(args?.kind == 'message') ? (args?.accepted ? ' (accepted)' : ' (rejected)') : ''));

			let r = (args?.kind == 'message')
				? t.session.resume('message', { response: args?.response ?? '', accepted: !!args?.accepted })
				: t.session.resume(args?.kind, args?.next);

			cb(r, r ? null : { resumed: args?.kind });
		},
		ts43_cancel: (ref, cb) => {
			let t = state(ref).ts43;

			trace(ref, 'ts43', 'cancelled by the user');
			t?.session?.cancel();
			cb(null, { cancelled: !!t });
		},

		// every 10 s (wwand plugin tick): deliver what is pending — at once on
		// a new data session, else every timing.retry
		tick: (ref) => {
			let s = state(ref);
			let tok = deps.online(ref);
			let open = filter(releases(ref), (r) => r.state == 'delivering');

			if (!length(open) || s.delivering)
				return;

			let fresh = (tok != null && tok != s.token);
			let due = length(filter(open, (r) => deps.now() - (r.last_try ?? 0) >= timing.retry));

			s.token = tok;

			if (fresh || due)
				deliver(ref);
		},

		status: (ref) => {
			let s = state(ref);
			let m = deps.modem(ref);

			return {
				releases: releases(ref),
				discovery: s.discovery,
				ts43: ts43_view(s.ts43),
				check: s.check,
				hint: hints.hint_for(m?.imsi),
				carriers: { count: length(carriers_file().records), fetched: carriers_file().fetched,
				            label: carriers_file().label },
				now: deps.now(),
			};
		},

		log: (ref) => state(ref).trace,

		forget: (ref, iccid) => {
			let s = state(ref);

			s.releases = filter(releases(ref), (r) => !(iccid_eq(r.iccid, iccid) && r.state in [ 'delivered', 'failed' ]));
			save();
		},
	};
}

// One esim-transfer-card run under the bridge's claim (esim_bridge
// session_run): the card's answer arrives as its `card_result` event.
function card_runner(pd, card)
{
	return (ref, args, cb) => {
		let br = pd.esim_bridge();

		if (!br)
			return cb({ error: 'esim_not_installed' });

		for (let a in args)
			if (!match(a, /^[A-Za-z0-9_]+$/))
				return cb({ error: 'invalid_argument' });

		let entry = pd.modem_of(ref);
		let result = null;
		let go = (slot) => {
			let r = br.session_run(ref, slot, 'esim-transfer', sprintf('%s %s', card, join(' ', args)), () => 'debug',
				(rec, reply) => {
					if (rec.event == 'card_result')
						result = rec.payload;
					reply({});
				},
				(err) => cb(result ? null : (err ?? { error: 'no_result' }), result));

			if (r?.error)
				cb(r);
		};

		// the active card's slot; a modem that cannot list them gets slot 1
		if (type(entry?.modem?.slot_status) != 'function')
			return go(1);

		entry.modem.slot_status((err, slots) => {
			let a = filter(slots ?? [], (s) => s.active)[0];

			go((!err && a?.physical != null) ? +a.physical : 1);
		});
	};
}

// An activation code as an SVG QR for the LuCI page, from qrencode (the
// optional `qrencode` package) — so a phone can scan what TS.43 issued for
// it. { svg } or { svg: null } without the tool. Only LPA codes, and only the
// characters an LPA code has, reach the shell.
function qr_svg(text)
{
	if (fs.access('/usr/bin/qrencode', 'x') != true || !match(text ?? '', /^LPA:1\$[A-Za-z0-9.:$_-]{1,250}$/))
		return { svg: null };

	let p = fs.popen(sprintf("/usr/bin/qrencode -t SVG -o - '%s'", text));
	let svg = p?.read('all');

	p?.close();

	return { svg: (substr(svg ?? '', 0, 5) == '<?xml' || index(svg ?? '', '<svg') >= 0) ? svg : null };
}

const PLUGIN = {
	name: 'esim_transfer',
	options: OPTIONS,

	create: function(pd) {
		// fs.mkdir() makes one level: a router without /etc/wwand (no other
		// plugin made it) would get no state directory at all, and every
		// write into it would fail (HW-seen on the Chateau, 2026-11-21)
		fs.mkdir('/etc/wwand');
		fs.mkdir(STATE_DIR);

		let eng = engine({
			// the guarded path (wwand plugin dep modem_esim: another plugin's
			// esim_guard, sim_in_use), as the user's own ubus call would run;
			// the bare bridge only on a wwand that predates that dep
			esim: (ref, op, params, cb) => {
				if (type(pd.modem_esim) == 'function')
					return pd.modem_esim(ref, op, params, cb);

				let br = pd.esim_bridge();

				return br ? br.modem_esim(ref, op, params, cb) : cb({ error: 'esim_not_installed' });
			},
			card: card_runner(pd, CARD),
			modem: (ref) => {
				let m = pd.modem_of(ref)?.modem;

				return m ? { imsi: m.info?.imsi, iccid: m.info?.iccid, imei: m.info?.imei,
				             model: m.info?.model, eid: m.esim_info?.eid, profiles: m.esim_info?.profiles } : null;
			},
			online: pd.connection_token,
			slots: (ref, cb) => (type(pd.sim_slots) == 'function') ? pd.sim_slots(ref, cb) : cb({ error: 'unsupported' }),
			switch_slot: (type(pd.sim_switch_slot) == 'function') ? pd.sim_switch_slot : null,
			http: http.request,
			timer: (ms, fn) => uloop.timer(ms, fn),
			now: () => time(),
			log: pd.log,
			read: (p) => fs.readfile(p),
			write: (p, t) => fs.writefile(p, t) != null,
		});

		let wrap = (fn) => (ref, ext, args, cb) => fn(ref, cfg_of(ext), args ?? {}, cb);

		return {
			tick: (ref, ext) => eng.tick(ref),

			status: (ref, ext) => {
				let open = filter(eng.status(ref).releases, (r) => r.state == 'delivering');

				return length(open) ? { label: 'eSIM release', level: 'warn',
					text: sprintf('%d deleted profile(s): notification not delivered yet', length(open)) } : null;
			},

			ops: {
				status: (ref, ext, args, cb) => cb(null, eng.status(ref)),
				release: wrap((ref, cfg, a, cb) => eng.release(ref, a.iccid, !!a.force, cb)),
				deliver: wrap((ref, cfg, a, cb) => eng.deliver(ref, (err) => cb(err, eng.status(ref).releases))),
				forget: wrap((ref, cfg, a, cb) => cb(null, eng.forget(ref, a.iccid))),
				discovery: wrap((ref, cfg, a, cb) => eng.discovery(ref, cfg, cb)),
				import: wrap((ref, cfg, a, cb) => eng.import(ref, a.activation_code, a.confirmation_code, cb)),
				meta: wrap((ref, cfg, a, cb) => eng.meta(ref, cb)),
				usim_check: wrap((ref, cfg, a, cb) => eng.usim_check(ref, cb)),
				check: wrap((ref, cfg, a, cb) => eng.check(ref, cfg, cb)),
				carriers_update: wrap((ref, cfg, a, cb) => eng.carriers_update(ref, cfg, cb)),
				log: (ref, ext, args, cb) => cb(null, { lines: eng.log(ref) }),
				download_status: (ref, ext, args, cb) => eng.download_status(ref, cb),
				ts43_start: wrap((ref, cfg, a, cb) => eng.ts43_start(ref, cfg, a, cb)),
				ts43_resume: wrap((ref, cfg, a, cb) => eng.ts43_resume(ref, a, cb)),
				ts43_install: wrap((ref, cfg, a, cb) => eng.ts43_install(ref, cb)),
				ts43_cancel: wrap((ref, cfg, a, cb) => eng.ts43_cancel(ref, cb)),
				qr: wrap((ref, cfg, a, cb) => cb(null, qr_svg(a.text))),
			},
			// what the page polls: none of these touches the card or the
			// network (download_status reads the bridge's own record)
			read_ops: [ 'status', 'log', 'download_status' ],
		};
	},
};

export { PLUGIN, engine, cfg_of, notifications_of, carriers_of, card_runner };
