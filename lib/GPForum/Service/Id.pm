package GPForum::Service::Id;

use strict;
use warnings;

use Mojo::Base -base;

use UUID::Tiny qw(create_uuid_as_string UUID_V4);

our $VERSION = '0.001';

sub uuid {
    my ($self) = @_;

    return create_uuid_as_string(UUID_V4);
}

1;

__END__

=head1 NAME

GPForum::Service::Id - Identifier service.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $id = GPForum::Service::Id->new->uuid;

=head1 DESCRIPTION

Provides UUID generation behind a replaceable service boundary.

=head1 SUBROUTINES/METHODS

=head2 uuid

Returns a version-four UUID string.

=head1 DIAGNOSTICS

UUID generation errors are surfaced by L<UUID::Tiny>.

=head1 CONFIGURATION AND ENVIRONMENT

No environment variables are read.

=head1 DEPENDENCIES

Uses L<UUID::Tiny>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only UUID version four generation is exposed.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
