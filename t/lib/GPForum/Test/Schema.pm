package GPForum::Test::Schema;

use strict;
use warnings;

use Mojo::Base -base;

use GPForum::Test::ResultSet;

our $VERSION = '0.001';

has created               => sub { return {}; };
has skip_search_count     => 0;
has transactions          => 0;
has existing_usernames    => sub { return {}; };
has existing_emails       => sub { return {}; };
has find_misses           => 0;
has users                 => sub { return []; };
has credentials           => sub { return []; };
has command_logs          => sub { return []; };
has event_logs            => sub { return []; };
has audit_logs            => sub { return []; };
has identity_tokens       => sub { return []; };
has outbox_messages       => sub { return []; };
has posts                 => sub { return []; };
has post_bodies           => sub { return []; };
has post_revisions        => sub { return []; };
has reports               => sub { return []; };
has sessions              => sub { return []; };
has threads               => sub { return []; };
has thread_counters       => sub { return []; };
has thread_counter_shards => sub { return []; };
has storage               => undef;

sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::ResultSet->new( schema => $self, name => $name );
}

sub txn_do {
    my ( $self, $code ) = @_;

    $self->transactions( $self->transactions + 1 );

    return $code->();
}

sub created_for {
    my ( $self, $name ) = @_;

    $self->created->{$name} ||= [];

    return $self->created->{$name};
}

sub transaction_count {
    my ($self) = @_;

    return $self->transactions;
}

1;
