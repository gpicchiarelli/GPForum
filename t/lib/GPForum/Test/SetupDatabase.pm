# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::SetupDatabase;

use Mojo::Base -base, -signatures;
use v5.40;

our $VERSION = '0.001';

# PostgreSQL as gpforum setup finds it, for a test: a superuser who answers
# (or none, with the error the forum's role then meets), and whether the
# role and the database exist. What setup makes is kept, the password the
# role is made with included.
has superuser => 'you';

# The superuser role that answered, and where its login came from: a test
# that names them reads which way in setup says it used.
has as       => undef;
has from     => undef;
has role     => 0;
has database => 0;
has error    => undef;
has made     => sub { return []; };

# What each superuser login was told, when none answers.
has tried => sub {
    return [ { as => 'you', reason => 'role "you" does not exist' } ];
};

sub inspect ( $self, %target ) {
    return { superuser => undef, error => $self->error, tried => $self->tried }
      if !$self->superuser;

    return {
        superuser => $self->superuser,
        role      => $self->role,
        database  => $self->database,
    };
}

sub connection_error ( $self, %target ) {
    return $self->superuser ? undef : $self->error;
}

sub provision ( $self, %target ) {
    my %made = (
        role_made     => $self->role     ? 0 : 1,
        database_made => $self->database ? 0 : 1,
    );
    push @{ $self->made },
      $made{role_made} ? { %made, password => $target{password} } : {%made};
    $self->role(1);
    $self->database(1);

    return {
        %made,
        superuser => $self->superuser,
        ( defined $self->as   ? ( as   => $self->as )   : () ),
        ( defined $self->from ? ( from => $self->from ) : () ),
    };
}

sub commands ( $self, %target ) {
    return [ $target{role_exists} ? () : 'psql-role', 'psql-database' ];
}

1;
