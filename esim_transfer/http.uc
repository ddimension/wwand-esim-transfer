// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// One HTTPS request through ucode-mod-uclient (OpenWrt package/libs/uclient,
// ucode.c, 2026.06.07), the shape ts43.uc's fx.http expects:
//   request({ method, url, headers, body }, cb) → cb(err, { status, headers, body })
//
// Certificates are verified against the system bundle (ca-bundle); an
// entitlement server is the operator's own and has no reason to need less.
//
// LIMIT: uclient keeps response headers in a blobmsg table by name
// (uc_uclient_get_headers, ucode.c:205-227), so of several Set-Cookie headers
// only the last survives. The servers seen so far set one session cookie; a
// server that needs two will fail at the relay step, and this is where it
// would have to be fixed (in uclient).
//
// An ES module, precompiled to bytecode; exports { request }.

'use strict';

import * as uloop from 'uloop';

const CA_BUNDLE = '/etc/ssl/certs/ca-certificates.crt';
const TIMEOUT_MS = 30000;

function request(req, cb)
{
	let uclient;

	try { uclient = require('uclient'); }
	catch (e) { return cb({ error: 'no_uclient', detail: 'install ucode-mod-uclient' }); }

	let body = '', answered = false, cl, guard;
	let answer = (err, res) => {
		if (answered)
			return;

		answered = true;
		guard?.cancel();
		cl?.disconnect();
		cb(err, res);
	};

	cl = uclient.new(req.url, null, {
		header_done: () => null,
		data_read: () => {
			let d;

			while (length(d = cl.read()) > 0)
				body += d;
		},
		data_eof: () => answer(null, { status: cl.status()?.status ?? 0, headers: cl.get_headers() ?? {}, body: body }),
		error: (cb2, code) => answer({ error: 'http_transport', code: code }),
	});

	if (!cl)
		return answer({ error: 'http_url', detail: req.url });

	if (substr(req.url, 0, 8) == 'https://' && !cl.ssl_init({ verify: true, ca_files: [ CA_BUNDLE ] }))
		return answer({ error: 'tls_init' });

	cl.set_timeout(TIMEOUT_MS);

	// the transport's own timeout covers a stalled read; this one also covers
	// a connect that never answers
	guard = uloop.timer(TIMEOUT_MS + 5000, () => answer({ error: 'http_timeout' }));

	if (!cl.connect())
		return answer({ error: 'http_connect' });

	let opts = { headers: req.headers ?? {} };

	if (req.body != null)
		opts.post_data = req.body;

	if (!cl.request(req.method ?? 'GET', opts))
		return answer({ error: 'http_request' });
}

export { request };
