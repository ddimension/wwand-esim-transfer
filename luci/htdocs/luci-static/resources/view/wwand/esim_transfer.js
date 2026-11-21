'use strict';
'require view';
'require rpc';
'require ui';
'require dom';
'require poll';

/* eSIM transfer (wwand-esim-transfer), per modem:
   - "Is a transfer possible?": the pre-flight checklist (SIM, USIM, eUICC,
     entitlement server, login, eligibility), stopping before anything is
     ordered;
   - the card's profiles, each with Release, and every release as its steps
     (disable → delete → operator notified) with times and reasons;
   - Import (a code pasted or read from a QR image) with the download's live
     progress, and the SM-DS lookup;
   - the TS.43 transfer as a step bar plus its timeline;
   - the plugin's debug trace (masked), to copy into a report.

   Status, trace and download progress come through modem_plugin_status and
   modem_esim_profiles (read acl); everything that changes the card or talks
   to the operator through modem_plugin (write acl) — rpcd grants methods,
   not arguments.

   Every string that comes from the card, the operator or the daemon goes into
   E() inside an ARRAY: dom.append() puts a bare string through innerHTML
   (luci.js:1394-1396, as luci-app-wwand's esim.js notes), and an operator's
   prompt text is not ours to trust. */

var callStatus = rpc.declare({ object: 'wwand', method: 'status', expect: { modems: {} } });
var callProfiles = rpc.declare({ object: 'wwand', method: 'modem_esim_profiles', params: [ 'modem' ], expect: {} });
var callPluginStatus = rpc.declare({ object: 'wwand', method: 'modem_plugin_status',
	params: [ 'modem', 'plugin', 'op' ], expect: {} });
var callPlugin = rpc.declare({ object: 'wwand', method: 'modem_plugin',
	params: [ 'modem', 'plugin', 'op', 'args' ], expect: {} });

var PLUGIN = 'esim_transfer';

/* TS.43 states in the order a transfer goes through them; the bar shows them */
var TS43_STEPS = [
	[ 'authenticating', _('Login (EAP-AKA)') ],
	[ 'eligibility', _('Eligibility') ],
	[ 'subscribing', _('Order') ],
	[ 'polling', _('Waiting for the operator') ],
	[ 'download', _('Activation code') ],
	[ 'installing', _('Install') ],
	[ 'activating', _('Activation') ],
	[ 'done', _('Done') ],
];
var TS43_RUNNING = [ 'starting', 'authenticating', 'eligibility', 'subscribing', 'polling', 'installing', 'activating', 'delete_source' ];

var CHECK_LABELS = {
	sim: _('SIM in use read'),
	euicc: _('eUICC on this router'),
	usim: _('USIM reachable for AUTHENTICATE'),
	server: _('Entitlement server known'),
	source: _('Source SIM and transfer type'),
	prepare: _('Preparation'),
	login: _('Login at the operator (EAP-AKA)'),
	eligible: _('Operator allows the transfer'),
};

var RELEASE_STEPS = { disable: _('Disable'), delete: _('Delete'), notify: _('Operator notified') };

function plugin(modem, op, args) {
	return callPlugin(modem, PLUGIN, op, args || {}).then(function(res) {
		if (res && res.ok === false)
			throw new Error((res.error || '?') + (res.detail ? ': ' + (typeof res.detail == 'string' ? res.detail : JSON.stringify(res.detail)) : ''));
		return res;
	});
}

function readOp(modem, op) {
	return L.resolveDefault(callPluginStatus(modem, PLUGIN, op), {});
}

function notify(text, kind) {
	ui.addNotification(null, E('p', {}, [ text ]), kind || 'info');
}

function hhmmss(t) {
	if (!t)
		return '';
	var d = new Date(t * 1000);
	return d.toTimeString().substr(0, 8);
}

function mark(ok) {
	/* a running step, a passed one, a failed one, one that does not apply */
	if (ok === null || ok === undefined)
		return E('span', { 'style': 'color:#888' }, [ '…' ]);
	return E('span', { 'style': ok ? 'color:#2a2' : 'color:#c22', 'title': ok ? _('ok') : _('failed') }, [ ok ? '✔' : '✘' ]);
}

