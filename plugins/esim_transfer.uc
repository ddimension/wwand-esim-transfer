// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// wwand-esim-transfer's entry for wwand plugins.uc, which require()s
// /usr/share/ucode/wwand/plugins/<name>.uc and takes the object it returns.
// A require()d script cannot be a bytecode module (it is parsed as source at
// runtime, and its top-level `return` is not module syntax), so this stays a
// two-line shim and the plugin lives in wwand.esim_transfer.plugin, which is
// precompiled.

'use strict';

import { PLUGIN } from 'wwand.esim_transfer.plugin';

return PLUGIN;
