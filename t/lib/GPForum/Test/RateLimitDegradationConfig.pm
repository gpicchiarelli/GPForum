# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RateLimitDegradationConfig;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

has environment                 => 'development';
has rate_limit_degradation_mode => undef;

1;
