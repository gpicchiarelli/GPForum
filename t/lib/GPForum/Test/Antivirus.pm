# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Antivirus;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

# A scanner with a fixed verdict that counts how often it was asked. The real
# ones are GPForum::Infrastructure::Antivirus::Clamd and ::Command; their own
# tests drive a real socket and a real process.
has detects       => undef;
has fails_on      => undef;
has max_bytes     => undef;
has reachable     => 1;
has health_report => undef;
has health_status => 'ok';
has immediate     => 1;
has scans         => 0;
has verdict => sub { return { status => 'clean', engine => 'Fake 1/1' }; };

sub available {
    my ($self) = @_;

    return $self->reachable;
}

sub within_request {
    my ($self) = @_;

    return $self;
}

sub answers_immediately {
    my ($self) = @_;

    return $self->immediate;
}

# With detects set, content matching it is infected and everything else
# takes the fixed verdict.
sub scan {
    my ( $self, $content ) = @_;

    $self->scans( $self->scans + 1 );
    if ( defined $self->max_bytes && length $content > $self->max_bytes ) {
        return {
            status => 'error',
            error  => 'clamd: INSTREAM size limit exceeded. ERROR'
        };
    }
    my $fails_on = $self->fails_on;
    if ( defined $fails_on && defined $content && $content =~ $fails_on ) {
        return { status => 'error', error => 'this file always fails' };
    }
    my $detects = $self->detects;
    if ( defined $detects && defined $content && $content =~ $detects ) {
        return {
            status    => 'infected',
            engine    => 'Fake 1/1',
            signature => 'Eicar-Test-Signature',
        };
    }

    return { %{ $self->verdict } };
}

# A fixed report when one is given, otherwise the configured status.
sub health {
    my ($self) = @_;

    return { %{ $self->health_report } } if $self->health_report;

    return { mode => 'fake', status => $self->health_status };
}

1;
