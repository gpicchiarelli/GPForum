package GPForum::Service::Operations::SharedCache;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use JSON::MaybeXS;
use Mojo::Base -base;

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

has client    => undef;
has connector => undef;
has endpoint  => undef;
has clock     => sub { return GPForum::Service::Clock->new; };
has codec => sub { return JSON::MaybeXS->new( canonical => 1, utf8 => 1 ); };
has namespace   => sub { return $DEFAULT_NAMESPACE; };
has ttl_seconds => sub { return $DEFAULT_TTL_SECONDS; };
has stats       => sub {
    return {
        failures      => 0,
        hits          => 0,
        invalidations => 0,
        misses        => 0,
        writes        => 0,
    };
};

sub connect_required {
    my ( $class, $options ) = @_;

    $options ||= {};
    if ( !_has_text( $options->{url} ) ) {
        croak 'glifistore_url is required';
    }

    my $endpoint = $class->parse_endpoint( $options->{url} );
    return $class->_instance_for_endpoint( $endpoint, $options );
}

sub try_connect {
    my ( $class, $options ) = @_;

    $options ||= {};
    if ( !_has_text( $options->{url} ) ) {
        return;
    }

    my $cache = eval { return $class->connect_required($options); };
    if ( !$cache ) {
        return;
    }

    return $cache;
}

