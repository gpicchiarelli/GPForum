# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use Digest::SHA qw(sha256_hex);
use English     qw(-no_match_vars);
use File::Temp  qw(tempdir);
use Mojo::File  qw(path);
use Mojo::URL;
use Mojolicious;
use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Security::BrowserHeaders;
use GPForum::Web::AssetManifest;

our $VERSION = '0.001';
our $TODO;

# Quality program 7.7: every static file a page names carries the digest of
# its bytes, and the response for that exact URL may be kept for a year.
# Before this the layout linked /gpforum-ssr.css bare and the static file
# server sent no Cache-Control at all, so a deploy's stylesheet reached a
# browser whenever its heuristic freshness ran out.

const my $HTTP_OK           => 200;
const my $HTTP_PARTIAL      => 206;
const my $HTTP_NOT_MODIFIED => 304;
const my $HTTP_BAD_RANGE    => 416;
const my $AN_HOUR_AGO       => 3600;
const my $DIGEST_LENGTH     => 12;
const my $IMMUTABLE         => 'public, max-age=31536000, immutable';
const my $SHORT             => 'public, max-age=3600';
const my $PRIVATE_IMMUTABLE => 'private, max-age=31536000, immutable';
const my $PRIVATE_SHORT     => 'private, max-age=3600';
const my $NO_CACHE          => 'no-cache';
const my @STATIC_ROOTS      => qw(assets/css assets/img);
const my @LAYOUT_PAGES      => qw(/login /register /legal/privacy);
const my $ASSET_ELEMENTS    => 'link[href], script[src], img[src]';

# The header's mark is drawn by components/site_header, which this change
# did not own; it still names the bare file.
const my $NOT_YET_VERSIONED => 'img.brand__mark';

_manifest_digests_the_bytes();
_a_changed_file_changes_its_url();
_a_file_rewritten_in_place_is_not_immutable();
_cache_policy();
_rendered_pages_name_the_digest();
_the_stylesheet_names_the_digest();
_static_responses_carry_the_policy();
_a_response_that_sets_a_cookie_is_private();
_only_the_digested_file_is_immutable();
_proxies_send_the_same_policy();

done_testing();

sub _manifest_digests_the_bytes {
    my $first_root = path( tempdir( CLEANUP => 1 ) );
    my $later_root = path( tempdir( CLEANUP => 1 ) );
    $first_root->child('site.css')->spew('body { color: black; }');
    $later_root->child('site.css')->spew('shadowed by the first root');
    my $icons = $later_root->child('icons')->make_path;
    $icons->child('mark.svg')->spew('<svg/>');

    my $manifest = GPForum::Web::AssetManifest->new(
        roots => [ "$first_root", "$later_root", "$first_root/absent" ] );

    is( $manifest->digest('site.css'), _short_digest('body { color: black; }'),
        'the digest is the first twelve hex digits of the SHA-256 of the bytes'
    );
    is(
        $manifest->digest('/site.css'),
        $manifest->digest('site.css'),
        'a leading slash names the same file'
    );
    is( $manifest->digest('icons/mark.svg'),
        _short_digest('<svg/>'),
        'a file below a root is named by its relative path' );
    is( $manifest->digest('missing.css'),
        undef, 'a name no root holds has no digest' );

    return;
}

sub _a_changed_file_changes_its_url {
    my $root = path( tempdir( CLEANUP => 1 ) );
    my $file = $root->child('site.css');
    $file->spew('body { color: black; }');

    my $controller = Mojolicious->new->build_controller;
    my $before     = GPForum::Web::AssetManifest->new( roots => ["$root"] );
    my $old_url    = $before->asset_url( $controller, 'site.css' )->to_string;
    is(
        $old_url,
        '/site.css?v=' . _short_digest('body { color: black; }'),
        'the URL names the file and the digest of its bytes'
    );
    is(
        $before->cache_control(
            name    => 'site.css',
            version => _short_digest('body { color: black; }'),
        ),
        $IMMUTABLE,
        'and that URL is immutable while the file is unchanged'
    );

    $file->spew('body { color: navy; background: white; }');
    my $after   = GPForum::Web::AssetManifest->new( roots => ["$root"] );
    my $new_url = $after->asset_url( $controller, 'site.css' )->to_string;
    isnt( $new_url, $old_url, 'a changed file gets a new URL' );
    is(
        $new_url,
        '/site.css?v='
          . _short_digest('body { color: navy; background: white; }'),
        'which carries the digest of the new bytes'
    );
    is(
        $before->cache_control(
            name    => 'site.css',
            version => _short_digest('body { color: black; }'),
        ),
        $SHORT,
        'a file changed since it was digested is no longer called immutable'
    );

    my $died = !eval { $after->asset_url( $controller, 'sitee.css' ); 1 };
    ok( $died, 'a misspelt asset fails the render' );
    like(
        $EVAL_ERROR,
        qr/unknown [ ] asset: [ ] sitee[.]css/msx,
        'and names the asset'
    );

    return;
}

