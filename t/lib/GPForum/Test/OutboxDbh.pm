package GPForum::Test::OutboxDbh;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

has attrs        => sub { return {}; };
has bind         => sub { return []; };
has claimed_ids  => sub { return []; };
has claimed_rows => sub { return []; };
has driver_name  => 'Pg';
has do_bind      => sub { return []; };
has do_sql       => sub { return []; };
has sql          => q{};

sub selectall_arrayref {
    my ( $self, $sql, $attrs, @bind ) = @_;

    $self->sql($sql);
    $self->attrs($attrs);
    $self->bind( \@bind );

    return $self->claimed_rows if @{ $self->claimed_rows };

    return [ map { { outbox_id => $_ } } @{ $self->claimed_ids } ];
}

sub execute_statement {
    my ( $self, $sql, $attrs, @bind ) = @_;

    push @{ $self->do_sql },  $sql;
    push @{ $self->do_bind }, \@bind;

    return 1;
}

1;