function row(label, value) {
	return E('tr', { 'class': 'tr' }, [
		E('td', { 'class': 'td left', 'width': '25%' }, [ label ]),
		E('td', { 'class': 'td left' }, Array.isArray(value) ? value : [ value == null ? '' : String(value) ]),
	]);
}

/* a QR image chosen by the user → the text in it. BarcodeDetector exists in
   Chromium-based browsers (not in Firefox, 2026-11); without it the code is
   pasted. */
function decodeQr(file) {
	if (typeof window.BarcodeDetector != 'function')
		return Promise.reject(new Error(_('This browser cannot read QR images; paste the code instead.')));

	return createImageBitmap(file).then(function(bmp) {
		return new window.BarcodeDetector({ formats: [ 'qr_code' ] }).detect(bmp);
	}).then(function(codes) {
		if (!codes.length)
			throw new Error(_('No QR code found in this image.'));
		return codes[0].rawValue;
	});
}

/* the bridge log's progress lines (lpac's ES9+/ES10 steps) */
function progressLines(log) {
	return String(log || '').split('\n').filter(function(l) {
		return /^(progress|result|data):/.test(l);
	}).slice(-8);
}

return view.extend({
	load: function() {
		return L.resolveDefault(callStatus(), {}).then(function(modems) {
			var names = Object.keys(modems || {}).sort();

			return Promise.all(names.map(function(n) {
				return Promise.all([
					readOp(n, 'status'),
					L.resolveDefault(callProfiles(n), {}),
					readOp(n, 'log'),
					readOp(n, 'download_status'),
				]);
			})).then(function(all) {
				return names.map(function(n, i) {
					return { modem: n, info: modems[n] || {}, st: all[i][0] || {},
					         profiles: (all[i][1] || {}).profiles || [],
					         log: (all[i][2] || {}).lines || [], dl: all[i][3] || {} };
				});
			});
		});
	},

	/* is anything in flight? then the page polls fast */
	busy: function(modems) {
		return (modems || []).some(function(m) {
			var st = m.st || {};
			return (st.check && st.check.running) ||
				(st.releases || []).some(function(r) { return r.state == 'delivering' || r.state == 'releasing'; }) ||
				(st.ts43 && TS43_RUNNING.indexOf(st.ts43.state) >= 0) ||
				(m.dl && m.dl.state == 'running');
		});
	},

	reload: function() {
		return this.load().then(L.bind(function(m) {
			this.modems = m;
			/* keep the debug log open across a refresh */
			var open = {};
			this.root.querySelectorAll('details[data-modem]').forEach(function(d) { open[d.getAttribute('data-modem')] = d.open; });
			dom.content(this.root, this.renderAll(m, open));
		}, this));
	},

	run: function(p, done) {
		var self = this;

		return p.then(function(res) {
			if (done)
				notify(done, 'info');
			return self.reload();
		}).catch(function(e) {
			notify(e.message, 'warning');
			return self.reload();
		});
	},

	/* --- is a transfer possible? ---------------------------------------- */

	renderCheck: function(m) {
		var self = this;
		var k = m.st.check;
		var body = [
			E('h4', {}, _('Is a transfer possible?')),
			E('p', { 'class': 'cbi-value-description' }, _('Asks the operator\'s entitlement server whether this SIM\'s subscription could be transferred (GSMA TS.43: login with the SIM, then CheckEligibility). Nothing is ordered or changed: the check stops before the first step that would.')),
		];

		if (k) {
			body.push(E('table', { 'class': 'table' }, (k.items || []).map(function(i) {
				return E('tr', { 'class': 'tr' }, [
					/* a checklist item without a verdict does not apply here
					   (no eUICC: only another device can be the target) —
					   not "running", which … would say */
					E('td', { 'class': 'td', 'width': '2em' }, [ (i.ok == null)
						? E('span', { 'style': 'color:#888', 'title': _('does not apply') }, [ '–' ]) : mark(i.ok) ]),
					E('td', { 'class': 'td left', 'width': '30%' }, [ CHECK_LABELS[i.id] || i.id ]),
					E('td', { 'class': 'td left' }, [ i.detail || '' ]),
				]);
			}).concat(k.running ? [ E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td' }, [ mark(null) ]),
				E('td', { 'class': 'td left', 'colspan': 2 }, [ _('checking…') ]) ]) ] : [])));

			if (k.verdict)
				body.push(E('p', {}, [ E('strong', {}, [ _('Result: ') ]),
					E('span', { 'style': (k.verdict == 'possible') ? 'color:#2a2' : 'color:#c22' }, [ k.verdict ]),
					' (' + hhmmss(k.finished) + ')' ]));
		}

		/* where the entitlement servers come from: the fetched operator list */
		var c = m.st.carriers || {};
		body.push(E('p', {}, [
			c.count ? _('Operator list: %d records (%s, fetched %s).').format(c.count, c.label || '?', c.fetched ? new Date(c.fetched * 1000).toISOString().substr(0, 16).replace('T', ' ') : '?')
			        : _('No operator list yet: without it (or option esim_transfer_server) no entitlement server is known.'),
			' ',
			E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
				return self.run(plugin(m.modem, 'carriers_update'), _('Operator list updated.'));
			}) }, c.count ? _('Update list') : _('Fetch list')),
		]));

		body.push(E('button', { 'class': 'btn cbi-button cbi-button-action', 'disabled': (k && k.running) ? true : null,
			'click': ui.createHandlerFn(this, function() { return self.run(plugin(m.modem, 'check')); }) },
			(k && k.running) ? _('Checking…') : _('Check now')));

		return E('div', { 'class': 'cbi-section' }, body);
	},

	/* --- profiles and releases ------------------------------------------- */

	renderProfiles: function(m) {
		var self = this;
		var rows = m.profiles.map(function(p) {
			return E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left' }, [ p.iccid || '' ]),
				E('td', { 'class': 'td left' }, [ p.state || '' ]),
				E('td', { 'class': 'td left' }, [ p.provider || p.nickname || '' ]),
				E('td', { 'class': 'td right' }, E('button', { 'class': 'btn cbi-button cbi-button-remove',
					'click': ui.createHandlerFn(self, function() {
						if (!confirm(_('Release profile %s? It is disabled and DELETED from this card; the operator is told so it can issue it to another device. This cannot be undone here.').format(p.iccid)))
							return;

						/* plain first: wwand refuses a profile whose card is
						   in use by an interface (sim_in_use) or managed by an
						   eIM (esim_managed), and says why; only then, and only
						   if the user agrees to that reason, with force */
						return plugin(m.modem, 'release', { iccid: p.iccid }).then(function() {
							return self.reload();
						}).catch(function(e) {
							if (!/sim_in_use|esim_managed/.test(e.message) ||
							    !confirm(_('wwand refused: %s\n\nRelease anyway?').format(e.message)))
								return notify(e.message, 'warning'), self.reload();

							return self.run(plugin(m.modem, 'release', { iccid: p.iccid, force: true }));
						});
					}) }, _('Release'))),
			]);
		});

		return E('div', { 'class': 'cbi-section' }, [
			E('h4', {}, _('Profiles on this card')),
			rows.length ? E('table', { 'class': 'table' }, rows) : E('p', {}, E('em', {}, _('No profile, or no eUICC in the active slot.'))),
		]);
	},

	renderReleases: function(m) {
		var self = this;
		var rel = m.st.releases || [];

		if (!rel.length)
			return E([]);

		return E('div', { 'class': 'cbi-section' }, [
			E('h4', {}, _('Releases')),
			E('table', { 'class': 'table' }, rel.slice().reverse().map(function(r) {
				var steps = (r.steps || []).map(function(s, i) {
					return E('span', { 'style': 'white-space:nowrap', 'title': (s.detail || '') + ' ' + hhmmss(s.at) }, [
						i ? ' → ' : '', mark(s.ok), ' ', RELEASE_STEPS[s.step] || s.step,
						s.detail ? ' (' + s.detail + ')' : '' ]);
				});
				var head = r.iccid + (r.provider ? ' — ' + r.provider : '');
				var tail = (r.state == 'delivered') ? _('operator notified %s').format(hhmmss(r.delivered))
					: (r.state == 'failed') ? _('stopped: %s').format(r.error || '?')
					: _('%d tries, next on a new connection or within 5 min').format(r.tries || 0);

				return E('tr', { 'class': 'tr' }, [
					E('td', { 'class': 'td left', 'width': '30%' }, [ head, E('br'), E('small', {}, [ hhmmss(r.released) ]) ]),
					E('td', { 'class': 'td left' }, steps.concat([ E('br'), E('small', {}, [ tail ]) ])),
					E('td', { 'class': 'td right' }, [
						(r.state == 'delivering') ? E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(self, function() {
							return self.run(plugin(m.modem, 'deliver'));
						}) }, _('Retry now')) : '',
						(r.state == 'delivered' || r.state == 'failed') ? E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(self, function() {
							return self.run(plugin(m.modem, 'forget', { iccid: r.iccid }));
						}) }, _('Remove')) : '',
					]),
				]);
			})),
		]);
	},

	/* --- import ------------------------------------------------------------ */

	renderImport: function(m) {
		var self = this;
		var code = E('input', { 'class': 'cbi-input-text', 'style': 'width:100%', 'placeholder': 'LPA:1$smdp.example$MATCHING-ID' });
		var cc = E('input', { 'class': 'cbi-input-text', 'placeholder': _('confirmation code / ePIN (if the operator gave one)') });
		var file = E('input', { 'type': 'file', 'accept': 'image/*', 'change': function(ev) {
			if (!ev.target.files.length)
				return;
			decodeQr(ev.target.files[0]).then(function(t) { code.value = t; }).catch(function(e) { notify(e.message, 'warning'); });
		} });
		var body = [
			E('h4', {}, _('Import a profile')),
			E('p', {}, [ code ]),
			E('p', {}, [ cc, ' ', _('or read a QR image:'), ' ', file ]),
			E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
				return self.run(plugin(m.modem, 'import', { activation_code: code.value.trim(), confirmation_code: cc.value.trim() || null }));
			}) }, _('Download')),
			' ',
			E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
				return self.run(plugin(m.modem, 'discovery'));
			}) }, _('Look for a queued profile (SM-DS)')),
		];

		/* the bridge's download record: running, or how the last one ended */
		var dl = m.dl || {};
		if (dl.state && dl.state != 'idle' && dl.via != 'notify') {
			var lines = progressLines(dl.log);
			body.push(E('div', { 'style': 'margin-top:1em' }, [
				E('p', {}, [ mark(dl.state == 'running' ? null : dl.state == 'done'), ' ',
					E('strong', {}, [ _('Download: %s').format(dl.state) ]) ]),
				lines.length ? E('pre', { 'style': 'max-height:12em;overflow:auto' }, [ lines.join('\n') ]) : '',
			]));
		}

		if (m.st.discovery)
			body.push(E('p', {}, [ _('SM-DS (%s): ').format(hhmmss(m.st.discovery.at)),
				(m.st.discovery.servers || []).length ? m.st.discovery.servers.join(', ')
					: (m.st.discovery.error || _('no profile waiting for this EID')) ]));

		return E('div', { 'class': 'cbi-section' }, body);
	},

	/* --- TS.43 ---------------------------------------------------------------- */

	renderTs43: function(m) {
		var self = this;
		var t = m.st.ts43;
		var eid = E('input', { 'class': 'cbi-input-text', 'placeholder': _('target EID (32 digits)') });
		var imei = E('input', { 'class': 'cbi-input-text', 'placeholder': _('target IMEI') });
		var go = function(args) { return self.run(plugin(m.modem, 'ts43_start', args)); };
		var body = [
			E('h4', {}, _('Transfer with the operator (GSMA TS.43, experimental)')),
		];

		if (t) {
			/* the step bar: done steps green, the current one bold, a failure red */
			var seen = (t.events || []).map(function(e) { return e.state; });
			var failed = (t.state == 'error' || t.state == 'denied' || t.state == 'cancelled');
			var bar = TS43_STEPS.filter(function(s) {
				return !(t.target != 'router' && (s[0] == 'installing' || s[0] == 'activating'));
			}).map(function(s, i) {
				var reached = seen.indexOf(s[0]) >= 0;
				var current = (t.state == s[0]);
				return E('span', { 'style': 'white-space:nowrap;' + (current ? 'font-weight:bold;' : '') +
					(reached ? 'color:#2a2;' : 'color:#888;') }, [ i ? ' → ' : '', reached ? '✔ ' : '', s[1] ]);
			});

			if (failed)
				bar.push(E('span', { 'style': 'color:#c22;font-weight:bold' }, [ ' ✘ ' + t.state ]));

			body.push(E('p', {}, bar));

			var last = (t.events || [])[t.events.length - 1];
			if (last && last.reason)
				body.push(E('p', {}, [ E('strong', {}, [ _('Reason: ') ]),
					last.reason + (last.error ? ' — ' + last.error : '') + (last.status ? ' (HTTP ' + last.status + ')' : '') ]));

			body.push(E('table', { 'class': 'table' }, [ row(_('Server'), [ t.server || '' ]),
				row(_('Target'), [ t.target + (t.target_eid ? ' ' + t.target_eid : '') ]) ]));

			if (t.prompt && t.prompt.state == 'message')
				body.push(E('div', { 'class': 'alert-message' }, [
					E('p', {}, [ t.prompt.message || '' ]),
					E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
						return self.run(plugin(m.modem, 'ts43_resume', { kind: 'message', accepted: true }));
					}) }, [ t.prompt.accept_label || _('Accept') ]), ' ',
					E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(this, function() {
						return self.run(plugin(m.modem, 'ts43_resume', { kind: 'message', accepted: false }));
					}) }, [ t.prompt.reject_label || _('Reject') ]),
				]));

			if (t.prompt && t.prompt.state == 'websheet')
				body.push(E('div', { 'class': 'alert-message' }, [
					E('p', {}, _('The operator wants a step on its own web page. Open it, finish it there, then continue here.')),
					E('button', { 'class': 'btn cbi-button', 'click': function() {
						/* the URL is the operator's, opened in its own window:
						   its page cannot reach this one (cross-origin), so the
						   result comes back by the button below */
						if (/^https:\/\//.test(t.prompt.url))
							window.open(t.prompt.url, '_blank', 'noopener');
					} }, _('Open the operator page')), ' ',
					E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
						return self.run(plugin(m.modem, 'ts43_resume', { kind: 'websheet', next: 'AcquireConfiguration' }));
					}) }, _('Done on the operator page')),
				]));

			if (t.result && t.result.activation_code) {
				var qrbox = E('div', {});

				body.push(E('p', {}, [ _('Activation code: '), E('code', {}, [ t.result.activation_code ]) ]), qrbox);

				if (t.target == 'router' && t.state == 'download')
					body.push(E('button', { 'class': 'btn cbi-button cbi-button-apply', 'click': ui.createHandlerFn(this, function() {
						return self.run(plugin(m.modem, 'ts43_install'));
					}) }, _('Install on this router')));
				else if (t.target != 'router')
					plugin(m.modem, 'qr', { text: t.result.activation_code }).then(function(r) {
						if (r && r.svg)
							dom.content(qrbox, E('img', { 'src': 'data:image/svg+xml;base64,' + btoa(r.svg), 'style': 'width:240px' }));
						else
							dom.content(qrbox, E('em', {}, _('Install qrencode to show this as a QR; or type it into the target device.')));
					}).catch(function() {});
			}

			body.push(E('details', {}, [ E('summary', {}, _('Timeline')),
				E('table', { 'class': 'table' }, (t.events || []).map(function(e) {
					return E('tr', { 'class': 'tr' }, [ E('td', { 'class': 'td', 'width': '6em' }, [ hhmmss(e.at) ]),
						E('td', { 'class': 'td left' }, [ e.state + (e.reason ? ' — ' + e.reason : '') +
							(e.error ? ' (' + e.error + ')' : '') + (e.status ? ' HTTP ' + e.status : '') ]) ]);
				})) ]));

			if (TS43_RUNNING.indexOf(t.state) >= 0 || t.waiting)
				body.push(E('button', { 'class': 'btn cbi-button cbi-button-reset', 'click': ui.createHandlerFn(this, function() {
					return self.run(plugin(m.modem, 'ts43_cancel'));
				}) }, _('Cancel transfer')));
		}

		body.push(E('p', {}, [
			E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() { return go({ target: 'router' }); }) },
				_('Move this SIM onto this router\'s eSIM')),
		]));
		body.push(E('p', {}, [ eid, ' ', imei, ' ',
			E('button', { 'class': 'btn cbi-button', 'click': ui.createHandlerFn(this, function() {
				return go({ target: 'external', target_eid: eid.value.trim(), target_imei: imei.value.trim() });
			}) }, _('Issue a profile for another device')),
		]));

		return E('div', { 'class': 'cbi-section' }, body);
	},

	/* --- debug trace --------------------------------------------------------- */

	renderLog: function(m, open) {
		var text = (m.log || []).map(function(l) {
			return hhmmss(l.at) + ' ' + l.area + ': ' + l.msg;
		}).join('\n');
		var pre = E('pre', { 'style': 'max-height:24em;overflow:auto;font-size:90%' }, [ text || _('(nothing yet)') ]);

		return E('details', { 'data-modem': m.modem, 'open': open ? '' : null, 'style': 'margin-top:1em' }, [
			E('summary', {}, _('Debug log (%d lines; identities masked)').format((m.log || []).length)),
			pre,
			E('button', { 'class': 'btn cbi-button', 'click': function() {
				/* the clipboard API needs a secure context; LuCI over plain
				   http falls back to selecting the text */
				if (navigator.clipboard && window.isSecureContext)
					navigator.clipboard.writeText(text).then(function() { notify(_('Copied.'), 'info'); });
				else {
					var r = document.createRange();
					r.selectNodeContents(pre);
					window.getSelection().removeAllRanges();
					window.getSelection().addRange(r);
					notify(_('Selected — press Ctrl+C.'), 'info');
				}
			} }, _('Copy')),
			' ',
			E('span', { 'class': 'cbi-value-description' }, [ _('Also: `wwandctl transfer log`, and the syslog at debug level.') ]),
		]);
	},

	renderModem: function(m, open) {
		if (m.st.ok === false)
			return E('div', { 'class': 'cbi-section' }, [
				E('h3', {}, [ m.modem ]),
				E('p', {}, E('em', {}, [ _('Not available: %s').format(m.st.error || '?') ])),
			]);

		var hint = m.st.hint;

		return E('div', { 'class': 'cbi-section' }, [
			E('h3', {}, [ m.modem ]),
			hint ? E('p', { 'class': 'cbi-value-description' }, [
				E('strong', {}, [ hint.operator + ': ' ]), _('a new code comes from %s; %s.').format(hint.code,
					hint.reusable ? _('it can be used again') : _('it works only once')),
				hint.note ? ' ' + hint.note : '' ]) : '',
			this.renderCheck(m),
			this.renderReleases(m),
			this.renderProfiles(m),
			this.renderImport(m),
			this.renderTs43(m),
			this.renderLog(m, open && open[m.modem]),
		]);
	},

	renderAll: function(modems, open) {
		var self = this;

		return modems.length ? modems.map(function(m) { return self.renderModem(m, open); })
		                     : [ E('p', {}, E('em', {}, _('No modem managed by wwand.'))) ];
	},

	render: function(modems) {
		this.modems = modems;
		this.root = E('div', {}, this.renderAll(modems, {}));

		/* fast while something runs (a check, a release, a download, a
		   transfer), else every 15 s; the decision is the last status, not
		   the page text */
		var tick = 0;
		poll.add(L.bind(function() {
			tick++;
			return (this.busy(this.modems) || tick % 5 == 0) ? this.reload() : Promise.resolve();
		}, this), 3);

		return E([], [
			E('h2', {}, _('eSIM transfer')),
			E('div', { 'class': 'cbi-map-descr' }, _('An eSIM profile cannot be copied: moving a subscription means the operator issues a new profile for the target, and the old one is deleted. Release deletes a profile here and makes sure the operator learns of it; Import installs a code the operator issued.')),
			this.root,
		]);
	},

	handleSave: null,
	handleSaveApply: null,
	handleReset: null,
});
