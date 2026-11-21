// SPDX-License-Identifier: GPL-2.0-only
// Copyright (C) 2026 André Valentin <avalentin@marcant.net>
// `wwandctl transfer`: wwandctl require()s /usr/share/ucode/wwand/ctl/<cmd>.uc
// and takes the object it returns. A require()d script is parsed as source,
// so this stays a shim; the command lives in the bytecode module
// wwand.esim_transfer.ctl.

'use strict';

import { COMMAND } from 'wwand.esim_transfer.ctl';

return COMMAND;
