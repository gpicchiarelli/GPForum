# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RealtimeSupervisor;

use v5.40;

our $VERSION = '0.001';

sub new {
    my ( $class, %input ) = @_;

    return bless { enabled => $input{enabled} ? 1 : 0 }, $class;
}

sub snapshot {
    my ($self) = @_;

    return {
        enabled  => $self->{enabled} ? 1 : 0,
        running  => 0,
        stats    => {},
        listener => {
            listen_notify_received => 0,
        },
    };
}

1;
