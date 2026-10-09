# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::WorkflowMentionStore;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# A mention store for PostingWorkflow that counts its calls, keeps the last
# input and dies when built with fail => 1.
has calls => 0;
has 'fail';
has 'last_input';

sub record_for_source ( $self, $input ) {
    $self->calls( $self->calls + 1 );
    $self->last_input($input);
    if ( $self->fail ) {
        die "mention failed\n";
    }

    return { ok => 1 };
}

1;