# Rewritten in place to bytes of the same length, a file keeps its device,
# inode and size: only its modification time says it is not the file that
# was digested.
sub _a_file_rewritten_in_place_is_not_immutable {
    my $root    = path( tempdir( CLEANUP => 1 ) );
    my $file    = $root->child('site.css')->spew('body { color: black; }');
    my $earlier = time - $AN_HOUR_AGO;
    utime $earlier, $earlier, "$file";

    my $manifest = GPForum::Web::AssetManifest->new( roots => ["$root"] );
    $manifest->files;
    my $before = $file->stat;

    $file->spew('body { color: white; }');
    my $after = $file->stat;
    ok(
        $after->ino == $before->ino && $after->size == $before->size,
        'the file is rewritten in place to bytes of the same length'
    );
    is(
        $manifest->cache_control(
            name    => 'site.css',
            version => _short_digest('body { color: black; }'),
        ),
        $SHORT,
        'a newer modification time is enough to stop calling it immutable'
    );

    return;
}

sub _cache_policy {
    my $manifest = GPForum::Web::AssetManifest->new( roots => [@STATIC_ROOTS] );
    my $digest   = _file_digest('gpforum-ssr.css');

    is( $manifest->digest('gpforum-ssr.css'),
        $digest, 'the stylesheet is digested from its bytes on disk' );
    is(
        $manifest->cache_control(
            name    => 'gpforum-ssr.css',
            version => $digest
        ),
        $IMMUTABLE,
        'the current digest is cached for a year, immutable'
    );
    is(
        $manifest->cache_control(
            name    => 'gpforum-ssr.css',
            version => '000000000000'
        ),
        $SHORT,
        'another digest gets the short lifetime'
    );
    is( $manifest->cache_control( name => 'gpforum-ssr.css' ),
        $SHORT, 'so does the bare URL' );
    is(
        $manifest->cache_control(
            name    => 'nothing.css',
            version => $digest
        ),
        $SHORT,
        'and a name the manifest does not hold'
    );
    is(
        $manifest->cache_control(
            development => 1,
            name        => 'gpforum-ssr.css',
            version     => $digest,
        ),
        $NO_CACHE,
        'development revalidates every response'
    );

    return;
}

# The stylesheet fetches files of its own, the typeface: a url() there is
# written by hand, so nothing but this keeps its version the file's digest.
# With another one the file would be asked for again every hour; with the
# digest of an older file, kept for a year under the new one's name.
sub _the_stylesheet_names_the_digest {
    my $manifest = GPForum::Web::AssetManifest->new( roots => [@STATIC_ROOTS] );
    my $css      = path('assets/css/gpforum-ssr.css')->slurp;
    my %fetched = $css =~ m{url[(] "/ ([^"?]+) [?]v= ([[:xdigit:]]+) " [)]}gmsx;
    my @bare    = $css =~ m{url[(] ( "? / [^)?]+ "? ) [)]}gmsx;

    ok( scalar keys %fetched, 'the stylesheet fetches the typeface' );
    is_deeply( \@bare, [], 'and no file without a version' );
    for my $name ( sort keys %fetched ) {
        is(
            $fetched{$name},
            $manifest->digest($name),
            "$name is named with the digest of its bytes"
        );
    }

    my $test = Test::Mojo->new('GPForum');
    $test->get_ok('/login')->status_is($HTTP_OK);
    my $page    = $test->tx->res->dom;
    my $preload = $page->at('link[rel="preload"][as="font"][crossorigin]');
    ok( $preload, 'a page preloads the face its text is set in' );
    my $preloaded = $preload ? $preload->attr('href') : q{};
    ok(
        index( $css, qq{url("$preloaded")} ) >= 0,
        'under the same URL the stylesheet asks for'
    );

    return;
}

