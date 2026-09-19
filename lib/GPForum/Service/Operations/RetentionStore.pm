package GPForum::Service::Operations::RetentionStore;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base -base;
use POSIX qw(strftime);

use GPForum::Service::Clock;
use GPForum::Service::Operations::BatchPurge;

our $VERSION = '0.001';

const my $DAY_SECONDS                => 86_400;
const my $OUTBOX_RETENTION_DAYS      => 7;
const my $DEAD_LETTER_RETENTION_DAYS => 30;
const my $LTE                        => q{<} . q{=};
const my $NOT_EQ                     => q{!} . q{=};
const my @DONE_OUTBOX_STATUSES       => qw(cancelled done);

has batch_purge =>
  sub { return GPForum::Service::Operations::BatchPurge->new; };
has clock  => sub { return GPForum::Service::Clock->new; };
has schema => undef;

sub purge_sessions {
    my ( $self, $input ) = @_;

    return $self->_purge(
        {
            input        => $input,
            order_column => 'expires_at',
            query        => $self->_session_query,
            resultset    => 'Session',
        }
    );
}

sub purge_identity_tokens {
    my ( $self, $input ) = @_;

    return $self->_purge(
        {
            input        => $input,
            order_column => 'expires_at',
            query        => $self->_token_query,
            resultset    => 'IdentityToken',
        }
    );
}

sub purge_rate_limit_buckets {
    my ( $self, $input ) = @_;

    return $self->_purge(
        {
            input        => $input,
            order_column => 'expires_at',
            query        => $self->_expired_at_query,
            resultset    => 'RateLimitBucket',
        }
    );
}

sub purge_outbox_messages {
    my ( $self, $input ) = @_;

    return $self->_purge(
        {
            input        => $input,
            order_column => 'created_at',
            query        => $self->_outbox_query($input),
            resultset    => 'OutboxMessage',
        }
    );
}

sub purge_dead_letters {
    my ( $self, $input ) = @_;

    return $self->_purge(
        {
            input        => $input,
            order_column => 'last_failed_at',
            query        => $self->_dead_letter_query($input),
            resultset    => 'DeadLetter',
        }
    );
}

sub _purge {
    my ( $self, $spec ) = @_;

    return $self->batch_purge->delete_rows( $self->_candidates($spec) );
}

sub _candidates {
    my ( $self, $spec ) = @_;

    return [ $self->_rows_from( $self->_search($spec) ) ];
}

sub _search {
    my ( $self, $spec ) = @_;

    my $resultset = $self->_resultset( $spec->{resultset} );
    return $resultset->search( $spec->{query}, $self->_search_attrs($spec) );
}

sub _resultset {
    my ( $self, $name ) = @_;

    return $self->schema->resultset($name);
}

sub _search_attrs {
    my ( $self, $spec ) = @_;

    return $self->batch_purge->search_attrs( $spec->{input},
        $spec->{order_column} );
}

sub _rows_from {
    my ( undef, $search ) = @_;

    if ( $search->can('items') ) {
        return $search->items;
    }

    return $search->all;
}

sub _not_null_query {
    my ( undef, $column ) = @_;

    return { $column => { $NOT_EQ => undef } };
}

sub _session_query {
    my ($self) = @_;

    return { -or =>
          [ $self->_expired_at_query, $self->_not_null_query('revoked_at') ], };
}

sub _token_query {
    my ($self) = @_;

    return {
        -or => [ $self->_expired_at_query, $self->_not_null_query('used_at') ],
    };
}

sub _expired_at_query {
    my ($self) = @_;

    return { expires_at => { $LTE => $self->clock->now_iso8601 } };
}

sub _outbox_query {
    my ( $self, $input ) = @_;

    return {
        created_at => {
            $LTE => $self->_cutoff_iso(
                $input, 'outbox_retention_days', $OUTBOX_RETENTION_DAYS
            )
        },
        status => { -in => [@DONE_OUTBOX_STATUSES] },
    };
}

sub _dead_letter_query {
    my ( $self, $input ) = @_;

    return {
        last_failed_at => {
            $LTE => $self->_cutoff_iso(
                $input, 'dead_letter_retention_days',
                $DEAD_LETTER_RETENTION_DAYS
            )
        },
    };
}

sub _cutoff_iso {
    my ( $self, $input, $field, $default_days ) = @_;

    my $days = $default_days;
    if ( $input && $input->{$field} ) {
        $days = $input->{$field};
    }

    return strftime '%Y-%m-%dT%H:%M:%SZ',
      gmtime( $self->clock->now_epoch - ( $days * $DAY_SECONDS ) );
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::RetentionStore - Batched operational deletes.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $store = GPForum::Service::Operations::RetentionStore->new(
        schema => $schema,
    );
    my $result = $store->purge_sessions( { limit => 100 } );

=head1 DESCRIPTION

Deletes stale C<sessions>, C<identity_tokens>, C<rate_limit_buckets>,
completed C<outbox_messages>, and aged C<dead_letters> in bounded batches.
Every search includes a row cap. It does not issue unbounded C<DELETE>.

=head1 SUBROUTINES/METHODS

=head2 purge_sessions

Deletes expired or revoked sessions, oldest expiry first.

=head2 purge_identity_tokens

Deletes expired or consumed identity tokens.

=head2 purge_rate_limit_buckets

Deletes rate-limit windows whose C<expires_at> has passed.

=head2 purge_outbox_messages

Deletes C<done> or C<cancelled> outbox rows older than the retention cutoff.

=head2 purge_dead_letters

Deletes dead-letter rows older than the retention cutoff.

=head1 DIAGNOSTICS

Persistence errors are raised by DBIx::Class.

=head1 CONFIGURATION AND ENVIRONMENT

Outbox rows default to a 7-day grace after completion. Dead letters default
to 30 days. Both can be overridden on the input hash.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<GPForum::Service::Clock>,
L<GPForum::Service::Operations::BatchPurge>, L<Mojo::Base>, and L<POSIX>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Pending, failed, and running outbox rows are never deleted. Partition DDL is
not this store's job.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
