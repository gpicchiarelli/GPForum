# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Mojo::File;
use Test::Mojo;
use Test::More;

use lib 'lib';

our $VERSION = '0.001';

# ui_path writes the path url_for would, without the URL object url_for
# builds on the way: the pages that write one for every post use it.
my $test       = Test::Mojo->new('GPForum');
my $controller = $test->app->build_controller;

for my $route (
    [ 'home',                {} ],
    [ 'categories',          {} ],
    [ 'category',            { category_id   => 'category-1' } ],
    [ 'thread',              { thread_id     => 'thread-1' } ],
    [ 'profile',             { username      => 'giacomo_forum' } ],
    [ 'post_edit',           { post_id       => 'post-1' } ],
    [ 'post_report',         { post_id       => 'post-1' } ],
    [ 'thread_subscribe',    { thread_id     => 'thread-1' } ],
    [ 'attachment_download', { attachment_id => 'attachment-1' } ],
  )
{
    my ( $name, $values ) = @{$route};
    is(
        $controller->ui_path( $name, %{$values} ),
        $controller->url_for( $name, %{$values} )->path->to_string,
        "$name is the path url_for writes"
    );
}

# Every named route the application has, with a value for each placeholder
# of its chain: the writer ui_path builds for a route is the path url_for
# writes, or ui_path leaves the route to url_for.
my %seen;
for my $route ( _named_routes( $test->app->routes ) ) {
    my $name = $route->name;
    next if $seen{$name}++;

    my %values = map { $_ => "$_-value" } _placeholders($route);
    is(
        $controller->ui_path( $name, %values ),
        $controller->url_for( $name, %values )->path->to_string,
        "$name is the path url_for writes"
    );
}

# Under a prefix, as a reverse proxy may mount the forum, the prefix leads.
my $base = $controller->req->url->base;
$base->path('/forum/');
delete $controller->stash->{ui_base_path};
is(
    $controller->ui_path( 'thread', thread_id => 'thread-1' ),
    $controller->url_for( 'thread', thread_id => 'thread-1' )->path->to_string,
    'a base path leads the route'
);

# Every route a template names through ui_path is a route the application
# has: a misspelt name fails here, not on the page that renders it.
my $routes = $test->app->routes;
my @unknown;
for my $template ( Mojo::File->new('templates')->list_tree->each ) {
    next if $template !~ /[.]html[.]ep\z/msx;
    my $source = $template->slurp;
    while ( $source =~ /\bui_path[(]\s*'([[:lower:]_]+)'/gmsx ) {
        if ( !$routes->lookup($1) ) {
            push @unknown, "$template: $1";
        }
    }
}
is_deeply( \@unknown, [], 'every route a template names exists' );

done_testing();

sub _named_routes ($route) {
    return (
        (
                 $route->name
              && $route->name !~ /\A[[:xdigit:]]{32}\z/msx ? $route : ()
        ),
        map { _named_routes($_) } @{ $route->children }
    );
}

sub _placeholders ($route) {
    my @names;
    my $link = $route;
    while ($link) {
        push @names, @{ $link->pattern->placeholders };
        $link = $link->parent;
    }

    return @names;
}

1;
