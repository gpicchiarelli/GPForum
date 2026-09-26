# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SearchRebuildIndexer;

use strict;
use warnings;

use Const::Fast;

our $VERSION = '0.001';

const my $INDEXED     => 3;
const my $LAG_SECONDS => 42;
const my $PENDING     => 2;
const my $UNCHANGED   => 5;

# The search indexer as bin/gpforum-search-rebuild sees it: a rebuild that
# reports fixed counts and remembers its scope, and a fixed lag.
sub new {
    my ($class) = @_;

    return bless {}, $class;
}

sub scope {
    my ($self) = @_;

    return $self->{scope};
}

sub rebuild {
    my ( $self, $scope ) = @_;

    $self->{scope} = $scope;
    return {
        entity_type => $scope->{entity_type},
        indexed     => $INDEXED,
        ok          => 1,
        pruned      => 1,
        unchanged   => $UNCHANGED,
    };
}

sub observe_lag {
    return {
        lag_seconds       => $LAG_SECONDS,
        oldest_pending_at => '2026-09-26T10:00:00Z',
        pending           => $PENDING,
        status            => 'behind',
    };
}

1;
