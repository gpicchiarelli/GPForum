# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SetupAccount;

use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

our $VERSION = '0.001';

# The service account as gpforum setup run as root finds it, for a test run
# by anyone: missing until made, then this process's own ids, so the file
# setup writes can be given to its group without root. What setup asked of
# it is kept.
has name            => 'gpforum';
has exists          => 0;
has fails           => undef;
has system_commands => sub { return [ [qw(useradd --system gpforum)] ]; };
has made            => sub { return []; };

# The ids it answers with instead, [ uid, gid ]: an account the file setup
# writes is not the account's to read.
has given => undef;

sub ids ($self) {
    return ()                if !$self->exists;
    return @{ $self->given } if defined $self->given;

    return ( $EFFECTIVE_USER_ID, ( split q{ }, $EFFECTIVE_GROUP_ID )[0] );
}

sub group_id ($self) {
    return $self->exists ? ( $self->ids )[1] : undef;
}

sub commands ( $self, $home ) {
    return $self->system_commands;
}

sub make ( $self, $home ) {
    push @{ $self->made }, "$home";
    return { command => 'useradd --system gpforum', reason => $self->fails }
      if defined $self->fails;

    $self->exists(1);

    return undef;
}

sub make_directory ( $self, $directory ) {
    return [] if -d $directory;

    path($directory)->make_path;

    return [$directory];
}

1;
