# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::ScriptedWorkflow;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# The result every call answers, whatever it was asked.
has answer => sub { return { ok => 1 } };

sub login ( $self, $input ) {
    return $self->answer;
}

sub save_bookmark ( $self, $input ) {
    return $self->answer;
}

1;

__END__

=head1 NAME

GPForum::Test::ScriptedWorkflow - A workflow that answers what the test
scripted.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $workflow = GPForum::Test::ScriptedWorkflow->new(
        answer => { ok => 0, status => 'failed' } );
    $app->helper( gp_identity_workflow => sub { return $workflow; } );

=head1 DESCRIPTION

Stands in for the identity or community workflow when a controller test needs
a result the real workflow only gives when its store breaks or races, such as
C<failed> or C<conflict>.

=head1 SUBROUTINES/METHODS

=head2 answer

The result hash every call returns; C<< { ok => 1 } >> by default.

=head2 login

Returns L</answer>.

=head2 save_bookmark

Returns L</answer>.

=head1 DIAGNOSTICS

None.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<Mojo::Base>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
