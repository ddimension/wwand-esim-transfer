// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// SHA-1 (FIPS 180-4), HMAC-SHA1 (RFC 2104) and the FIPS 186-2 pseudo-random
// function, in ucode — what EAP-AKA (RFC 4187) derives its keys with.
//
// Why not ucode-mod-digest: the PRF of RFC 4187 7 is NOT SHA-1 of a message,
// it runs the bare SHA-1 COMPRESSION on a zero-padded 64-byte block with no
// length padding (FIPS 186-2 change notice 1, appendix 3.3 "G(t, c)"). No
// digest module exposes the compression function, and an implementation that
// "simplifies" G into sha1(XKEY) derives the wrong K_aut — every AT_MAC then
// fails at the server with nothing on our side to show why.
//
// Bytes travel as arrays of integers 0..255; hex at the edges (h2b / b2h).
//
// An ES module (precompiled to bytecode with the rest of the package).

'use strict';

const M32 = 0xffffffff;

let rol = (x, n) => ((x << n) | (x >> (32 - n))) & M32;

function h2b(h)
{
	let out = [];

	for (let i = 0; i + 1 < length(h ?? ''); i += 2)
		push(out, hex(substr(h, i, 2)));

	return out;
}

function b2h(b)
{
	return join('', map(b ?? [], (x) => sprintf('%02X', x)));
}

// one 64-byte block (array) into the five-word state H; returns the new state
function compress(H, blk)
{
	let w = [];

	for (let t = 0; t < 16; t++)
		w[t] = (blk[4 * t] << 24) | (blk[4 * t + 1] << 16) | (blk[4 * t + 2] << 8) | blk[4 * t + 3];

	for (let t = 16; t < 80; t++)
		w[t] = rol(w[t - 3] ^ w[t - 8] ^ w[t - 14] ^ w[t - 16], 1);

	let a = H[0], b = H[1], c = H[2], d = H[3], e = H[4];

	for (let t = 0; t < 80; t++) {
		let f, k;

		if (t < 20)      { f = (b & c) | ((~b & M32) & d); k = 0x5A827999; }
		else if (t < 40) { f = b ^ c ^ d;                  k = 0x6ED9EBA1; }
		else if (t < 60) { f = (b & c) | (b & d) | (c & d); k = 0x8F1BBCDC; }
		else             { f = b ^ c ^ d;                  k = 0xCA62C1D6; }

		let tmp = (rol(a, 5) + f + e + k + w[t]) & M32;

		e = d; d = c; c = rol(b, 30); b = a; a = tmp;
	}

	return [ (H[0] + a) & M32, (H[1] + b) & M32, (H[2] + c) & M32,
	         (H[3] + d) & M32, (H[4] + e) & M32 ];
}

const H0 = [ 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 ];

function words_to_bytes(H)
{
	let out = [];

	for (let x in H)
		push(out, (x >> 24) & 255, (x >> 16) & 255, (x >> 8) & 255, x & 255);

	return out;
}

function sha1(msg)
{
	let m = [ ...msg ];
	let bits = length(msg) * 8;

	push(m, 0x80);

	while (length(m) % 64 != 56)
		push(m, 0);

	for (let i = 7; i >= 0; i--)
		push(m, (i >= 4) ? 0 : ((bits >> (8 * i)) & 255));

	let H = H0;

	for (let i = 0; i < length(m); i += 64)
		H = compress(H, slice(m, i, i + 64));

	return words_to_bytes(H);
}

function hmac_sha1(key, msg)
{
	let k = (length(key) > 64) ? sha1(key) : [ ...key ];

	while (length(k) < 64)
		push(k, 0);

	let ipad = map(k, (x) => x ^ 0x36), opad = map(k, (x) => x ^ 0x5c);

	return sha1([ ...opad, ...sha1([ ...ipad, ...msg ]) ]);
}

// FIPS 186-2 change notice 1 general purpose PRF, XSEED = 0, b = 160:
// x_j = G(XKEY), XKEY = (1 + XKEY + x_j) mod 2^160, two x_j per round
// (RFC 4187 7 and its appendix). xkey: 20 bytes. Returns n bytes.
function fips186_prf(xkey, n)
{
	let out = [];
	let x = [ ...xkey ];

	while (length(out) < n) {
		let blk = [ ...x ];

		while (length(blk) < 64)
			push(blk, 0);

		let w = words_to_bytes(compress(H0, blk));

		push(out, ...w);

		// XKEY = (1 + XKEY + w) mod 2^160, big-endian
		let carry = 1;

		for (let i = 19; i >= 0; i--) {
			let s = x[i] + w[i] + carry;

			x[i] = s & 255;
			carry = s >> 8;
		}
	}

	return slice(out, 0, n);
}

export { h2b, b2h, sha1, hmac_sha1, fips186_prf };
