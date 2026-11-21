#!/bin/sh
# wwand-esim-transfer tests. They run against a wwand source checkout, the one
# the plugin is loaded into: WWAND_SRC (default ../wwand beside this
# repository).
#
# Every suite runs TWICE: once on the source, once on the bytecode the
# package ships — built by this repository's CMakeLists.txt with the same
# ucode, so a module that only breaks once compiled (an import the compiler
# resolves differently, an export it does not see) fails here and not on a
# router. An overlay directory makes the modules reachable the way the daemon
# reaches them — wwand.plugins.esim_transfer, wwand.ctl.transfer,
# wwand.esim_transfer.* — next to wwand's own.

set -e

TESTDIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(dirname "$TESTDIR")"
WWAND_SRC="${WWAND_SRC:-$REPO/../wwand}"
WWAND_SRC="$(cd "$WWAND_SRC" && pwd)"

if [ -x "$HOME/.local/bin/ucode" ]; then
	UCODE="$HOME/.local/bin/ucode"
	export LD_LIBRARY_PATH="$HOME/.local/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
	MODPATH="$HOME/.local/lib/ucode/*.so"
else
	UCODE=ucode
	MODPATH="/usr/lib/ucode/*.so"
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# the bytecode, as the package build makes it
cmake -S "$REPO" -B "$WORK/build" -DUCODE_COMPILER="$UCODE" >"$WORK/cmake.log" 2>&1 || {
	cat "$WORK/cmake.log"; exit 1; }
grep -q 'bytecode precompile enabled' "$WORK/cmake.log" || {
	echo "FAIL: the host ucode cannot precompile — no bytecode to test"; cat "$WORK/cmake.log"; exit 1; }
cmake --build "$WORK/build" >"$WORK/build.log" 2>&1 || { cat "$WORK/build.log"; exit 1; }

BC="$WORK/build/out"

rc=0

# the ucode traps wwand's own tree is checked for (an escape class inside a
# bracket, a called parenthesized `??`): the same interpreter runs this code
python3 "$WWAND_SRC/tools/check-ucode-pitfalls.py" "$REPO" || rc=1

for variant in source bytecode; do
	OVL="$WORK/ovl-$variant"
	ROOT="$REPO"
	[ "$variant" = bytecode ] && ROOT="$BC"

	mkdir -p "$OVL/wwand"
	for f in "$WWAND_SRC"/src-ucode/*; do ln -s "$f" "$OVL/wwand/"; done
	ln -s "$ROOT/plugins" "$OVL/wwand/plugins"
	ln -s "$ROOT/ctl" "$OVL/wwand/ctl"
	ln -s "$ROOT/esim_transfer" "$OVL/wwand/esim_transfer"

	# a compiled program must still start from its interpreter line
	if [ "$variant" = bytecode ]; then
		head -c 2 "$BC/libexec/esim-transfer-card" | grep -q '#!' || {
			echo "FAIL: compiled esim-transfer-card lost its interpreter line"; rc=1; }
		for m in "$BC"/esim_transfer/*.uc; do
			head -c 64 "$m" | grep -q 'use strict' && { echo "FAIL: $m is source, not bytecode"; rc=1; }
		done
	fi

	export ESIM_TRANSFER_CARD="$ROOT/libexec/esim-transfer-card"
	export FAKE_CURL="$TESTDIR/fake-curl"
	export ESIM_TRANSFER_UCODE="$UCODE -L '$MODPATH' -L '$OVL/*.uc'"

	for t in "$TESTDIR"/test_*.uc; do
		out=$(cd "$TESTDIR" && "$UCODE" -L "$MODPATH" -L "$WWAND_SRC/io/build-host/*.so" \
			-L "$OVL/*.uc" "$t" 2>&1) || true
		printf '[%s] %s\n' "$variant" "$out"
		printf '%s\n' "$out" | grep -qE '^test_[a-z0-9_]+: [0-9]+ checks, 0 failures$' || rc=1
	done
done

exit $rc
