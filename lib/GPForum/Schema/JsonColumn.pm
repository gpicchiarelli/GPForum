# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Schema::JsonColumn;

use strict;
use warnings;
use feature 'signatures';

use Const::Fast;
use JSON::MaybeXS;

our $VERSION = '0.001';

const my %JSON_DATA_TYPES => map { $_ => 1 } qw(json jsonb);

my $CODEC = JSON::MaybeXS->new(
    allow_nonref => 1,
    canonical    => 1,
    utf8         => 0,
);

sub inflate_json_columns ( $, $result_class ) {
    my $columns_info = $result_class->columns_info;
    for my $column ( sort keys %{$columns_info} ) {
        next if !_is_json_column( $columns_info->{$column} );

        $result_class->inflate_column(
            $column,
            {
                inflate => \&_inflate,
                deflate => \&_deflate,
            }
        );
    }

    return;
}

sub _is_json_column ($column_info) {
    my $data_type = lc( $column_info->{data_type} || q{} );

    return exists $JSON_DATA_TYPES{$data_type} ? 1 : 0;
}

# DBIx::Class calls both as ->($value, $result_object); the row is not needed
# to encode or decode a column, but a one-argument signature made every JSON
# column write die.
sub _inflate ( $value, @ ) {
    return $CODEC->decode($value);
}

sub _deflate ( $value, @ ) {
    return $CODEC->encode($value);
}

1;

__END__

=head1 NAME

GPForum::Schema::JsonColumn - JSON serialization for json/jsonb columns.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    __PACKAGE__->add_columns( payload => { data_type => 'jsonb' } );
    GPForum::Schema::JsonColumn->inflate_json_columns(__PACKAGE__);

=head1 DESCRIPTION

DBD::Pg cannot bind Perl references, so writing a hash or array reference
into a C<json> or C<jsonb> column fails with "Cannot bind a reference".
Result classes call C<inflate_json_columns> after C<add_columns> so every
JSON column deflates Perl structures to canonical JSON text on write and
inflates JSON text back to Perl structures on read.

Plain strings are passed through unchanged on write, because DBIx::Class
only deflates references.

=head1 SUBROUTINES/METHODS

=head2 inflate_json_columns

Registers the JSON codec on every C<json>/C<jsonb> column of the given
result class.

=head1 DIAGNOSTICS

Invalid JSON read from the database dies in the JSON decoder.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<DBIx::Class::InflateColumn> through L<DBIx::Class::Core>,
L<JSON::MaybeXS> and L<Const::Fast>.

=head1 INCOMPATIBILITIES

Columns with a L<DBIx::Class::FilterColumn> filter cannot also be inflated.

=head1 BUGS AND LIMITATIONS

C<get_column> still returns the raw JSON text; use the column accessor or
C<get_inflated_column> for the decoded structure.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
