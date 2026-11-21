// The curl backend of esim_transfer/http.uc against a fake curl: the
// arguments it builds, and every Set-Cookie coming back (uclient keeps one).

'use strict';

import * as fs from 'fs';
import * as uloop from 'uloop';
import { eq, ok, done } from './lib/check.uc';
import * as H from 'wwand.esim_transfer.http';

let h = H.parse_headers('HTTP/1.1 100 Continue\r\n\r\nHTTP/2 200 \r\nSet-Cookie: a=1; path=/\r\nset-cookie: b=2\r\nContent-Type: x\r\n\r\n');

eq(h.status, 200, 'headers: the last response\'s status');
eq(h.headers['set-cookie'], [ 'a=1; path=/', 'b=2' ], 'headers: every Set-Cookie, in order');
eq(h.headers['content-type'], 'x', 'headers: names lower-cased');
eq(H.parse_headers('').status, 0, 'headers: nothing -> status 0');

let fake = getenv('FAKE_CURL');
let argf = fake + '.args';

uloop.init();

let res = null;
let go = (curl) => {
	res = null;
	H.request({ method: 'POST', url: 'https://es.example/ts43',
	            headers: { 'Content-Type': 'application/json', 'Cookie': 'x=1; y=2' },
	            body: '{"eap-relay-packet":"AQ=="}' }, (err, r) => { res = [ err, r ]; uloop.end(); }, curl);
	uloop.run();
};

// something that is not curl: a clean transport error, not a hang
go('/bin/true');
eq(res?.[0]?.error, 'http_transport', 'request: no HTTP answer -> http_transport');

fs.unlink(argf);
go(fake);

eq(res[0], null, 'curl: no error for an HTTP answer');
eq(res[1].status, 400, 'curl: the final status (not the 100 Continue)');
eq(res[1].headers['set-cookie'], [ 'visid_incap_1=AAA; path=/', 'nlbi_1=BBB; path=/', 'incap_ses_1=CCC; path=/' ],
	'curl: all three cookies of an Imperva answer');
eq(res[1].body, '{"eap-relay-packet":"AQ=="}', 'curl: the request body went out byte for byte');

let args = split(trim(fs.readfile(argf) ?? ''), '\n');

ok(index(args, 'Cookie: x=1; y=2') >= 0, 'curl: headers passed as -H "Name: value", no shell in between');
ok(index(args, '--cacert') >= 0, 'curl: certificates verified against the bundle');
eq(args[length(args) - 1], 'https://es.example/ts43', 'curl: the URL last');
eq(length(filter(fs.lsdir('/tmp/wwand') ?? [], (f) => index(f, 'esim-transfer-http') == 0)), 0, 'curl: temp files removed');
fs.unlink(argf);

done('test_http');
