# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::Warmup;

use Mojo::Base 'GPForum::Base', -signatures;
use v5.40;

use Const::Fast;
use GPForum::Infrastructure::Row;
use Mojo::IOLoop;
use Mojo::UserAgent;
use Time::HiRes qw(time);

our $VERSION = '0.001';

# The pages that need no row to render, and the pages the newest thread
# gives: its category and itself, the two templates with the most in them.
const my @PAGES        => ( q{/}, '/categories', '/login', '/register' );
const my $MILLISECONDS => 1_000;

__PACKAGE__->requires(qw(application));

sub run ($self) {
    my $application = $self->application;
    my $started     = time;

    # A client of its own, on a loop of its own: the server's loop is not
    # running yet, and a request made through it would wait for it.
    my $client = Mojo::UserAgent->new(
        ioloop        => Mojo::IOLoop->new,
        max_redirects => 0,
    );
    $client->server->app($application);

    $application->defaults->{'gpforum.warming'} = 1;
    my @pages = map { _fetched( $client, $_ ) } @PAGES, $self->_listed_paths;
    delete $application->defaults->{'gpforum.warming'};
    $self->_disconnect;

    return {
        milliseconds => ( time - $started ) * $MILLISECONDS,
        pages        => \@pages,
    };
}

sub describe ( $, $report ) {
    my @pages = @{ $report->{pages} };

    return sprintf 'warmed %d pages before forking in %.0f ms: %s',
      scalar @pages, $report->{milliseconds},
      join ', ', map { "$_->{path} $_->{status}" } @pages;
}

sub _fetched ( $client, $path ) {
    my $status = $client->get($path)->res->code;

    return { path => $path, status => $status // 0 };
}

# The newest listed thread and its category, read as the sitemap reads them.
# Without a database to read -- not up yet, say -- the pages that need none
# are warmed and these are left.
sub _listed_paths ($self) {
    my @paths;
    try {
        my $controller = $self->application->build_controller;
        my $page =
          $controller->gp_thread_reader->list_public_threads( { limit => 1 } );
        my ($thread) = @{ $page->{items} || [] };
        if ($thread) {
            my $rows = 'GPForum::Infrastructure::Row';
            push @paths,
              $controller->ui_path(
                'category',
                category_id => $rows->column( $thread, 'category_id' )
              ),
              $controller->ui_path( 'thread',
                thread_id => $rows->column( $thread, 'thread_id' ) );
        }
    }
    catch ($error) {
        $self->application->log->warn(
            "warm-up found no thread to render: $error");
    };

    return @paths;
}

# The manager's connection is closed before it forks, so no worker inherits
# an open one.
sub _disconnect ($self) {
    try {
        my $controller = $self->application->build_controller;
        $controller->gp_schema->storage->disconnect;
    }
    catch ($error) {
        return;
    };

    return;
}

1;

__END__

=head1 NAME

GPForum::Web::Warmup - Render the main pages once before a pre-forking server forks.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $report = GPForum::Web::Warmup->new( application => $app )->run;
    $app->log->info( GPForum::Web::Warmup->describe($report) );

=head1 DESCRIPTION

A worker's first request of a page compiles the page's templates, prepares
its statements and fills the process's memos: the home page's first request
took 146 ms where its second took 16. A pre-forking server's manager runs
this before it forks, so every worker starts with that work done and
inherits it through the fork. L<GPForum::Bootstrap::Core> runs it from the
C<before_server_start> hook when the server is a L<Mojo::Server::Prefork>
(Hypnotoad is one) and C<warmup_enabled> is on.

The pages are requested through an in-process client, as the test client
requests them, with C<gpforum.warming> set on the stash defaults for the
duration: the realtime listener is not started for those requests, since
the workers would inherit its connection. The database connection the
manager opened is closed afterwards for the same reason.

=head1 SUBROUTINES/METHODS

=head2 run

Requests the home page, the category index, the login and registration
forms, and -- when the database answers -- the newest listed thread's
category and the thread itself. Returns C<< { pages, milliseconds } >>:
C<pages> is an array reference of C<< { path, status } >> in the order
requested, C<status> being 0 for a request that got no response.

=head2 describe

Class method. Takes a report from L</run> and returns one line for the log:
how many pages were warmed, in how long, and each page's path and status.

=head1 DIAGNOSTICS

A database that cannot be read leaves the two listed pages out and logs a
warning; nothing here dies, so a server starts with cold workers rather
than not at all.

=head1 CONFIGURATION AND ENVIRONMENT

C<GPFORUM_WARMUP_ENABLED> (on by default) is read by L<GPForum::Config>;
this module reads nothing itself.

=head1 DEPENDENCIES

L<Mojo::UserAgent>, L<GPForum::Infrastructure::Row>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Only the templates these pages render are compiled before the fork; the
rest compile on their first request, as before.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
