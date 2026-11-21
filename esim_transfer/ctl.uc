// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// `wwandctl transfer`: eSIM transfer from the command line. wwandctl
// require()s the shim ctl/transfer.uc, which hands back this module's
// COMMAND ({ run(ctx, args), help }); ctx is { call, call_ok, status,
// resolve_modem } (wwandctl.uc, the plugin-command dispatch).
//
// An ES module, precompiled to bytecode; exports COMMAND and the pure
// formatter status_lines for the tests.

'use strict';

import * as fs from 'fs';

let plugin_call = (ctx, modem, op, args) =>
	ctx.call_ok('modem_plugin', { modem: modem, plugin: 'esim_transfer', op: op, args: args ?? {} });

// a trace timestamp as HH:MM:SS
function localtime_s(t)
{
	let tm = localtime(t ?? 0);

	return sprintf('%02d:%02d:%02d', tm.hour, tm.min, tm.sec);
}

// a duration as a person reads it
function ago(now, t)
{
	let s = int(now - (t ?? now));

	return (s < 90) ? sprintf('%d s ago', s) : (s < 5400) ? sprintf('%d min ago', int((s + 30) / 60))
		: sprintf('%d h ago', int(s / 3600));
}

// the plugin's status as [ label, text ] lines: what is not through first
function status_lines(st, now)
{
	let out = [];

	for (let r in st?.releases ?? []) {
		let what = sprintf('%s%s', r.iccid, r.provider ? ' (' + r.provider + ')' : '');

		if (r.state == 'delivered')
			push(out, [ 'released', sprintf('%s — operator notified %s', what, ago(now, r.delivered)) ]);
		else
			push(out, [ 'releasing', sprintf('%s — notification NOT delivered yet (%d tries%s)', what, r.tries ?? 0,
				r.error ? ', last: ' + r.error : '') ]);
	}

	if (st?.discovery)
		push(out, [ 'discovery', length(st.discovery.servers) ? join(', ', st.discovery.servers)
			: (st.discovery.error ? 'failed: ' + st.discovery.error : 'no profile waiting for this EID') ]);

	let t = st?.ts43;

	if (t) {
		push(out, [ 'ts43', sprintf('%s (target %s, %s)', t.state, t.target, t.server) ]);

		if (t.prompt?.state == 'message')
			push(out, [ '  asks', t.prompt.message ?? '?' ]);

		if (t.prompt?.state == 'websheet')
			push(out, [ '  open', t.prompt.url ]);

		if (t.result?.activation_code)
			push(out, [ '  code', t.result.activation_code ]);

		let last = t.events?.[length(t.events) - 1];

		if (last?.reason)
			push(out, [ '  reason', sprintf('%s%s', last.reason, last.error ? ' (' + last.error + ')' : '') ]);
	}

	if (st?.hint) {
		let h = st.hint;

		push(out, [ 'operator', h.operator ]);
		push(out, [ '  new code', h.code ]);
		push(out, [ '  code use', h.reusable ? 'reusable (' + h.reusable_source + ')' : 'single use (' + h.reusable_source + ')' ]);

		if (h.note)
			push(out, [ '  note', h.note ]);
	}

	return length(out) ? out : [ [ 'transfer', 'nothing released, nothing running' ] ];
}

// an activation code as a QR on the terminal, when qrencode is installed
function qr(code)
{
	if (fs.access('/usr/bin/qrencode', 'x') != true || !match(code, /^LPA:1\$[A-Za-z0-9.:$_-]+$/))
		return;

	let p = fs.popen(sprintf("/usr/bin/qrencode -t UTF8 '%s'", code));

	if (p) {
		print(p.read('all'));
		p.close();
	}
}

