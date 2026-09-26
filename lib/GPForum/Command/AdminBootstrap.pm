# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::AdminBootstrap;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Admin::Bootstrapper;

our $VERSION = '0.001';

has schema => undef;

# --help is answered before anything is parsed, and a parse failure becomes a
# usage error rather than an uncaught croak: this used to exit 255 with
# " at FILE line N." glued to the help text.
sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    return GPForum::Command::Usage->error(
        GPForum::Command::Usage->trimmed($EVAL_ERROR), _usage() );
}

sub _run ( $self, @arguments ) {
    my $options = _parse_arguments(@arguments);
    my $result =
      GPForum::Service::Admin::Bootstrapper->new( schema => $self->_schema )
      ->bootstrap($options);

    print _result_line( $options, $result )
      or croak 'failed to write admin bootstrap result';

    return 0;
}

sub _schema ($self) {
    return $self->schema if $self->schema;

    my $config = GPForum::Config->from_environment;
    return GPForum::Schema->connect_from_config($config);
}

sub _parse_arguments (@arguments) {
    my %options;
    while (@arguments) {
        my $flag  = shift @arguments;
        my $field = _field_for_flag($flag);
        croak _usage() if !_has_text($field);

        $options{$field} = _required_value( $flag, \@arguments );
    }

    croak _usage() if !_has_text( $options{user_id} );

    return \%options;
}

sub _field_for_flag ($flag) {
    my %field_by_flag = (
        '--user-id'       => 'user_id',
        '--actor-user-id' => 'actor_user_id',
        '--role-name'     => 'role_name',
    );

    return $field_by_flag{$flag};
}

sub _required_value ( $flag, $arguments ) {
    croak _usage() if !@{$arguments};

    my $value = shift @{$arguments};
    croak _usage() if !_has_text($value) || substr( $value, 0, 1 ) eq q{-};

    return $value;
}

sub _result_line ( $options, $result ) {
    my $counts = $result->{counts};

    return join q{ },
      'admin bootstrap',
      'role=' . $result->{role}{name},
      'user=' . $options->{user_id},
      'permissions=' . scalar @{ $result->{permissions} },
      'created_roles=' . $counts->{roles_created},
      'created_permissions=' . $counts->{permissions_created},
      'attached_permissions=' . $counts->{role_permissions_attached},
      'created_bindings=' . $counts->{bindings_created},
      "\n";
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return
"Usage: bin/gpforum-admin-bootstrap --user-id USER_ID [--actor-user-id USER_ID] [--role-name ROLE]\n";
}

sub _has_text ($value) {
    return defined $value && length $value;
}

1;
