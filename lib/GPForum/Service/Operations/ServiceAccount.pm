# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::ServiceAccount;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

use GPForum::OS;

our $VERSION = '0.001';

# The account GPForum's services run as -- the units', the rc scripts' and
# the plists' gpforum -- and the directory it writes the uploads to. gpforum
# setup makes them, as root, where the system has one command for it (ADR
# 0122), and says the commands where it has not.

# What the service may write, readable by its group and nobody else.
const my $PRIVATE_DIRECTORY => oct '750';

# Where getpwnam and getgrnam put the ids.
const my $USER_ID  => 2;
const my $GROUP_ID => 2;

has os   => sub { return GPForum::OS->detect; };
has name => 'gpforum';

# Runs a command, an argument list, and returns undef or why it failed; a
# test gives its own.
has run => sub {
    return sub (@command) {
        my $status = system { $command[0] } @command;
        return undef       if $status == 0;
        return "$OS_ERROR" if $status < 0;

        return 'it exited ' . ( $status >> 8 );    ## no critic (ValuesAndExpressions::ProhibitMagicNumbers) -- the exit status sits above the signal's eight bits
    };
};

# The account's user and group ids, or an empty list when it does not
# exist.
sub ids ($self) {
    my @user = getpwnam $self->name;
    return () if !@user;

    return ( $user[$USER_ID], $user[ $USER_ID + 1 ] );
}

# The id of the group named after the account, or undef: the environment
# file is the group's to read.
sub group_id ($self) {
    my @group = getgrnam $self->name;

    return @group ? $group[$GROUP_ID] : undef;
}

# The commands that make the account on this system, each an argument list;
# empty where gpforum setup leaves it to the operator.
sub commands ( $self, $home ) {
    return $self->os->service_account_commands( $self->name, "$home" );
}

# Makes the account with this system's commands. Returns undef when it was
# made, or { command, reason } for the command that failed.
sub make ( $self, $home ) {
    for my $command ( @{ $self->commands($home) } ) {
        my $reason = $self->run->( @{$command} );
        next if !defined $reason;

        return { command => join( q{ }, @{$command} ), reason => $reason };
    }

    return undef;
}

# Makes a directory and those above it that are missing, each owned by the
# account with mode 0750. Returns the directories it made, or croaks with
# the system's reason.
sub make_directory ( $self, $directory ) {
    my ( $uid, $gid ) = $self->ids;
    croak 'the account ' . $self->name . ' does not exist' if !defined $uid;

    my @missing;
    my $path = path($directory);
    while ( !-d $path ) {
        unshift @missing, $path;
        my $parent = $path->dirname;
        last if $parent eq $path;
        $path = $parent;
    }
    for my $made (@missing) {
        mkdir $made or croak "mkdir $made: $OS_ERROR";
        chown $uid, $gid, $made or croak "chown $made: $OS_ERROR";
        chmod $PRIVATE_DIRECTORY, "$made" or croak "chmod $made: $OS_ERROR";
    }

    return [ map { "$_" } @missing ];
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::ServiceAccount - The account GPForum's services
run as.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $account = GPForum::Service::Operations::ServiceAccount->new;
    if ( !$account->ids ) {
        my $failed = $account->make('/opt/gpforum');
    }
    $account->make_directory('/opt/gpforum/var/attachments');

=head1 DESCRIPTION

The C<gpforum> account the shipped units, rc scripts and plists run the
services as, and the directories it writes. C<gpforum setup>, run as root,
makes the account with the system's own command -- C<useradd> on Linux,
C<pw useradd> on FreeBSD (L<GPForum::OS>) -- and, where the system has none
GPForum runs, says how instead (ADR 0122).

=head1 SUBROUTINES/METHODS

=head2 ids

The account's user and group ids, or an empty list when it does not exist.

=head2 group_id

The id of the group named after the account, or undef.

=head2 commands

Takes the account's home and returns the commands that make the account on
this system, each an argument list; empty where GPForum leaves it to the
operator.

=head2 make

Takes the account's home and runs those commands. Returns undef when they
succeeded, or C<command> and C<reason> for the one that failed.

=head2 make_directory

Takes a directory and makes it, and each one above it that is missing,
owned by the account with mode 0750. Returns the directories made; croaks
with the system's reason.

=head1 DIAGNOSTICS

C<make_directory> croaks with the system's reason, or when the account does
not exist.

=head1 CONFIGURATION AND ENVIRONMENT

None.

=head1 DEPENDENCIES

L<GPForum::OS> for the commands.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Making the account and giving it a directory need root.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
