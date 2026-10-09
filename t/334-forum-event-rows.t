# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Test::More;

use lib 'lib';

use GPForum::Service::Forum::Event;

our $VERSION = '0.001';

# Which fields of an event and its audit row the stored row answers before
# the command does. The golden tests (t/325, t/329) hand the builders rows
# and commands that agree, so they cannot tell which one a field is read
# from; here the row and the command disagree, and then the row is left out.

my $events = GPForum::Service::Forum::Event->new;

# [ aggregate, event type, field, where it is in the payload or metadata ]
my @FROM_ROW = (
    [ 'post',   'post.updated',     'thread_id',      'payload', 'metadata' ],
    [ 'post',   'post.deleted',     'thread_id',      'payload', 'metadata' ],
    [ 'post',   'post.undeleted',   'thread_id',      'payload', 'metadata' ],
    [ 'post',   'post.undeleted',   'author_user_id', 'payload' ],
    [ 'thread', 'thread.updated',   'slug',           'payload', 'metadata' ],
    [ 'thread', 'thread.updated',   'title',          'payload', 'metadata' ],
    [ 'thread', 'thread.moved',     'category_id',    'payload', 'metadata' ],
    [ 'thread', 'thread.deleted',   'category_id',    'payload', 'metadata' ],
    [ 'thread', 'thread.undeleted', 'category_id',    'payload', 'metadata' ],
    [ 'thread', 'thread.undeleted', 'author_user_id', 'payload' ],
);

for my $case (@FROM_ROW) {
    my ( $aggregate, $type, $field, @places ) = @{$case};
    my $command = {
        $aggregate => { "${aggregate}_id" => 'id-1', $field => 'command' },
        revision   => { revision_id       => 'revision-1' },
    };

    my %built = _built( $aggregate, $type,
        { command => $command, $aggregate => { $field => 'row' } } );
    for my $place (@places) {
        is( $built{$place}{$field},
            'row', "$type: the stored row's $field comes first in its $place" );
    }

    %built = _built( $aggregate, $type, { command => $command } );
    for my $place (@places) {
        is( $built{$place}{$field},
            'command',
            "$type: the command's $field fills in for a row without it" );
    }
}

# A field the command alone names is never read from the row.
my %built = _built(
    'post',
    'post.deleted',
    {
        command => { post => { deleted_by => 'command', post_id => 'post-1' } },
        post    => { deleted_by => 'row' },
    }
);
is( $built{payload}{deleted_by},
    'command', 'post.deleted: deleted_by is the command\'s' );
is( $built{envelope}{actor_id},
    'command', 'post.deleted: the actor is the command\'s' );

done_testing();

sub _built ( $aggregate, $type, $input ) {
    my $envelope_method = "${aggregate}_envelope";
    my $audit_method    = "${aggregate}_audit";
    my $envelope        = $events->$envelope_method( $type, $input );
    my $audit           = $events->$audit_method( $type, $input );

    return (
        envelope => $envelope,
        metadata => $audit->{metadata},
        payload  => $envelope->{payload},
    );
}

1;
