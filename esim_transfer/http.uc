// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// One HTTPS request, the shape ts43.uc's fx.http expects:
//   request({ method, url, headers, body }, cb) → cb(err, { status, headers, body })
// with headers['set-cookie'] an ARRAY of every Set-Cookie line.
//
// Two backends, curl first:
//
// - a curl CLI: wwand-lpac-curl's /usr/libexec/wwand/curl first (static,
//   the libcurl + wolfSSL of the wwand-lpac build — no shared library an older
//   image could lack), then the system's /usr/bin/curl, then an executable at
//   /etc/wwand/esim-transfer/curl (a wrapper for one kept elsewhere).
//   It hands back every response header, so a server that sets several
//   cookies gets all of them back. That is not a nicety: Vodafone DE's
//   entitlement server sits behind Imperva, sets three cookies per answer
//   (visid_incap_*, nlbi_*, incap_ses_*), and answers the EAP relay with an
//   empty HTTP 400 when they do not come back (HW-seen from the Chateau,
//   2026-11-21). Run through uloop.process — asynchronously, the daemon is
//   not held for a request's 30 s, and without a shell, so nothing needs
//   quoting.
// - ucode-mod-uclient (OpenWrt package/libs/uclient, ucode.c, 2026.06.07),
//   when there is no curl. LIMIT: uclient keeps response headers in a
//   blobmsg table and get_headers() turns it into an object by name
//   (uc_uclient_get_headers, ucode.c:205-227), so of several Set-Cookie
//   headers only the LAST survives — enough for a server with one session
//   cookie, not for one behind such a CDN.
//
// Certificates are verified against the system bundle (ca-bundle); an
// entitlement server is the operator's own and has no reason to need less.
//
// An ES module, precompiled to bytecode; exports { request, parse_headers }.

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';

const CA_BUNDLE = '/etc/ssl/certs/ca-certificates.crt';
const TIMEOUT_MS = 30000;
const CURLS = [ '/usr/libexec/wwand/curl', '/usr/bin/curl', '/etc/wwand/esim-transfer/curl' ];
const TMP = '/tmp/wwand';

let seq = 0;

// a `curl -D` header dump as { status, headers }: only the LAST response
// counts (a 100 Continue or a redirect leaves blocks before it); names
// lower-cased; set-cookie collected as an array, every other header the last
// value seen
function parse_headers(dump)
{
	let blocks = split(replace(dump ?? '', /\r/g, ''), /\n\n/);
	let last = null;

	for (let b in blocks)
		if (match(b, /^HTTP\/[0-9.]+ [0-9]{3}/))
			last = b;

	if (!last)
		return { status: 0, headers: {} };

	let lines = split(last, '\n');
	let out = { status: +match(lines[0], /^HTTP\/[0-9.]+ ([0-9]{3})/)[1], headers: { 'set-cookie': [] } };

	for (let i = 1; i < length(lines); i++) {
		let m = match(lines[i], /^([^:]+):[ \t]*(.*)$/);

		if (!m)
			continue;

		let k = lc(m[1]);

		if (k == 'set-cookie')
			push(out.headers['set-cookie'], m[2]);
		else
			out.headers[k] = m[2];
	}

	return out;
}

function curl_of()
{
	for (let c in CURLS)
		if (fs.access(c, 'x'))
			return c;

	return null;
}

function request_curl(curl, req, cb)
{
	fs.mkdir(TMP);

	let base = sprintf('%s/esim-transfer-http.%d.%d', TMP, time(), ++seq);
	let hdr = base + '.hdr', body = base + '.body', data = base + '.req';
	let args = [ '-sS', '--max-time', sprintf('%d', TIMEOUT_MS / 1000), '--cacert', CA_BUNDLE,
	             '-X', req.method ?? 'GET', '-D', hdr, '-o', body ];

	for (let k, v in req.headers ?? {})
		push(args, '-H', sprintf('%s: %s', k, v));

	if (req.body != null) {
		fs.writefile(data, req.body);
		push(args, '--data-binary', '@' + data);
	}

	push(args, req.url);

	let done = false;
	let finish = (code) => {
		if (done)
			return;

		done = true;

		let h = parse_headers(fs.readfile(hdr));
		let b = fs.readfile(body) ?? '';

		for (let f in [ hdr, body, data ])
			fs.unlink(f);

		// curl exits non-zero only when there was no HTTP answer at all
		// (connect, TLS, timeout): an HTTP 4xx/5xx is an answer
		if (!h.status)
			return cb({ error: 'http_transport', code: code });

		cb(null, { status: h.status, headers: h.headers, body: b });
	};

	// the environment is REPLACED by this object, {} would run curl with
	// none at all: a fixed PATH, nothing of the daemon's own
	if (!uloop.process(curl, args, { PATH: '/usr/sbin:/usr/bin:/sbin:/bin' }, (code) => finish(code)))
		finish(-1);
}

function request_uclient(req, cb)
{
	let uclient;

	try { uclient = require('uclient'); }
	catch (e) { return cb({ error: 'no_http_client', detail: 'install wwand-lpac-curl (or curl)' }); }

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
		data_eof: () => {
			let h = cl.get_headers() ?? {};
			let out = {};

			// one Set-Cookie at most (see the header); as an array like curl's
			for (let k, v in h)
				out[lc(k)] = (lc(k) == 'set-cookie') ? [ v ] : v;

			answer(null, { status: cl.status()?.status ?? 0, headers: out, body: body });
		},
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

// curl: the CLI to use instead of the search (the tests' fake one)
function request(req, cb, curl)
{
	curl ??= curl_of();

	return curl ? request_curl(curl, req, cb) : request_uclient(req, cb);
}

export { request, parse_headers };
