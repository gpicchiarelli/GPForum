# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Web::AssetManifest;

use Const::Fast;
use Digest::SHA;
use GPForum::X::Argument;
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

our $VERSION = '0.001';

# Twelve hex digits are 48 bits of the SHA-256: two versions of one file
# will not share them, and the URL stays short.
const my $DIGEST_LENGTH     => 12;
const my $SHA_ALGORITHM     => 256;
const my $VERSION_PARAMETER => 'v';

# A versioned URL names one sequence of bytes for good, so a browser may keep
# it for a year without asking again. Anything else -- a bare URL, a version
# that is not the file's digest, a file changed since the process started --
# is asked about again after an hour. In development a stylesheet is edited
# under a running server, so every response is revalidated.
const my $YEAR        => 'max-age=31536000, immutable';
const my $HOUR        => 'max-age=3600';
const my $DEVELOPMENT => 'no-cache';

# A response that writes a cookie back is one browser's: called public, a
# shared cache could keep it and hand that cookie to the next visitor.
const my $PUBLIC  => 'public';
const my $PRIVATE => 'private';

# A lifetime belongs on a response that carries the file (200, 206) or
# confirms the browser's copy of it (304). A 416 only refuses the range it
# was asked for: with a year on it, a cache could keep that refusal under
# the file's URL. (Read with exists: a const hash dies on a missing key.)
const my %CARRIES_THE_FILE => map { $_ => 1 } qw(200 206 304);

has roots => sub { return []; };
has files => sub ($self) { return $self->_scan_roots; };

sub digest ( $self, $name ) {
    my $file = $self->files->{ _relative($name) };
    return $file ? $file->{digest} : undef;
}

sub asset_url ( $self, $controller, $name ) {
    my $relative = _relative($name);
    my $file     = $self->files->{$relative};

    # A misspelt name in a template fails the render rather than sending a
    # URL nothing will ever invalidate.
    if ( !$file ) {
        GPForum::X::Argument->throw( message => "unknown asset: $name" );
    }

    return $controller->url_for( q{/} . $relative )
      ->query( $VERSION_PARAMETER => $file->{digest} );
}

sub cache_control ( $self, %input ) {
    return $DEVELOPMENT if $input{development};

    my $scope    = $input{sets_cookie}        ? $PRIVATE : $PUBLIC;
    my $lifetime = $self->_is_current(%input) ? $YEAR    : $HOUR;

    return "$scope, $lifetime";
}

