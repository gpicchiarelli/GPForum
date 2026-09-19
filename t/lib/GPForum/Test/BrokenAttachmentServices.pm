package GPForum::Test::BrokenAttachmentServices;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base 'GPForum::Test::AttachmentWebServices';

our $VERSION = '0.001';

sub upload_and_link {
    croak 'pipeline down';
}

sub download {
    croak 'delivery down';
}

1;

__END__

=head1 NAME

GPForum::Test::BrokenAttachmentServices - Attachment fakes that throw.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $broken = GPForum::Test::BrokenAttachmentServices->new;

=head1 DESCRIPTION

Test double that inherits the attachment web fakes and throws on upload and
download so workflow tests can assert C<failed> mapping.

=head1 SUBROUTINES/METHODS

=head2 upload_and_link

Throws instead of storing an attachment.

=head2 download

Throws instead of delivering bytes.

=head1 DIAGNOSTICS

Always throws.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

Uses L<GPForum::Test::AttachmentWebServices>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Intended only for workflow unit tests.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
