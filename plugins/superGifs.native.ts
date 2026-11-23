/*
 * Vencord, a Discord client mod
 * Copyright (c) 2026 contributors
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

import { CspPolicies, ImageAndMediaSrc } from "@main/csp";

// gifconvert links point directly at an image, but Discord's default CSP
// does not allow this host.
CspPolicies["gifconvert.vxtwitter.com"] = ImageAndMediaSrc;