sub _rendered_pages_name_the_digest {
    my $test = Test::Mojo->new('GPForum');

    for my $page (@LAYOUT_PAGES) {
        $test->get_ok($page)->status_is($HTTP_OK);
        my $dom = $test->tx->res->dom;

        my %seen;
        for my $element ( $dom->find($ASSET_ELEMENTS)->each ) {
            my $url  = Mojo::URL->new( $element->{href} // $element->{src} );
            my $name = _static_name($url);
            next if !defined $name;

            $seen{$name}++;
            local $TODO =
              $element->matches($NOT_YET_VERSIONED)
              ? 'components/site_header still links the bare mark'
              : undef;
            is( $url->query->param('v'),
                _file_digest($name),
                "$page: $url carries the digest of $name" );
        }

        ok( $seen{'gpforum-ssr.css'},  "$page links the stylesheet" );
        ok( $seen{'gpforum-mark.svg'}, "$page links the icon" );
        $test->element_exists(
            'link[rel="stylesheet"][href="/gpforum-ssr.css?v='
              . _file_digest('gpforum-ssr.css') . '"]',
            "$page: the stylesheet link is the versioned URL"
        );
        $test->element_exists(
            'link[rel="icon"][href="/gpforum-mark.svg?v='
              . _file_digest('gpforum-mark.svg') . '"]',
            "$page: so is the icon link"
        );
    }

    return;
}

sub _static_responses_carry_the_policy {
    my $test = Test::Mojo->new('GPForum');
    my $css  = '/gpforum-ssr.css?v=' . _file_digest('gpforum-ssr.css');
    my $icon = '/gpforum-mark.svg?v=' . _file_digest('gpforum-mark.svg');
    my $csp  = GPForum::Security::BrowserHeaders->new->content_security_policy;

    $test->app->mode('production');

    $test->get_ok($css);
    $test->status_is($HTTP_OK);
    $test->header_is( 'Cache-Control' => $IMMUTABLE );
    $test->header_is(
        'Content-Security-Policy' => $csp,
        'the browser headers, CSP included, are unchanged'
    );
    $test->header_is( 'X-Content-Type-Options' => 'nosniff' );
    $test->content_like( qr/--color-primary/msx,
        'the versioned URL serves the stylesheet' );
    my $response = $test->tx->res;
    my $etag     = $response->headers->etag;

    $test->get_ok( $css => { 'If-None-Match' => $etag } );
    $test->status_is($HTTP_NOT_MODIFIED);
    $test->header_is(
        'Cache-Control' => $IMMUTABLE,
        'a revalidation answers with the same lifetime'
    );

    $test->get_ok( $css => { Range => 'bytes=0-9' } );
    $test->status_is($HTTP_PARTIAL);
    $test->header_is(
        'Cache-Control' => $IMMUTABLE,
        'a part of the file is as immutable as the whole'
    );

    # A 416 refuses the range it was asked for; it is not the file. Given a
    # year, a cache could keep that refusal under the stylesheet's URL.
    $test->get_ok( $css => { Range => 'bytes=999999999-' } );
    $test->status_is($HTTP_BAD_RANGE);
    $test->header_is(
        'Cache-Control' => undef,
        'a refused range is given no lifetime'
    );

    $test->get_ok($icon);
    $test->status_is($HTTP_OK);
    $test->header_is( 'Cache-Control' => $IMMUTABLE );

    $test->get_ok('/gpforum-ssr.css');
    $test->status_is($HTTP_OK);
    $test->header_is(
        'Cache-Control' => $SHORT,
        'the bare URL keeps a short lifetime'
    );

    $test->get_ok('/gpforum-ssr.css?v=000000000000');
    $test->status_is($HTTP_OK);
    $test->header_is( 'Cache-Control' => $SHORT );
    $test->content_like( qr/--color-primary/msx,
        'an old digest is answered with the current file, briefly' );

    $test->app->mode('development');
    $test->get_ok($css);
    $test->status_is($HTTP_OK);
    $test->header_is(
        'Cache-Control' => $NO_CACHE,
        'development revalidates the stylesheet on every load'
    );

    return;
}

sub _a_response_that_sets_a_cookie_is_private {
    my $manifest = GPForum::Web::AssetManifest->new( roots => [@STATIC_ROOTS] );
    my $digest   = _file_digest('gpforum-ssr.css');

    is(
        $manifest->cache_control(
            name        => 'gpforum-ssr.css',
            sets_cookie => 1,
            version     => $digest,
        ),
        $PRIVATE_IMMUTABLE,
        'a response that sets a cookie keeps its lifetime, privately'
    );
    is(
        $manifest->cache_control(
            name        => 'gpforum-ssr.css',
            sets_cookie => 1
        ),
        $PRIVATE_SHORT,
        'and so does a short one'
    );
    is(
        $manifest->cache_control(
            development => 1,
            name        => 'gpforum-ssr.css',
            sets_cookie => 1,
        ),
        $NO_CACHE,
        'development stays no-cache'
    );

    # A page with a form keeps its CSRF token in the session cookie, and the
    # session guard reads the session on every request, static ones too, so
    # Mojolicious writes that cookie back on the stylesheet's response. It
    # used to go out marked public: a shared cache could keep it and hand
    # one visitor's session cookie to the next.
    my $test = Test::Mojo->new('GPForum');
    $test->app->mode('production');
    $test->get_ok('/login')->status_is($HTTP_OK);

    $test->get_ok("/gpforum-ssr.css?v=$digest")->status_is($HTTP_OK);
    my $response = $test->tx->res;
    ok( defined $response->headers->set_cookie,
        'the stylesheet response writes the session cookie back' );
    $test->header_is(
        'Cache-Control' => $PRIVATE_IMMUTABLE,
        'so it is cached for a year by the browser and by no shared cache'
    );

    $test->get_ok('/gpforum-ssr.css')->status_is($HTTP_OK);
    $test->header_is(
        'Cache-Control' => $PRIVATE_SHORT,
        'the bare URL is private too'
    );

    return;
}

sub _only_the_digested_file_is_immutable {
    my $first_root = path( tempdir( CLEANUP => 1 ) );
    my $later_root = path( tempdir( CLEANUP => 1 ) );
    $later_root->child('site.css')->spew('body { color: black; }');
    $later_root->child('mark.svg')->spew('<svg id="a"/>');

    my $application = Mojolicious->new;
    $application->mode('production');
    $application->static->paths( [ "$first_root", "$later_root" ] );
    my $manifest = GPForum::Web::AssetManifest->new(
        roots => [ "$first_root", "$later_root" ] );
    $manifest->files;
    $application->hook( after_static => sub ($c) { $manifest->apply($c); } );
    my $test = Test::Mojo->new($application);

    my $css = '/site.css?v=' . _short_digest('body { color: black; }');
    $test->get_ok($css)->status_is($HTTP_OK);
    $test->header_is(
        'Cache-Control' => $IMMUTABLE,
        'the file that was digested is immutable under its digest'
    );

    # An override dropped into an earlier root is served from then on, but
    # the digest in the URL names the bytes it shadows.
    $first_root->child('site.css')->spew('body { color: red; }');
    $test->get_ok($css)->status_is($HTTP_OK);
    $test->content_is( 'body { color: red; }',
        'a file added to an earlier root shadows the digested one' );
    $test->header_is(
        'Cache-Control' => $SHORT,
        'and is not called immutable under the digest of the file it hides'
    );
    my $shadow      = $test->tx->res;
    my $shadow_etag = $shadow->headers->etag;
    $test->get_ok( $css => { 'If-None-Match' => $shadow_etag } );
    $test->status_is($HTTP_NOT_MODIFIED);
    $test->header_is(
        'Cache-Control' => $SHORT,
        'nor when a browser revalidates its copy of it'
    );

    # A deploy renames new bytes over the file; nothing tells them apart from
    # the old by size or modification time.
    my $mark      = $later_root->child('mark.svg');
    my $mtime     = $mark->stat->mtime;
    my $temporary = $later_root->child('mark.svg.new')->spew('<svg id="b"/>');
    utime $mtime, $mtime, "$temporary";
    $temporary->move_to("$mark");
    $test->get_ok( '/mark.svg?v=' . _short_digest('<svg id="a"/>') );
    $test->status_is($HTTP_OK);
    $test->content_is( '<svg id="b"/>', 'the renamed file is what is served' );
    $test->header_is(
        'Cache-Control' => $SHORT,
        'and it is not called immutable under the digest of the one it replaced'
    );

    return;
}

sub _proxies_send_the_same_policy {
    my $nginx = path('deploy/nginx/gpforum.conf')->slurp;
    like(
        $nginx,
        qr/map [ ] \$arg_v [ ] \$gpforum_asset_cache_control [ ] [{]/msx,
        'nginx keys the lifetime on v'
    );
    like(
        $nginx,
        qr/"" \s+ "\Q$SHORT\E";/msx,
        'nginx gives a bare URL the short lifetime'
    );
    like(
        $nginx,
        qr/default \s+ "\Q$IMMUTABLE\E";/msx,
        'and a versioned one the immutable lifetime'
    );
    like(
        $nginx,
        qr{try_files [ ] /css\$uri [ ] /img\$uri [ ] \@gpforum_app;}msx,
        'nginx searches the static roots in the application order'
    );
    like(
        $nginx,
        qr/add_header [ ] Cache-Control [ ] \$gpforum_asset_cache_control/msx,
        'and sends that lifetime'
    );

    # With "always" nginx adds the header to its own 404 and 403 pages too,
    # and a versioned URL that is missing would be kept missing for a year.
    ok( $nginx !~ qr/add_header [ ] Cache-Control [^;\n]* [ ] always/msx,
        'nginx gives no lifetime to an error page' );

    my $caddy = path('deploy/caddy/Caddyfile')->slurp;
    like(
        $caddy,
        qr/\@versioned [ ] query [ ] v=[*]/msx,
        'Caddy matches a versioned request'
    );
    like(
        $caddy,
        qr/header [ ] \@versioned [ ] Cache-Control [ ] "\Q$IMMUTABLE\E"/msx,
        'Caddy sends it the immutable lifetime'
    );
    like(
        $caddy,
        qr/header [ ] \@unversioned [ ] Cache-Control [ ] "\Q$SHORT\E"/msx,
        'and the short one otherwise'
    );
    like(
        $caddy,
        qr{try_files [ ] /css[{]path[}] [ ] /img[{]path[}]}msx,
        'Caddy searches the static roots in the application order'
    );

    # Caddy's header directive also writes onto the 404 its file server
    # answers for a missing file; each handle that sends a lifetime must
    # match only files that exist.
    my @handles = $caddy =~ /^ [ ]* handle [ ]+ (\S+) [ ]+ [{]/gmsx;
    ok( scalar @handles, 'Caddy has handle blocks' );
    for my $handle (@handles) {
        my ($matcher) = $handle =~ /\A [@] (\w+) \z/msx;
        my ($definition) =
          defined $matcher
          ? $caddy =~ /^ [ ]* [@] \Q$matcher\E [ ]+ [{] (.*?) ^ [ ]{4} [}]/msx
          : ();
        like(
            $definition // q{},
            qr/^ [ ]* file [ ]+ [{]/msx,
            "Caddy's handle $handle matches only a file that exists"
        );
    }

    return;
}

# The file a URL on this site names, searched as the static file server
# searches; undef for any other URL (a page, another host).
sub _static_name ($url) {
    return if defined $url->host;

    my $name = join q{/}, @{ $url->path->parts };
    return if !length $name;

    for my $root (@STATIC_ROOTS) {
        return $name if -f path( $root, $name );
    }

    return;
}

sub _file_digest ($name) {
    for my $root (@STATIC_ROOTS) {
        my $file = path( $root, $name );
        return _short_digest( $file->slurp ) if -f $file;
    }

    return;
}

sub _short_digest ($bytes) {
    return substr sha256_hex($bytes), 0, $DIGEST_LENGTH;
}

1;