const COMMAND = {
	help: [
		'transfer [modem] [status]             eSIM transfer: releases, discovery, TS.43, operator hints',
		'transfer [modem] release <iccid> [--force]   disable + delete a profile, deliver its notification',
		'transfer [modem] deliver              retry the delete notifications not delivered yet',
		'transfer [modem] discovery            profiles an operator queued for this EID (SM-DS)',
		'transfer [modem] import <code> [cc]   download an activation code (LPA:1$...) [confirmation code]',
		'transfer [modem] check                is a transfer possible? (TS.43 login + eligibility, orders nothing)',
		'transfer [modem] usim                 can this modem reach the USIM for EAP-AKA (read-only probe)',
		'transfer [modem] log                  the debug trace: every step, status word and server verdict',
		'transfer [modem] meta                 the card\'s profiles with their Device Change settings (SGP.22 v3)',
		'transfer [modem] ts43 start --router  TS.43: move this SIM onto this router\'s eUICC',
		'transfer [modem] ts43 start <eid> <imei>     TS.43: an activation code for another device',
		'transfer [modem] ts43 accept|reject [text]   answer the operator\'s question',
		'transfer [modem] ts43 continue [ManageSubscription]   after the operator\'s web page',
		'transfer [modem] ts43 install | cancel',
	],

	run: function(ctx, args) {
		let r = ctx.resolve_modem(ctx.status(), args[0]);
		let rest = r.consumed ? slice(args, 1) : args;
		let op = rest[0] ?? 'status';
		let show = () => {
			let st = plugin_call(ctx, r.modem, 'status');

			for (let l in status_lines(st, time()))
				printf('%-12s%s\n', l[0], l[1]);

			return st;
		};

		switch (op) {
		case 'status': {
			let st = show();

			if (st?.ts43?.result?.activation_code && st.ts43.target == 'external')
				qr(st.ts43.result.activation_code);

			break;
		}

		case 'release':
			plugin_call(ctx, r.modem, 'release', { iccid: rest[1], force: index(rest, '--force') >= 0 });
			printf('released %s — delivering its notification (`wwandctl transfer` shows when it is through)\n', rest[1]);
			break;

		case 'deliver':
			plugin_call(ctx, r.modem, 'deliver');
			show();
			break;

		case 'discovery': {
			let res = plugin_call(ctx, r.modem, 'discovery');

			if (!length(res?.servers ?? []))
				printf('no profile waiting for this EID\n');

			for (let s in res?.servers ?? [])
				printf('%s   (wwandctl transfer import \'LPA:1$%s$\')\n', s, s);

			break;
		}

		case 'import':
			plugin_call(ctx, r.modem, 'import', { activation_code: rest[1], confirmation_code: rest[2] });
			printf('download started — `wwandctl esim download-status` follows it\n');
			break;

		case 'meta': {
			let res = plugin_call(ctx, r.modem, 'meta');

			for (let p in res?.profiles ?? [])
				printf('%-22s %-9s %-20s %s\n', p.iccid, p.enabled ? 'enabled' : 'disabled', p.provider ?? '',
					!p.dc ? 'no Device Change (SGP.22 v2 card or not set)'
					: (p.dc.method == 'stored_ac') ? sprintf('stored code %s%s', p.dc.activation_code,
						p.dc.delete_old_profile ? ' (delete this profile first)' : '')
					: sprintf('ask SM-DP+ %s', p.dc.smdp));

			break;
		}

		// the pre-flight: started, then followed until it has a verdict
		case 'check': {
			plugin_call(ctx, r.modem, 'check');

			let k = null;

			for (let i = 0; i < 60; i++) {
				k = plugin_call(ctx, r.modem, 'status')?.check;

				if (!k?.running)
					break;

				sleep(1000);
			}

			for (let it in k?.items ?? [])
				printf('%-3s %-10s %s\n', (it.ok == null) ? '-' : it.ok ? 'ok' : 'NO', it.id, it.detail ?? '');

			printf('\n%s\n', k?.running ? 'still running — `wwandctl transfer` shows the result'
				: 'result: ' + (k?.verdict ?? '?'));
			exit((k?.verdict == 'possible') ? 0 : 1);
		}

		case 'log':
			for (let l in plugin_call(ctx, r.modem, 'log')?.lines ?? [])
				printf('%s %-9s %s\n', localtime_s(l.at), l.area, l.msg);
			break;

		case 'usim': {
			let res = plugin_call(ctx, r.modem, 'usim_check');

			printf('%-13s%s\n%-13s%s\n%-13s%s\n%-13s%s\n', 'USIM', res?.verdict ?? '?',
				'MNC length', res?.mnc_len ?? '? (EF_AD unreadable: set option esim_transfer_mnc_len)',
				'GID1', res?.gid1 ?? '-', 'AUTHENTICATE', res?.aka_sw ?? res?.aka_error ?? '-');
			break;
		}

		case 'ts43': {
			let sub = rest[1] ?? 'status';
			let call = (o, a) => plugin_call(ctx, r.modem, o, a);

			if (sub == 'start') {
				let a = (rest[2] == '--router') ? { target: 'router' }
					: { target: 'external', target_eid: rest[2], target_imei: rest[3] };
				let res = call('ts43_start', a);

				printf('TS.43 transfer started against %s — `wwandctl transfer` follows it\n', res?.server ?? '?');
			}
			else if (sub == 'accept' || sub == 'reject')
				call('ts43_resume', { kind: 'message', accepted: sub == 'accept', response: rest[2] ?? '' });
			else if (sub == 'continue')
				call('ts43_resume', { kind: 'websheet', next: rest[2] ?? 'AcquireConfiguration' });
			else if (sub == 'install')
				call('ts43_install');
			else if (sub == 'cancel')
				call('ts43_cancel');
			else if (sub != 'status')
				die(sprintf('unknown ts43 step %J — see `wwandctl help`', sub));

			show();
			break;
		}

		default:
			die(sprintf('unknown transfer op %J — see `wwandctl help`', op));
		}
	},
};

export { COMMAND, status_lines };
