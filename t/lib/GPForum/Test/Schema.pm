# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::Schema;

use strict;
use warnings;

use Const::Fast;
use Mojo::Base 'GPForum::Test::TransactionalSchema';

use GPForum::Test::ResultSet;

our $VERSION = '0.001';

const my @STORAGE_ACCESSOR => qw(
  audit_logs command_logs credentials event_logs identity_tokens
  outbox_messages post_bodies post_revisions posts reports sessions
  thread_counter_shards thread_counters threads users
);

has row_locks             => 0;
has skip_search_count     => 0;
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

sub storage_accessors {
    return @STORAGE_ACCESSOR;
}

sub resultset {
    my ( $self, $name ) = @_;

    return GPForum::Test::ResultSet->new( schema => $self, name => $name );
}

1;
