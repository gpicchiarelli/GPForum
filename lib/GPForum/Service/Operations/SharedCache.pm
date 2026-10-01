# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::SharedCache;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use Crypt::URandom ();
use English        qw(-no_match_vars);
use JSON::MaybeXS;
use List::Util qw(uniq);
use Mojo::Base -base, -signatures;

use GPForum::Service::Clock;

our $VERSION = '0.001';

const my $DEFAULT_NAMESPACE       => 'gpforum';
const my $DEFAULT_TTL_SECONDS     => 60;
const my $DEFAULT_CONNECT_TIMEOUT => 1;
const my $DEFAULT_REQUEST_TIMEOUT => 1;
const my $NANOSECONDS_PER_SECOND  => 1_000_000_000;
const my $TCP_ENDPOINT_PATTERN =>
  qr{\A (?:tcp://)? ([[:alnum:]._-]+) : ([[:digit:]]+) \z}msx;
const my $UNIX_ENDPOINT_PATTERN => qr{\A unix:// (\S+) \z}msx;
const my $INVALID_ENDPOINT_MESSAGE =>
  'glifistore_url must be tcp://host:port, unix://path, or host:port';

# After a failure every call skips L2 for this long. Handlers are synchronous
# and a hung GlifiStore costs each call its connect and request timeouts, so
# without a pause every anonymous page miss, and every tag the outbox
# invalidates, stalled its process for seconds. Fixed rather than growing,
# like the realtime listener's reconnect delay: one number to reason about.
const my $RETRY_AFTER_SECONDS => 15;

# A tag's token outlives any entry written under it. When it lapses, the
# entries under it miss once and the next write mints a new one.
const my $TAG_TOKEN_TTL_SECONDS => 86_400;
const my $TAG_TOKEN_BYTES       => 16;
const my $TAG_TOKEN_PATTERN     => qr{\A [[:xdigit:]]{32} \z}msx;

# What a failed call does to the connection, by GlifiStore error category
# (client-semantics-v1, section 3). A dead or confused connection is dropped
# and rebuilt after the pause. An overloaded server keeps its connection:
# reconnecting every process to it only adds load. A request refused on its
# merits (too large, not permitted) says nothing about the connection and
# pauses nothing. An unknown category is dropped.
const my %FAILURE_ACTION => (
    indeterminate     => 'drop',
    internal          => 'drop',
    protocol          => 'drop',
    transport         => 'drop',
    unavailable       => 'drop',
    overloaded        => 'pause',
    invalid_argument  => 'keep',
    permission_denied => 'keep',
);

has client    => undef;
has connector => undef;
has endpoint  => undef;
has clock     => sub { return GPForum::Service::Clock->new; };
has codec => sub { return JSON::MaybeXS->new( canonical => 1, utf8 => 1 ); };
has namespace => sub { return $DEFAULT_NAMESPACE; };

# While set and not yet reached, every call skips L2 ($RETRY_AFTER_SECONDS).
has retry_after_epoch => undef;
has ttl_seconds       => sub { return $DEFAULT_TTL_SECONDS; };
has stats             => sub {
    return {
        failures      => 0,
        hits          => 0,
        invalidations => 0,
        misses        => 0,
        skipped       => 0,
        writes        => 0,
    };
};

sub connect_required ( $class, $options ) {
    $options ||= {};
    if ( !_has_text( $options->{url} ) ) {
        croak 'glifistore_url is required';
    }

    my $endpoint = $class->parse_endpoint( $options->{url} );
    return $class->_instance_for_endpoint( $endpoint, $options );
}

sub try_connect ( $class, $options ) {
    my $undefined;

    $options ||= {};
    if ( !_has_text( $options->{url} ) ) {
        return $undefined;
    }

    my $cache = eval { return $class->connect_required($options); };
    if ( !$cache ) {
        return $undefined;
    }

    return $cache;
}

sub parse_endpoint ( $, $url ) {
    my $unix = _unix_endpoint($url);
    if ($unix) {
        return $unix;
    }

    my $tcp = _tcp_endpoint($url);
    if ($tcp) {
        return $tcp;
    }

    croak $INVALID_ENDPOINT_MESSAGE;
}

sub lookup ( $self, $key ) {
    $self->_validate_key($key);
    my $payload = $self->_read_payload($key);
    if ( !$payload ) {
        $self->stats->{misses} += 1;
        my $undefined;
        return $undefined;
    }

    $self->stats->{hits} += 1;
    return $payload;
}

sub get ( $self, $key ) {
    my $payload = $self->lookup($key);
    if ( !$payload ) {
        my $undefined;
        return $undefined;
    }

    return $payload->{value};
}

sub put ( $self, $key, $value, $options = undef ) {
    $options ||= {};
    $self->_validate_key($key);
    if ( !$self->_store_value( $key, $value, $options ) ) {
        my $undefined;
        return $undefined;
    }

    $self->stats->{writes} += 1;
    return $value;
}

sub get_or_set ( $self, $key, $producer, $options = undef ) {
    my $cached = $self->get($key);
    if ( defined $cached ) {
        return $cached;
    }

    my %put = %{ $options || {} };
    $put{ticket} = $self->ticket( $put{tags}, { mint => 1 } );
    my $generated = $producer->();
    $self->put( $key, $generated, \%put );
    return $generated;
}

# The tokens of the tags a value is about to be computed under, read before
# the computation reads the database. Passed to put as its ticket option, the
# value is stored under these tokens rather than those current at the put, so
# a purge that lands while the value is computed retires it. Read at the put,
# a page with a post hidden meanwhile was stored under the token minted after
# the purge, and stayed current in L2 until its TTL.
#
# With mint, a tag with no token gets one now, which is safe since nothing has
# been read yet; for a caller that always stores (get_or_set). Without, the
# tag is recorded as having none and the put mints it but does not store the
# value: a purge in between had nothing to erase, so nothing tells whether
# the value predates it. That is for a caller that may store nothing, such as
# a page that turns out not to exist: minting for it would let any thread id
# in a URL write a key that lives a day.
sub ticket ( $self, $tags, $options = undef ) {
    my $mint = $options && $options->{mint};
    my %tokens;
    for my $tag ( _tag_list($tags) ) {
        my $token =
            $mint
          ? $self->_tag_token($tag)
          : $self->_current_tag_token($tag);
        if ( !defined $token ) {
            return { failed => 1 };
        }
        $tokens{$tag} = length $token ? $token : undef;
    }

    return { tokens => \%tokens };
}

sub invalidate ( $self, $key ) {
    $self->_validate_key($key);
    my $removed = $self->_erase_store_key( $self->_entry_store_key($key) );
    $self->stats->{invalidations} += $removed;
    return $removed;
}

# One ERASE retires every entry written under the tag, since each carries the
# token this removes. The tag used to keep a list of its entries, rewritten by
# read-modify-write on every put: two concurrent puts lost one of the two, a
# purge then missed the lost key, and a hidden post came back from L2.
# Returns 1 when a token was erased, 0 when the tag had none or L2 failed.
sub invalidate_tag ( $self, $tag ) {
    if ( !_has_text($tag) ) {
        return 0;
    }

    my $removed = $self->_erase_store_key( $self->_tag_store_key($tag) );
    $self->stats->{invalidations} += $removed;
    return $removed;
}

sub purge_expired {
    return 0;
}

sub clear {
    return 0;
}

sub snapshot ($self) {
    return {
        namespace         => $self->namespace,
        layer             => 'shared',
        retry_after_epoch => $self->retry_after_epoch,
        ttl_seconds       => $self->ttl_seconds,
        stats             => { %{ $self->stats } },
    };
}

sub ping ($self) {
    my $client = $self->_active_client;
    if ( !$client ) {
        return 0;
    }

    my $ok = eval {
        $client->ping(q{});
        return 1;
    };
    if ( !$ok ) {
        $self->_record_failed_call( _error_category($EVAL_ERROR) );
        return 0;
    }

    return 1;
}

sub _instance_for_endpoint ( $class, $endpoint, $options ) {
    my $connector = $options->{connector} || \&_default_connector;
    my $client    = eval { return $connector->($endpoint); };
    return $class->_new_connected(
        $client,
        {
            clock       => $options->{clock},
            connector   => $connector,
            endpoint    => $endpoint,
            namespace   => $options->{namespace},
            ttl_seconds => $options->{ttl_seconds},
        }
    );
}

sub _new_connected ( $class, $client, $options ) {
    my %args = (
        client    => $client,
        connector => $options->{connector},
        endpoint  => $options->{endpoint},
    );
    if ( $options->{clock} ) {
        $args{clock} = $options->{clock};
    }
    if ( _has_text( $options->{namespace} ) ) {
        $args{namespace} = $options->{namespace};
    }
    if ( $options->{ttl_seconds} ) {
        $args{ttl_seconds} = $options->{ttl_seconds};
    }

    return $class->new(%args);
}

sub _default_connector ($endpoint) {
    require GlifiStore::Client;
    return GlifiStore::Client->connect( %{$endpoint} );
}

sub _unix_endpoint ($url) {
    if ( $url =~ $UNIX_ENDPOINT_PATTERN ) {
        return {
            unix_socket_path => $1,
            connect_timeout  => $DEFAULT_CONNECT_TIMEOUT,
            request_timeout  => $DEFAULT_REQUEST_TIMEOUT,
        };
    }

    my $undefined;
    return $undefined;
}

sub _tcp_endpoint ($url) {
    if ( $url =~ $TCP_ENDPOINT_PATTERN ) {
        return {
            host            => $1,
            port            => int $2,
            connect_timeout => $DEFAULT_CONNECT_TIMEOUT,
            request_timeout => $DEFAULT_REQUEST_TIMEOUT,
        };
    }

    my $undefined;
    return $undefined;
}

sub _read_payload ( $self, $key ) {
    my $undefined;

    my $store_key = $self->_entry_store_key($key);
    my ( $status, $raw ) = $self->_client_get($store_key);
    if ( $status ne 'found' ) {
        return $undefined;
    }

    my $payload = $self->_decode_payload($raw);
    if ( $self->_payload_expired($payload) ) {
        $self->_erase_store_key($store_key);
        return $undefined;
    }
    if ( !$self->_tokens_current($payload) ) {
        return $undefined;
    }

    return $payload;
}

# An entry is current while each of its tags still holds the token it was
# written under. An entry written before tokens existed carries none and
# misses, so no entry the old member list tracked outlives the deploy.
sub _tokens_current ( $self, $payload ) {
    my $tokens = $payload->{tokens};
    my $tags   = $payload->{tags};
    if ( ref $tokens ne 'HASH' || ref $tags ne 'ARRAY' ) {
        return 0;
    }

    for my $tag ( @{$tags} ) {
        my $written = $tokens->{$tag};
        return 0 if !defined $written;

        my ( $status, $current ) =
          $self->_client_get( $self->_tag_store_key($tag) );
        return 0 if $status ne 'found' || ( $current // q{} ) ne $written;
    }

    return 1;
}

sub _store_value ( $self, $key, $value, $options ) {
    my @tags = _tag_list( $options->{tags} );
    my $tokens =
        $options->{ticket}
      ? $self->_ticketed_tokens( $options->{ticket}, \@tags )
      : $self->_tag_tokens( \@tags );
    if ( !$tokens ) {
        return 0;
    }

    my $ttl   = $options->{ttl_seconds} || $self->ttl_seconds;
    my $bytes = $self->_encode_payload(
        {
            expires_at_epoch => $self->clock->now_epoch + $ttl,
            tags             => \@tags,
            tokens           => $tokens,
            value            => $value,
        }
    );
    if ( !defined $bytes ) {
        return 0;
    }

    return $self->_client_put(
        $self->_entry_store_key($key),
        $bytes, $self->_expire_at_ns($ttl),
    );
}

# Every tag's token, or nothing when one cannot be read or written: an entry
# stored without its tokens could never be invalidated by tag.
sub _tag_tokens ( $self, $tags ) {
    my %tokens;
    for my $tag ( @{$tags} ) {
        my $token = $self->_tag_token($tag);
        if ( !defined $token ) {
            my $undefined;
            return $undefined;
        }
        $tokens{$tag} = $token;
    }

    return \%tokens;
}

# The tokens a ticket holds for the tags, or nothing when the ticket could not
# read them or lacks one. A tag it found without a token gets one now, for the
# next value, but this value is not stored (see ticket).
sub _ticketed_tokens ( $self, $ticket, $tags ) {
    my $undefined;

    my $held = $ticket->{tokens};
    if ( $ticket->{failed} || ref $held ne 'HASH' ) {
        return $undefined;
    }

    my %tokens;
    my $complete = 1;
    for my $tag ( @{$tags} ) {
        if ( !defined $held->{$tag} ) {
            $self->_tag_token($tag);
            $complete = 0;
            next;
        }
        $tokens{$tag} = $held->{$tag};
    }

    return $complete ? \%tokens : $undefined;
}

# The tag's token, minted when the tag has none. An existing token is never
# written again, not even to extend it: a put that read it just before an
# invalidation erased it would put it back, and every entry the invalidation
# retired would be current again. Two puts that both find none each mint one;
# the later wins and the other's entry misses, which is only a wasted write.
# A value that is not a token (the member list this key held before tokens)
# is replaced.
sub _tag_token ( $self, $tag ) {
    my $undefined;

    my $token = $self->_current_tag_token($tag);
    if ( !defined $token || length $token ) {
        return $token;
    }

    my $minted = unpack 'H*', Crypt::URandom::urandom($TAG_TOKEN_BYTES);
    if (
        !$self->_client_put(
            $self->_tag_store_key($tag), $minted,
            $self->_expire_at_ns($TAG_TOKEN_TTL_SECONDS),
        )
      )
    {
        return $undefined;
    }

    return $minted;
}

# The tag's token; an empty string when it has none (or holds what is not a
# token); nothing when L2 could not be read.
sub _current_tag_token ( $self, $tag ) {
    my ( $status, $value ) = $self->_client_get( $self->_tag_store_key($tag) );
    if ( $status eq 'failed' ) {
        my $undefined;
        return $undefined;
    }

    return _is_token( $status, $value ) ? $value : q{};
}

# ( 'found', $value ), ( 'absent' ), or ( 'failed' ) when L2 is paused or the
# call failed. Minting a tag token depends on telling the last two apart.
sub _client_get ( $self, $store_key ) {
    my $client = $self->_active_client;
    if ( !$client ) {
        return ('failed');
    }

    my $value;
    my $ok = eval {
        $value = $client->get($store_key);
        return 1;
    };
    if ($ok) {
        return ( 'found', $value );
    }

    my $category = _error_category($EVAL_ERROR);
    if ( $category eq 'not_found' ) {
        return ('absent');
    }

    $self->_record_failed_call($category);
    return ('failed');
}

sub _client_put ( $self, $store_key, $bytes, $expire_at_ns ) {
    my $client = $self->_active_client;
    if ( !$client ) {
        return 0;
    }

    my $result = eval {
        return $client->put( $store_key, $bytes,
            expire_at_ns => $expire_at_ns, );
    };
    my $category = _outcome_category($result);
    if ( $category eq 'committed' ) {
        return 1;
    }

    $self->_record_failed_call($category);
    return 0;
}

# 1 when the key was erased, 0 when it was absent or L2 failed.
sub _erase_store_key ( $self, $store_key ) {
    my $client = $self->_active_client;
    if ( !$client ) {
        return 0;
    }

    my $result   = eval { return $client->erase($store_key); };
    my $category = _outcome_category($result);
    if ( $category eq 'committed' ) {
        return 1;
    }

    # GlifiStore rejects the ERASE of an absent key with not_found: the key is
    # gone, which is what was asked. Read as a failure it dropped a healthy
    # connection on almost every post, since most of the tags the outbox
    # invalidates were never cached.
    if ( $category eq 'not_found' ) {
        return 0;
    }

    $self->_record_failed_call($category);
    return 0;
}

# The one gate every call passes, invalidations and ping included. A skipped
# invalidation leaves an L2 entry until its TTL, the bound ADR 0067 already
# relies on; letting invalidations through would park the outbox for a second
# per tag while GlifiStore hangs, and notifications, search and realtime wait
# behind it. The constructor never pauses: a process that starts before
# GlifiStore tries it on the first call.
sub _active_client ($self) {
    if ( $self->_paused ) {
        $self->stats->{skipped} += 1;
        my $undefined;
        return $undefined;
    }
    if ( $self->client ) {
        return $self->client;
    }

    return $self->_reconnect;
}

sub _paused ($self) {
    my $retry_after = $self->retry_after_epoch;
    if ( !defined $retry_after ) {
        return 0;
    }
    if ( $self->clock->now_epoch < $retry_after ) {
        return 1;
    }

    $self->retry_after_epoch(undef);
    return 0;
}

sub _reconnect ($self) {
    my $client;
    if ( $self->connector && $self->endpoint ) {
        $client = eval { return $self->connector->( $self->endpoint ); };
    }
    if ( !$client ) {
        $self->_record_failure;
        $self->_pause;
        my $undefined;
        return $undefined;
    }

    $self->client($client);
    return $client;
}

sub _record_failed_call ( $self, $category ) {
    my $action =
      exists $FAILURE_ACTION{$category} ? $FAILURE_ACTION{$category} : 'drop';

    $self->_record_failure;
    if ( $action eq 'drop' ) {
        $self->client(undef);
    }
    if ( $action ne 'keep' ) {
        $self->_pause;
    }

    return;
}

sub _pause ($self) {
    $self->retry_after_epoch( $self->clock->now_epoch + $RETRY_AFTER_SECONDS );
    return;
}

sub _record_failure ($self) {
    $self->stats->{failures} += 1;
    return;
}

sub _decode_payload ( $self, $raw ) {
    my $payload = eval { return $self->codec->decode($raw); };
    if ( ref $payload ne 'HASH' ) {
        $self->_record_failure;
        my $undefined;
        return $undefined;
    }

    return $payload;
}

sub _encode_payload ( $self, $payload ) {
    my $bytes = eval { return $self->codec->encode($payload); };
    if ( !defined $bytes ) {
        $self->_record_failure;
        my $undefined;
        return $undefined;
    }

    return $bytes;
}

sub _payload_expired ( $self, $payload ) {
    if ( !$payload ) {
        return 1;
    }

    my $expires = $payload->{expires_at_epoch};
    if ( !defined $expires ) {
        return 0;
    }

    return $self->clock->now_epoch >= $expires ? 1 : 0;
}

sub _expire_at_ns ( $self, $ttl ) {
    return ( $self->clock->now_epoch + $ttl ) * $NANOSECONDS_PER_SECOND;
}

sub _entry_store_key ( $self, $key ) {
    return join q{:}, $self->namespace, 'entry', $key;
}

# The key the member list used to live under, kept so that an invalidation
# from a process still running the old code erases the token as well.
sub _tag_store_key ( $self, $tag ) {
    return join q{:}, $self->namespace, 'tag', $tag;
}

sub _validate_key ( $, $key ) {
    if ( !_has_text($key) ) {
        croak 'cache key is required';
    }

    return;
}

sub _has_text ($value) {
    return defined $value && length $value ? 1 : 0;
}

sub _tag_list ($tags) {
    return uniq grep { _has_text($_) } @{ $tags || [] };
}

# A value read from a tag key that is a token, not the member list the key
# held before tokens, nor nothing.
sub _is_token ( $status, $value ) {
    return $status eq 'found' && ( $value // q{} ) =~ $TAG_TOKEN_PATTERN
      ? 1
      : 0;
}

# 'committed', or the category a PUT or ERASE failed with. An indeterminate
# outcome may or may not have applied and leaves the connection in doubt. A
# rejection without an error object is what a client that could not reach its
# server answers.
sub _outcome_category ($result) {
    if ( ref $result ne 'HASH' ) {
        return 'transport';
    }

    my $outcome = $result->{outcome} // q{};
    return 'committed'     if $outcome eq 'committed';
    return 'indeterminate' if $outcome eq 'indeterminate';
    return 'unavailable'   if !$result->{error};

    return _error_category( $result->{error} );
}

# The GlifiStore category of an error. A GlifiStore::Error names its own;
# anything else is a transport failure, unless its text says not found.
sub _error_category ($error) {
    if ( ref $error && eval { return $error->can('category'); } ) {
        return $error->category // 'transport';
    }

    my $message = "$error";
    return $message =~ /not[_ ]found/imsx ? 'not_found' : 'transport';
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::SharedCache - The GlifiStore L2 cache: fail-open, tag invalidation by token.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $cache = GPForum::Service::Operations::SharedCache->connect_required(
        {
            namespace   => 'gpforum',
            ttl_seconds => 30,
            url         => 'tcp://127.0.0.1:7379',
        }
    );
    $cache->put( 'category:42', $category, { tags => ['categories'] } );
    my $value = $cache->get('category:42');

    my $ticket = $cache->ticket( ['forum:public-html'] );
    my $page   = render_page();
    $cache->put( 'page:/', $page,
        { tags => ['forum:public-html'], ticket => $ticket } );

    $cache->invalidate_tag('categories');

=head1 DESCRIPTION

The shared cache layer every web and worker process reaches: L2 under
L<GPForum::Service::Operations::TieredCache>, built by
L<GPForum::Service::Operations::CacheFactory> whenever C<glifistore_url> is
set (ADR 0048). It stores JSON in a GlifiStore server through
C<GlifiStore::Client>. Like every cache here it is disposable: PostgreSQL
stays the source of truth, and nothing read from GlifiStore is
authoritative.

Each entry is stored under C<E<lt>namespaceE<gt>:entry:E<lt>keyE<gt>> as a
JSON object holding the value, its tags, the token of each tag it was
written under, and its expiry (C<expires_at_epoch>); GlifiStore is given the
same expiry. A value must therefore encode as JSON: a blessed object, such
as a L<DBIx::Class> row, does not, and is not stored.

B<Tags.> Each tag has a token, 32 random hexadecimal characters, under
C<E<lt>namespaceE<gt>:tag:E<lt>tagE<gt>>, minted by the first write, or
minting L</ticket>, that finds none, and kept for a day. An entry is
current while each of its tags still holds the token it was written under,
so invalidating a tag is one ERASE of its token, and every entry written
under it misses from then on.
An existing token is never written again, not even to extend it: a write
that read it just before an invalidation erased it would put it back, and
the entries the invalidation retired would be current again. The tag used
to keep a list of its entries, rewritten by every put; two concurrent puts
lost one key, a purge then missed it, and a hidden post came back from L2.
An entry written before tokens existed carries none and misses, and a tag
key that still holds the old list is replaced by a token on the next write.

B<Tickets.> A value computed from the database should be stored under the
tokens its tags had before the computation read anything (L</ticket>), not
those current when it is stored: read at the put, a page with a post hidden
meanwhile was stored under the token minted after the purge, and stayed
current in L2 until its TTL.

B<Failures.> Every call is fail-open: a GlifiStore error never reaches the
caller, it reads as a miss, an unstored value or nothing erased. A failed
call is counted in C<stats.failures> and, by GlifiStore error category
(client-semantics-v1, section 3), drops the connection and pauses L2
(C<transport>, C<protocol>, C<internal>, C<indeterminate>, C<unavailable>,
and any unknown category), pauses it but keeps the connection (C<overloaded>:
reconnecting every process only adds load), or does neither
(C<invalid_argument>, C<permission_denied>: refused on their merits).
C<not_found> is not a failure: a GET of an absent key is a miss, and an
ERASE of an absent key has done what was asked. While paused, for fifteen
seconds, every call skips GlifiStore and counts in C<stats.skipped>:
handlers are synchronous, and a hung server would otherwise cost every
call its connect and request timeouts. Invalidations and L</ping> are skipped
too; an invalidation skipped then leaves the entry current until its TTL, the
bound ADR 0067 relies on. After the pause a dropped connection is rebuilt
through C<connector> and C<endpoint>; a failed reconnect pauses again.

=head1 SUBROUTINES/METHODS

=head2 new

Mojo::Base constructor; L</connect_required> is the usual way in. Accepts
C<client> (a connected GlifiStore client, or none to connect through
C<connector> on the first call), C<connector> (a code reference that takes
the endpoint hash and returns a client) and C<endpoint> (a hash from
L</parse_endpoint>); without both of the last two, a lost client is never
replaced. Optional C<clock>
(L<GPForum::Service::Clock>, read through C<now_epoch>), C<codec>
(L<JSON::MaybeXS>, canonical, UTF-8), C<namespace> (C<gpforum>),
C<ttl_seconds> (60), C<retry_after_epoch> (the end of the current pause, or
C<undef>) and C<stats>.

=head2 connect_required

Class method. Takes a hash reference with C<url> (required) and optional
C<connector>, C<clock>, C<namespace> (used when not empty) and
C<ttl_seconds> (used when true). Parses the URL with L</parse_endpoint>,
tries to connect once, and returns an instance. The default connector loads
C<GlifiStore::Client> and calls its C<connect> with the endpoint's fields.
A failed connect is not an error: the instance has no client, is not
paused, and tries again on its first call, so a process that starts before
GlifiStore still starts. Croaks when the URL is missing or malformed.

=head2 try_connect

Class method. Takes the options of L</connect_required>. Returns C<undef>
when C<url> is undefined or empty, or when L</connect_required> dies (a
malformed URL); otherwise the instance L</connect_required> returns, which
is also the case when the server could not be reached. Never croaks. The
application builds its cache with L</connect_required> instead (ADR 0048).

=head2 parse_endpoint

Takes a URL (callable on the class or an instance). Returns a hash
reference for C<GlifiStore::Client-E<gt>connect>: for C<unix://path>,
C<unix_socket_path>; for C<tcp://host:port> or C<host:port>, C<host> and
C<port>. Both carry C<connect_timeout> and C<request_timeout>, one second
each. Croaks for anything else.

=head2 lookup

Takes a key. Returns the stored entry, a hash reference with C<value>,
C<tags>, C<tokens> and C<expires_at_epoch>, when it is present, decodes as
a JSON object, has not expired, and each of its tags still holds the token
it was written under, counted as a hit. Otherwise returns C<undef>, counted
as a miss; an entry that has expired or does not decode is erased. One GET
reads the entry and one more reads each of its tags. This is the read
L<GPForum::Service::Operations::TieredCache> fills L1 from.

=head2 get

Takes a key. Returns the entry's value as L</lookup> finds it, or C<undef>.

=head2 put

Takes a key, a value and an optional hash reference with C<tags> (an array
reference; empty and repeated tags are dropped), C<ttl_seconds> (the
instance's when absent or zero) and C<ticket> (from L</ticket>). Without a
ticket, the entry is written under each tag's current token, minted when the
tag has none. With one, it is written under the ticket's tokens, and not
written at all when the ticket failed or holds no token for one of the
tags; such a tag gets a token now, for the next value. Returns the value
when it was stored (counted in C<stats.writes>), or C<undef> when it was
not: L2 paused or failing, a tag token that could not be read or minted, a
refused ticket, or a value that does not encode as JSON.

=head2 get_or_set

Takes a key, a code reference and the options of L</put>. Returns the
cached value on a hit. On a miss it takes a minting L</ticket> for the tags
before calling the code reference with no arguments, then stores the result
under that ticket (replacing any C<ticket> in the options) and returns it,
whether or not it was stored. Errors from the code reference propagate, and
nothing is stored.

=head2 ticket

Takes an array reference of tags and an optional hash reference with
C<mint>. Reads each distinct non-empty tag's current token before the
caller computes a value, and returns C<< { tokens => { $tag => $token } } >>
to pass to L</put> as C<ticket>. With C<mint>, a tag with no token gets one
now, which is safe since nothing has been read yet: for a caller that
always stores (L</get_or_set>). Without it, a tag with no token is recorded
as C<undef>, and the put mints one but does not store the value, since a
purge in between had nothing to erase and nothing tells whether the value
predates it. That is for a caller that may store nothing, such as a page
that turns out not to exist: minting for it would let any thread id in a
URL write a key that lives a day. Returns C<< { failed => 1 } >> when a
token could not be read or minted (L2 paused or failing); L</put> stores
nothing under that ticket.

=head2 invalidate

Takes a key and erases its entry. Returns 1 when an entry was erased, 0
when there was none or L2 was paused or failed; the result is added to
C<stats.invalidations>.

=head2 invalidate_tag

Takes a tag and erases its token, which retires every entry written under
it: they miss from then on and GlifiStore drops them at their expiry.
Returns 1 when the tag's key was erased, 0 for an undefined or empty tag,
a tag whose key is absent, or L2 paused or failed; the result is added to
C<stats.invalidations>.

=head2 purge_expired

Does nothing and returns 0: GlifiStore is given each entry's expiry and
drops it itself. Present because
L<GPForum::Service::Operations::TieredCache> calls it on both layers.

=head2 clear

Does nothing and returns 0: the shared store is not emptied from a process.
Present because L<GPForum::Service::Operations::TieredCache> calls it on
both layers.

=head2 snapshot

Returns a hash reference with C<namespace>, C<layer> (C<shared>),
C<retry_after_epoch> (C<undef> unless paused), C<ttl_seconds> and a copy of
C<stats> (C<hits>, C<misses>, C<writes>, C<invalidations>, C<failures>,
C<skipped>). C</metrics> shows it under C<local_caches[0].l2>.

=head2 ping

Returns 1 when GlifiStore answers a PING, 0 when L2 is paused, no client
could be connected, or the PING failed (counted and handled as any failed
call). The readiness check reaches it through
L<GPForum::Service::Operations::TieredCache/ping>.

=head1 DIAGNOSTICS

L</connect_required> croaks with C<glifistore_url is required> when the URL
is undefined or empty, and L</connect_required> and L</parse_endpoint>
croak with
C<glifistore_url must be tcp://host:port, unix://path, or host:port> for a
malformed one. L</lookup>, L</get>, L</put>, L</get_or_set> and
L</invalidate> croak with C<cache key is required> for an undefined or
empty key. GlifiStore errors never propagate: they are counted in
C<stats.failures> and handled as L</DESCRIPTION> says, and C<stats.skipped>
counts the calls a pause skipped. C<stats.failures> also counts a reconnect
that fails (which pauses L2), a value that does not encode as JSON and a
stored entry that does not decode (neither of which touches the connection).

=head1 CONFIGURATION AND ENVIRONMENT

None read directly. L<GPForum::Service::Operations::CacheFactory> passes the
configuration's C<glifistore_url> (C<GPFORUM_GLIFISTORE_URL>) as C<url>,
C<gpforum> as C<namespace>, and C<category_cache_ttl_seconds> as
C<ttl_seconds>. C<GlifiStore::Client> is not a C<cpanfile> pin: the
operator installs it on the Perl that runs the application (see
F<docs/DEPLOYMENT.md>).

=head1 DEPENDENCIES

L<Mojo::Base>, L<Const::Fast>, L<Crypt::URandom>, L<JSON::MaybeXS>,
L<List::Util>, L<GPForum::Service::Clock>, and C<GlifiStore::Client>, loaded
at run time by the default connector.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

A host is letters, digits, dots, underscores and hyphens, so an IPv6
literal address is not accepted. The connect and request timeouts are fixed
at one second, and the pause after a failure at fifteen seconds. A hit costs
one GET for the entry and one per tag. A tag's token lapses after a day;
the entries under it then miss once and the next write mints a new one. Two
writes that both find a tag without a token each mint one: the later wins
and the other's entry misses, which is only a wasted write. The counters in
C<stats> are per process.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
