# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::SearchRebuild;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Search::Indexer;

our $VERSION = '0.001';

const my %ENTITIES => map { $_ => 1 } qw(all post thread);

has indexer => undef;
has schema  => undef;

# ADR 0062 makes search a projection that can lag and must be rebuildable;
# ADR 0110 found the rebuild and the lag had no way in for an operator. This
# is that way in: after a search configuration change, a handler bug or
# dead-lettered search events, or to tell a stalled indexer from a busy one.
sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( GPForum::Command::Usage->is_usage($error) ) {
        return GPForum::Command::Usage->error( undef, $error );
    }
    if ( $error =~ /\A Unknown [ ] option: /msx ) {
        return GPForum::Command::Usage->error( $error, _usage() );
    }
    die "$error\n";
}

sub _run ( $self, @arguments ) {
    my $options = _options(@arguments);

    return $self->_status if $options->{status};

    my $rebuilt =
      $self->_indexer->rebuild( { entity_type => $options->{entity} } );
    _say(
        join q{ },
        'rebuilt',
        map { "$_=" . ( $rebuilt->{$_} // 0 ) }
          qw(entity_type indexed unchanged pruned)
    );

    return $GPForum::Command::Usage::EXIT_OK;
}

sub _status ($self) {
    my $lag = $self->_indexer->observe_lag || {};
    _say(
        join q{ },
        'search',
        'status=' .      ( $lag->{status}            // 'unknown' ),
        'pending=' .     ( $lag->{pending}           // 0 ),
        'lag_seconds=' . ( $lag->{lag_seconds}       // 0 ),
        'oldest=' .      ( $lag->{oldest_pending_at} // q{-} ),
    );

    return $GPForum::Command::Usage::EXIT_OK;
}

sub _indexer ($self) {
    return $self->indexer if $self->indexer;

    return GPForum::Service::Search::Indexer->new( schema => $self->_schema );
}

sub _schema ($self) {
    return $self->schema if $self->schema;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

sub _options (@arguments) {
    my %options = ( entity => 'all', status => 0 );
    my $entity_given;
    while (@arguments) {
        my $flag = shift @arguments;
        if ( $flag eq '--status' ) {
            $options{status} = 1;
        }
        elsif ( $flag eq '--entity' ) {
            $options{entity} = shift @arguments // q{};
            $entity_given = 1;
            croak _usage() if !exists $ENTITIES{ $options{entity} };
        }
        else {
            croak "Unknown option: $flag";
        }
    }
    croak _usage() if $options{status} && $entity_given;

    return \%options;
}

sub _say ($line) {
    print "$line\n" or croak 'failed to write search-rebuild output';

    return;
}

sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-search-rebuild [--entity thread|post|all]
       bin/gpforum-search-rebuild --status

Rebuild the search index from the forum's threads and posts: every live
thread and post is indexed again, in batches, and documents whose thread or
post is gone, deleted or hidden are removed. Safe to run while the forum
serves; documents that did not change are left alone.

--status reports how far search may be behind: the outbox messages not yet
delivered, and the age of the oldest.
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::SearchRebuild - Rebuild the search index, or report its lag.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    bin/gpforum-search-rebuild
    bin/gpforum-search-rebuild --entity post
    bin/gpforum-search-rebuild --status

=head1 DESCRIPTION

The operator's way into L<GPForum::Service::Search::Indexer>'s C<rebuild>
and C<observe_lag> (ADR 0062, ADR 0110).

=head1 SUBROUTINES/METHODS

=head2 run

Runs the command; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Exit 0 on success, 2 on misuse; a database failure dies with its error.

=head1 CONFIGURATION AND ENVIRONMENT

The database comes from the usual C<GPFORUM_DATABASE_*> environment.

=head1 DEPENDENCIES

L<GPForum::Service::Search::Indexer>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The lag is an upper bound: it is the age of the oldest undelivered outbox
message, whether or not that message changes search.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
