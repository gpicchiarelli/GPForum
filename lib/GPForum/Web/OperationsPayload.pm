# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::OperationsPayload;

use strict;
use warnings;
use feature 'signatures';

our $VERSION = '0.001';

sub metrics ( $, %input ) {
    return $input{snapshot} || {};
}

1;
