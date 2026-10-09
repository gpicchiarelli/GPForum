# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RefusingNotifier;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# Stands in for a realtime notifier that could not send: notify answers
# { ok => 0 } with the reason, as GPForum::Service::Realtime::PgNotifier
# does when its NOTIFY fails.
has reason => 'listener gone';

sub notify ( $self, $event ) {
    return { ok => 0, reason => $self->reason };
}

1;
