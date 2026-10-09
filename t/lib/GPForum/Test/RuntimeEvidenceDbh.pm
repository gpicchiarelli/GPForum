# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::RuntimeEvidenceDbh;

use Mojo::Base -base;
use v5.40;

our $VERSION = '0.001';

# A database handle whose pg_settings report every asked-for setting: 1, and
# shared_buffers as 16384 blocks of 8kB.

sub selectall_arrayref {
    my ( $self, $sql, $attributes, @settings ) = @_;

    return [
        map {
            +{
                name    => $_,
                setting => $_ eq 'shared_buffers' ? '16384' : '1',
                unit    => $_ eq 'shared_buffers' ? '8kB'   : undef,
                source  => 'test',
            }
        } @settings
    ];
}

1;
