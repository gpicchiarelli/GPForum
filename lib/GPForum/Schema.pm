package GPForum::Schema;

use strict;
use warnings;

use Mojo::Base 'DBIx::Class::Schema';

our $VERSION = '0.001';

__PACKAGE__->load_namespaces;

sub connect_from_config {
    my ( $class, $config ) = @_;

    return $class->connect( $config->database_connect_info );
}

1;

__END__

=head1 NAME

GPForum::Schema - DBIx::Class schema root.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $schema = GPForum::Schema->connect_from_config($config);

=head1 DESCRIPTION

Defines the GPForum DBIx::Class schema root and keeps database wiring outside
the Mojolicious application root.

=head1 SUBROUTINES/METHODS

=head2 connect_from_config

Creates a schema connection from a validated GPForum configuration object.

=head1 DIAGNOSTICS

Connection failures are reported by DBIx::Class and DBI.

=head1 CONFIGURATION AND ENVIRONMENT

Receives database connection information from L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<DBIx::Class::Schema> through L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only foundational metadata results are present in this milestone.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