sub apply ( $self, $controller ) {
    my $url      = $controller->req->url;
    my $response = $controller->res;
    return if !exists $CARRIES_THE_FILE{ $response->code // 0 };

    my $path = $url->path->clone;
    $path->canonicalize;
    my $name = join q{/}, @{ $path->parts };

    # The session guard reads the session on every request, static ones too,
    # and rendered() stores it before after_static runs: the cookie it writes
    # back is already on the response.
    $response->headers->cache_control(
        $self->cache_control(
            development => $controller->app->mode eq 'development',
            name        => $name,
            served      => scalar _served_path( $controller, $name ),
            sets_cookie => defined $response->headers->set_cookie,
            version     => $url->query->param($VERSION_PARAMETER),
        )
    );

    return;
}

sub _is_current ( $self, %input ) {
    my $file    = $self->files->{ _relative( $input{name} // q{} ) };
    my $version = $input{version};
    return if !$file || !defined $version;
    return if $version ne $file->{digest};

    return _unchanged( $file, $input{served} );
}

# The file the static file server answers this name from: not always the one
# digested under it, if a file has since been put in an earlier root. It is
# asked again rather than read off the response, because a 304 carries no
# file, and a 304 with a year's lifetime keeps the browser's copy as long as
# a 200 would.
sub _served_path ( $controller, $name ) {
    my $asset = $controller->app->static->file($name);

    return $asset && $asset->is_file ? $asset->path : undef;
}

# The roots are searched in order and the first file found under a name is
# the one served, as Mojolicious::Static does. The stat is taken before the
# bytes are read: a file replaced in between then fails _unchanged and is
# never called immutable, rather than the other way round.
sub _scan_roots ($self) {
    my %files;
    for my $root ( map { path($_) } @{ $self->roots } ) {
        next if !-d $root;

        for my $file ( $root->list_tree->each ) {
            my $relative = join q{/}, @{ $file->to_rel($root)->to_array };
            next if exists $files{$relative};

            my $stat = $file->stat;
            next if !$stat;
            $files{$relative} = {
                device => $stat->dev,
                digest => _digest($file),
                inode  => $stat->ino,
                mtime  => $stat->mtime,
                path   => $file->to_string,
                size   => $stat->size,
            };
        }
    }

    return \%files;
}

sub _digest ($file) {
    my $sha = Digest::SHA->new($SHA_ALGORITHM);
    $sha->addfile( $file->to_string, 'b' );

    return substr $sha->hexdigest, 0, $DIGEST_LENGTH;
}

# The digest was taken at startup; a file replaced on disk since then (an
# upgrade copied in before the restart) is served with the new bytes, which
# that digest does not name. The file served must be the very one digested:
# the same inode, which a file renamed over it or one added to an earlier
# root is not, whatever its size and time; and, for a file rewritten in
# place, the same size and modification time.
sub _unchanged ( $file, $served ) {
    my $stat = path( $served // $file->{path} )->stat;

    return
         $stat
      && $stat->dev == $file->{device}
      && $stat->ino == $file->{inode}
      && $stat->size == $file->{size}
      && $stat->mtime == $file->{mtime};
}

sub _relative ($name) {
    my $relative = $name // q{};
    $relative =~ s{\A /+}{}msx;

    return $relative;
}

1;

__END__

=head1 NAME

GPForum::Web::AssetManifest - Name each static file by the digest of its bytes, and say how long a browser may keep it.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $manifest = GPForum::Web::AssetManifest->new(
        roots => [ @{ $app->static->paths } ] );
    $manifest->files;    # digest every file now, at startup

    # In a template, through the ui_asset_url helper:
    #   <link rel="stylesheet" href="<%= ui_asset_url('gpforum-ssr.css') %>">
    # renders /gpforum-ssr.css?v=3f2a9c0d41b7
    my $url = $manifest->asset_url( $c, 'gpforum-ssr.css' );

    # On every static response (the after_static hook):
    $manifest->apply($c);

=head1 DESCRIPTION

Quality program 7.7. A page names each stylesheet, script and image with the
first twelve hex digits of the SHA-256 of the file's bytes as a C<v> query
parameter. A changed file gets a new URL, so the old one can be cached
for a year and never revalidated, and a deploy is still seen on the next page
load.

The digests are taken once, when the manifest's C<files> is first read: the
application reads it while it starts, so Hypnotoad's workers share the table
and no request reads a file to name it.

L</apply> sets C<Cache-Control> on a response from the static file server
that carries the file or confirms the browser's copy (a 200, 206 or 304):
C<public, max-age=31536000, immutable> when the request's C<v> is the
current digest of the file it names, C<public, max-age=3600> otherwise, and
C<no-cache> in the C<development> mode. A request with an old C<v> (a page
rendered before a deploy) is still answered with the current file, under the
short lifetime, so a browser does not keep the new bytes for a year under
a URL that names the old ones. A response that writes a cookie back -- the
session cookie, which every visitor who has seen a form carries -- says
C<private> instead of C<public>, with the same lifetime: the browser keeps
it, and no shared cache stores one visitor's cookie for the next.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor. C<roots> is the list of directories the static file
server searches, in its order; the application passes
C<< $app->static->paths >>.

=head2 files

The table, built from C<roots> on first read and kept: for each file, under
its path relative to its root (C<gpforum-ssr.css>, C<icons/x.svg>), its
C<digest>, the C<path> it was read from and the C<device>, C<inode>, C<size>
and C<mtime> it had then. The first root holding a name wins, as with the
static file server.
Hidden files are skipped.

=head2 digest

Takes a name, with or without a leading slash. Returns the file's digest,
twelve lowercase hex digits, or undef for a name the table does not hold.

=head2 asset_url

Takes a controller and a name. Returns the L<Mojo::URL> the controller's
C<url_for> gives for C</name>, with C<v=digest> as its query.

=head2 cache_control

Takes a hash: C<name> (the file's name, as for L</digest>), C<version> (the
request's C<v>, or undef), C<served> (the path of the file the response is
served from, or undef to look at the one digested), C<sets_cookie> (true when
the response carries C<Set-Cookie>) and C<development> (true in the
development mode). Returns the C<Cache-Control> value described above. The
immutable lifetime is given only when the file served is the one digested --
the same device and inode -- and its size and modification time are still
those it had then.

=head2 apply

Takes the controller of a response the static file server has just produced
and, for a 200, 206 or 304, sets its C<Cache-Control> from
L</cache_control>: the request path canonicalized as the static file server
canonicalizes it, the file the static file server answers that path from,
and whether the response already carries C<Set-Cookie>, as it does once the
session has been stored. A 416, which refuses the range asked for and
carries none of the file, is left without one. Returns nothing.

=head1 DIAGNOSTICS

L</asset_url> throws a L<GPForum::X::Argument> with C<unknown asset: NAME> for a name the table does
not hold, so a misspelt asset fails the render. Building the table croaks when
L<Digest::SHA> cannot read a file.

=head1 CONFIGURATION AND ENVIRONMENT

None directly. L<GPForum::Bootstrap::UI> builds one over the static paths
L<GPForum::Bootstrap::Core> sets (C<assets/css>, then C<assets/img>),
registers the C<ui_asset_url> helper and calls L</apply> from an
C<after_static> hook. The application mode comes from C<GPFORUM_ENV>.

=head1 DEPENDENCIES

L<Const::Fast>, L<Digest::SHA>, L<GPForum::X::Argument>, L<Mojo::Base>,
L<Mojo::File>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A file added under a root after startup is served, but has no digest: it
gets the short lifetime, and L</asset_url> refuses it until the next
restart. A file rewritten in place (the same inode) with the same size within
the same second as the original is not seen to have changed; a file renamed
over it is.

A reverse proxy that serves these files itself cannot compare C<v> with the
digest. The shipped nginx and Caddy configurations call any C<v> immutable.
On a single host that shows only after a rollback: a page cached from before
the deploy names the old digest, browsers keep the new bytes under it, and
the rolled-back pages name it again. Behind a load balancer whose hosts are
upgraded one at a time it shows at once: a page from an upgraded host names
the new digest, a host not yet upgraded answers it from disk with the old
bytes, and browsers keep those for a year. There, let the proxy pass these
URLs to the application, which compares the digest.

The header's mark (F<templates/components/site_header.html.ep>) is still
linked without a digest, so it gets the short lifetime.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
