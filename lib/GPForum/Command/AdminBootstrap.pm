package GPForum::Command::AdminBootstrap;

use strict;
use warnings;

use Carp qw(croak);
use Mojo::Base -base;

use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Admin::Bootstrapper;

our $VERSION = '0.001';

has schema => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $options = _parse_arguments(@arguments);
    my $result =
      GPForum::Service::Admin::Bootstrapper->new( schema => $self->_schema )
      ->bootstrap($options);

    print _result_line( $options, $result )
      or croak 'failed to write admin bootstrap result';

    return 0;
}

sub _schema {
    my ($self) = @_;

    return $self->schema if $self->schema;

    my $config = GPForum::Config->from_environment;
    return GPForum::Schema->connect_from_config($config);
}

sub _parse_arguments {
    my (@arguments) = @_;

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

sub _field_for_flag {
    my ($flag) = @_;

    my %field_by_flag = (
        '--user-id'       => 'user_id',
        '--actor-user-id' => 'actor_user_id',
        '--role-name'     => 'role_name',
    );

    return $field_by_flag{$flag};
}

sub _required_value {
    my ( $flag, $arguments ) = @_;

    croak _usage() if !@{$arguments};

    my $value = shift @{$arguments};
    croak _usage() if !_has_text($value) || substr( $value, 0, 1 ) eq q{-};

    return $value;
}

sub _result_line {
    my ( $options, $result ) = @_;

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

sub _usage {
    return
"Usage: bin/gpforum-admin-bootstrap --user-id USER_ID [--actor-user-id USER_ID] [--role-name ROLE]\n";
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
}

1;
