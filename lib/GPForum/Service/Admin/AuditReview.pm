# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Admin::AuditReview;

use strict;
use warnings;

use Const::Fast;
use MIME::Base64 qw(decode_base64url encode_base64url);
use Mojo::Base -base, -signatures;

use GPForum::Infrastructure::Id;
use GPForum::Infrastructure::Keyset;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT => 50;
const my $UUID          => GPForum::Infrastructure::Id->uuid_pattern;
const my $DAY           => qr/\A \d{4} - \d{2} - \d{2} \z/msx;
const my $WORD          => qr/\A [[:alnum:]_.:-]{1,100} \z/msx;
const my @FILTERS =>
  qw(actor_id action target_type target_id correlation_id from until);
const my %UUID_FILTER  => map { $_ => 1 } qw(actor_id target_id correlation_id);
const my %DAY_FILTER   => map { $_ => 1 } qw(from until);
const my $CURSOR_PARTS => 2;

has schema => undef;

# The dashboard's recent activity.
sub recent ( $self, $options ) {
    return [
        _rows(
            $self->schema->resultset('AuditLog')->search_rs(
                {},
                {
                    order_by => _newest_first(),
                    rows     => $options->{limit} || $DEFAULT_LIMIT,
                }
            )
        )
    ];
}

# The audit viewer's filters, as ADR 0079 requires them: actor, action,
# target, correlation id and a UTC date window. Returns the filters to apply
# and the ones that could not be: a value that is not a uuid never reaches a
# uuid column, where PostgreSQL would reject the whole query.
sub filters ( $class, $input ) {
    my ( %filters, %errors );
    for my $name (@FILTERS) {
        my $value = $input->{$name};
        next if !defined $value || !length $value;

        my $shape =
            exists $UUID_FILTER{$name} ? $UUID
          : exists $DAY_FILTER{$name}  ? $DAY
          :                              $WORD;
        if ( $value =~ $shape ) {
            $filters{$name} = $value;
        }
        else {
            $errors{$name} = $value;
        }
    }

    return { filters => \%filters, errors => \%errors };
}

# One page, newest first, and the cursor of the next page if there is one.
sub page ( $self, $filters, $page ) {
    my $limit = $page->{limit} || $DEFAULT_LIMIT;
    my @rows  = _rows( $self->page_resultset( $filters, $page ) );

    my $next;
    if ( @rows > $limit ) {
        splice @rows, $limit;
        $next = _cursor( $rows[-1] );
    }

    return { rows => \@rows, next_cursor => $next };
}

# The resultset page executes, one row past the page to learn whether there
# is another. Public so the plan tests EXPLAIN what actually runs.
sub page_resultset ( $self, $filters, $page ) {
    my $query = _query($filters);
    if ( my $after = _decode_cursor( $page->{after} ) ) {
        GPForum::Infrastructure::Keyset->after(
            $query,
            {
                direction => 'desc',
                id        => [ 'audit_id',   $after->{audit_id} ],
                sort      => [ 'created_at', $after->{created_at} ],
            }
        );
    }

    return $self->schema->resultset('AuditLog')->search_rs(
        $query,
        {
            order_by => _newest_first(),
            rows     => ( $page->{limit} || $DEFAULT_LIMIT ) + 1,
        }
    );
}

sub _query ($filters) {
    my %query =
      map  { $_ => $filters->{$_} }
      grep { defined $filters->{$_} }
      qw(actor_id action target_type target_id correlation_id);
    my ( $from, $until ) = @{$filters}{qw(from until)};
    my %window;
    if ( defined $from ) {
        $window{q{>=}} = "${from}T00:00:00Z";
    }
    if ( defined $until ) {
        $window{q{<=}} = "${until}T23:59:59.999999Z";
    }
    if (%window) {
        $query{created_at} = \%window;
    }

    return \%query;
}

sub _newest_first {
    return [ { -desc => 'created_at' }, { -desc => 'audit_id' } ];
}

sub _cursor ($row) {
    return encode_base64url(
        join q{|},
        _column( $row, 'created_at' ),
        _column( $row, 'audit_id' )
    );
}

# A cursor that does not decode to a timestamp and a uuid is ignored, and the
# first page is shown, rather than sent to PostgreSQL.
sub _decode_cursor ($cursor) {
    return if !defined $cursor || !length $cursor;

    my ( $created_at, $audit_id ) = split /[|]/msx,
      decode_base64url($cursor), $CURSOR_PARTS;
    return if !defined $audit_id || $audit_id !~ $UUID;
    return
      if !defined $created_at || $created_at !~ /\A \d{4} - \d{2} - \d{2}/msx;

    return { created_at => $created_at, audit_id => $audit_id };
}

sub _column ( $row, $name ) {
    return ref $row eq 'HASH' ? $row->{$name} : $row->get_column($name);
}

sub _rows ($search) {
    return $search->all       if $search->can('all');
    return @{ $search->rows } if $search->can('rows');

    return;
}

1;

__END__

=head1 NAME

GPForum::Service::Admin::AuditReview - Read the audit log for the console.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $checked = GPForum::Service::Admin::AuditReview->filters(\%params);
    my $page    = $review->page( $checked->{filters}, { after => $cursor } );

=head1 DESCRIPTION

The audit viewer's reads (ADR 0079): filtering by actor, action, target,
correlation id and a UTC date window, newest first, a page at a time with a
keyset cursor. Audit rows are never written here.

=head1 SUBROUTINES/METHODS

=head2 recent

The newest rows, for the dashboard.

=head2 filters

Splits request parameters into filters to apply and values rejected because
they do not have the column's shape (a uuid, a C<YYYY-MM-DD> date, a word).

=head2 page

One page of rows and the C<next_cursor>, or undef on the last page.

=head2 page_resultset

The resultset C<page> executes.

=head1 DIAGNOSTICS

Invalid filter values are returned as errors, never queried; an invalid cursor
is ignored.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Const::Fast>, L<MIME::Base64>, L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Dates are UTC days.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
