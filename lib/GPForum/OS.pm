# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::OS;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::OS::Base;
use GPForum::OS::Darwin;
use GPForum::OS::FreeBSD;
use GPForum::OS::Linux;

our $VERSION = '0.001';

const my $OS_DARWIN  => 'darwin';
const my $OS_FREEBSD => 'freebsd';
const my $OS_LINUX   => 'linux';

sub detect ($class) {
    return $class->from_name($OS_DARWIN)  if $OSNAME eq $OS_DARWIN;
    return $class->from_name($OS_FREEBSD) if $OSNAME eq $OS_FREEBSD;
    return $class->from_name($OS_LINUX)   if $OSNAME eq $OS_LINUX;

    return GPForum::OS::Base->new( name => 'unknown' );
}

sub from_name ( $class, $name ) {
    return GPForum::OS::Darwin->new  if $name eq $OS_DARWIN;
    return GPForum::OS::FreeBSD->new if $name eq $OS_FREEBSD;
    return GPForum::OS::Linux->new   if $name eq $OS_LINUX;

    return GPForum::OS::Base->new( name => 'unknown' );
}

1;