sub parse_endpoint {
    my ( undef, $url ) = @_;

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

sub lookup {
    my ( $self, $key ) = @_;

    $self->_validate_key($key);
    my $payload = $self->_read_payload($key);
    if ( !$payload ) {
        $self->stats->{misses} += 1;
        return;
    }

    $self->stats->{hits} += 1;
    return $payload;
}

sub get {
    my ( $self, $key ) = @_;

    my $payload = $self->lookup($key);
    if ( !$payload ) {
        return;
    }

    return $payload->{value};
}

sub put {
    my ( $self, $key, $value, $options ) = @_;

    $options ||= {};
    $self->_validate_key($key);
    if ( !$self->_store_value( $key, $value, $options ) ) {
        return;
    }

    $self->stats->{writes} += 1;
    return $value;
}

sub get_or_set {
    my ( $self, $key, $producer, $options ) = @_;

    my $cached = $self->get($key);
    if ( defined $cached ) {
        return $cached;
    }

    my $generated = $producer->();
    $self->put( $key, $generated, $options );
    return $generated;
}

sub invalidate {
    my ( $self, $key ) = @_;

    $self->_validate_key($key);
    my $removed = $self->_drop_entry($key);
    $self->stats->{invalidations} += $removed;
    return $removed;
}

sub invalidate_tag {
    my ( $self, $tag ) = @_;

    if ( !_has_text($tag) ) {
        return 0;
    }

    my $keys    = $self->_read_tag_keys($tag);
    my $removed = $self->_drop_keys($keys);
    $self->_erase_store_key( $self->_tag_store_key($tag) );
    $self->stats->{invalidations} += $removed;
    return $removed;
}

sub purge_expired {
    return 0;
}

sub clear {
    return 0;
}

sub snapshot {
    my ($self) = @_;

    return {
        namespace   => $self->namespace,
        layer       => 'shared',
        ttl_seconds => $self->ttl_seconds,
        stats       => { %{ $self->stats } },
    };
}

sub ping {
    my ($self) = @_;

    my $client = $self->_active_client;
    if ( !$client ) {
        $self->_record_failure;
        return 0;
    }

    my $ok = eval {
        $client->ping(q{});
        return 1;
    };
    if ( !$ok ) {
        $self->_forget_client;
        return 0;
    }

    return 1;
}

sub _instance_for_endpoint {
    my ( $class, $endpoint, $options ) = @_;

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

sub _new_connected {
    my ( $class, $client, $options ) = @_;

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

sub _default_connector {
    my ($endpoint) = @_;

    require GlifiStore::Client;
    return GlifiStore::Client->connect( %{$endpoint} );
}

sub _unix_endpoint {
    my ($url) = @_;

    if ( $url =~ $UNIX_ENDPOINT_PATTERN ) {
        return {
            unix_socket_path => $1,
            connect_timeout  => $DEFAULT_CONNECT_TIMEOUT,
            request_timeout  => $DEFAULT_REQUEST_TIMEOUT,
        };
    }

    return;
}

sub _tcp_endpoint {
    my ($url) = @_;

    if ( $url =~ $TCP_ENDPOINT_PATTERN ) {
        return {
            host            => $1,
            port            => int $2,
            connect_timeout => $DEFAULT_CONNECT_TIMEOUT,
            request_timeout => $DEFAULT_REQUEST_TIMEOUT,
        };
    }

    return;
}

sub _read_payload {
    my ( $self, $key ) = @_;

    my $raw = $self->_client_get( $self->_entry_store_key($key) );
    if ( !defined $raw ) {
        return;
    }

    my $payload = $self->_decode_payload($raw);
    if ( $self->_payload_expired($payload) ) {
        $self->_erase_store_key( $self->_entry_store_key($key) );
        return;
    }

    return $payload;
}

sub _store_value {
    my ( $self, $key, $value, $options ) = @_;

    if ( !$self->_write_payload( $key, $value, $options ) ) {
        return 0;
    }

    $self->_index_tags(
        $key,
        $options->{tags}        || [],
        $options->{ttl_seconds} || $self->ttl_seconds,
    );
    return 1;
}

sub _write_payload {
    my ( $self, $key, $value, $options ) = @_;

    my $ttl     = $options->{ttl_seconds} || $self->ttl_seconds;
    my $payload = {
        expires_at_epoch => $self->clock->now_epoch + $ttl,
        tags             => $options->{tags} || [],
        value            => $value,
    };
    my $bytes = $self->_encode_payload($payload);
    if ( !defined $bytes ) {
        return 0;
    }

    return $self->_client_put(
        $self->_entry_store_key($key),
        $bytes, $self->_expire_at_ns($ttl),
    );
}

sub _drop_entry {
    my ( $self, $key ) = @_;

    my $payload = $self->_read_payload($key);
    my $removed = $self->_erase_store_key( $self->_entry_store_key($key) );
    if ( $payload && $payload->{tags} ) {
        $self->_forget_tags( $key, $payload->{tags} );
    }

    return $removed;
}

sub _drop_keys {
    my ( $self, $keys ) = @_;

    my $removed = 0;
    for my $key ( @{$keys} ) {
        $removed += $self->_erase_store_key( $self->_entry_store_key($key) );
    }

    return $removed;
}

sub _index_tags {
    my ( $self, $key, $tags, $ttl ) = @_;

    for my $tag ( @{$tags} ) {
        $self->_add_tag_member( $tag, $key, $ttl );
    }

    return;
}

sub _forget_tags {
    my ( $self, $key, $tags ) = @_;

    for my $tag ( @{$tags} ) {
        $self->_remove_tag_member( $tag, $key );
    }

    return;
}

sub _add_tag_member {
    my ( $self, $tag, $key, $ttl ) = @_;

    if ( !_has_text($tag) ) {
        return;
    }

    my %members = map { $_ => 1 } @{ $self->_read_tag_keys($tag) };
    $members{$key} = 1;
    $self->_write_tag_keys( $tag, [ sort keys %members ], $ttl );
    return;
}

sub _remove_tag_member {
    my ( $self, $tag, $key ) = @_;

    my %members = map { $_ => 1 } @{ $self->_read_tag_keys($tag) };
    delete $members{$key};
    my @remaining = sort keys %members;
    if ( !@remaining ) {
        $self->_erase_store_key( $self->_tag_store_key($tag) );
        return;
    }

    $self->_write_tag_keys( $tag, \@remaining, $self->ttl_seconds );
    return;
}

sub _read_tag_keys {
    my ( $self, $tag ) = @_;

    my $raw = $self->_client_get( $self->_tag_store_key($tag) );
    if ( !defined $raw ) {
        return [];
    }

    my $decoded = eval { return $self->codec->decode($raw); };
    if ( ref $decoded ne 'ARRAY' ) {
        return [];
    }

    return $decoded;
}

sub _write_tag_keys {
    my ( $self, $tag, $keys, $ttl ) = @_;

    my $bytes = eval { return $self->codec->encode($keys); };
    if ( !defined $bytes ) {
        $self->_record_failure;
        return;
    }

    $self->_client_put(
        $self->_tag_store_key($tag),
        $bytes, $self->_expire_at_ns($ttl),
    );
    return;
}

sub _client_get {
    my ( $self, $store_key ) = @_;

    my $client = $self->_active_client;
    if ( !$client ) {
        $self->_record_failure;
        return;
    }

    my $value = eval { return $client->get($store_key); };
    if ($EVAL_ERROR) {
        $self->_record_get_error($EVAL_ERROR);
        return;
    }

    return $value;
}

sub _client_put {
    my ( $self, $store_key, $bytes, $expire_at_ns ) = @_;

    my $client = $self->_active_client;
    if ( !$client ) {
        $self->_record_failure;
        return 0;
    }

    my $result = eval {
        return $client->put( $store_key, $bytes,
            expire_at_ns => $expire_at_ns, );
    };
    if ( !_mutation_committed($result) ) {
        $self->_forget_client;
        return 0;
    }

    return 1;
}

sub _erase_store_key {
    my ( $self, $store_key ) = @_;

    my $client = $self->_active_client;
    if ( !$client ) {
        $self->_record_failure;
        return 0;
    }

    my $result = eval { return $client->erase($store_key); };
    if ( !_mutation_committed($result) ) {
        $self->_forget_client;
        return 0;
    }

    return 1;
}

sub _active_client {
    my ($self) = @_;

    if ( $self->client ) {
        return $self->client;
    }

    return $self->_reconnect;
}

sub _reconnect {
    my ($self) = @_;

    if ( !$self->connector ) {
        return;
    }
    if ( !$self->endpoint ) {
        return;
    }

    my $client = eval { return $self->connector->( $self->endpoint ); };
    if ( !$client ) {
        $self->_record_failure;
        return;
    }

    $self->client($client);
    return $client;
}

sub _forget_client {
    my ($self) = @_;

    $self->client(undef);
    $self->_record_failure;
    return;
}

sub _record_get_error {
    my ( $self, $error ) = @_;

    if ( _is_miss_error($error) ) {
        return;
    }

    $self->_forget_client;
    return;
}

sub _record_failure {
    my ($self) = @_;

    $self->stats->{failures} += 1;
    return;
}

sub _decode_payload {
    my ( $self, $raw ) = @_;

    my $payload = eval { return $self->codec->decode($raw); };
    if ( ref $payload ne 'HASH' ) {
        $self->_record_failure;
        return;
    }

    return $payload;
}

sub _encode_payload {
    my ( $self, $payload ) = @_;

    my $bytes = eval { return $self->codec->encode($payload); };
    if ( !defined $bytes ) {
        $self->_record_failure;
        return;
    }

    return $bytes;
}

sub _payload_expired {
    my ( $self, $payload ) = @_;

    if ( !$payload ) {
        return 1;
    }

    my $expires = $payload->{expires_at_epoch};
    if ( !defined $expires ) {
        return 0;
    }

    return $self->clock->now_epoch >= $expires ? 1 : 0;
}

sub _expire_at_ns {
    my ( $self, $ttl ) = @_;

    return ( $self->clock->now_epoch + $ttl ) * $NANOSECONDS_PER_SECOND;
}

sub _entry_store_key {
    my ( $self, $key ) = @_;

    return join q{:}, $self->namespace, 'entry', $key;
}

sub _tag_store_key {
    my ( $self, $tag ) = @_;

    return join q{:}, $self->namespace, 'tag', $tag;
}

sub _validate_key {
    my ( undef, $key ) = @_;

    if ( !_has_text($key) ) {
        croak 'cache key is required';
    }

    return;
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value ? 1 : 0;
}

sub _mutation_committed {
    my ($result) = @_;

    return 0 if !$result;
    return 0 if ref $result ne 'HASH';
    return ( $result->{outcome} || q{} ) eq 'committed' ? 1 : 0;
}

sub _is_miss_error {
    my ($error) = @_;

    if ( ref $error && eval { return $error->can('category'); } ) {
        return $error->category eq 'not_found' ? 1 : 0;
    }

    my $message = "$error";
    return $message =~ /not[_ ]found/imsx ? 1 : 0;
}

1;
