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

    my $generated = $producer->();
    $self->put( $key, $generated, $options );
    return $generated;
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
    my @tags   = uniq grep { _has_text($_) } @{ $options->{tags} || [] };
    my $tokens = $self->_tag_tokens( \@tags );
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

# The tag's token, minted when the tag has none. An existing token is never
# written again, not even to extend it: a put that read it just before an
# invalidation erased it would put it back, and every entry the invalidation
# retired would be current again. Two puts that both find none each mint one;
# the later wins and the other's entry misses, which is only a wasted write.
# A value that is not a token (the member list this key held before tokens)
# is replaced.
sub _tag_token ( $self, $tag ) {
    my $undefined;

    my $store_key = $self->_tag_store_key($tag);
    my ( $status, $token ) = $self->_client_get($store_key);
    if ( $status eq 'failed' ) {
        return $undefined;
    }
    if ( $status eq 'found' && ( $token // q{} ) =~ $TAG_TOKEN_PATTERN ) {
        return $token;
    }

    my $minted = unpack 'H*', Crypt::URandom::urandom($TAG_TOKEN_BYTES);
    if (
        !$self->_client_put(
            $store_key, $minted,
            $self->_expire_at_ns($TAG_TOKEN_TTL_SECONDS),
        )
      )
    {
        return $undefined;
    }

    return $minted;
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
