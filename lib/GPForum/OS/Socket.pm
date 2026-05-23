package GPForum::OS::Socket;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub snapshot {
    my ( $self, $os, $features ) = @_;

    return {
        reuseaddr => _option(
            {
                supported => 1,
                enabled   => 1,
                purpose   => 'listener restart tolerance',
            }
        ),
        reuseport => _option(
            {
                supported => $os->supports_reuseport ? 1 : 0,
                enabled   => _feature_enabled( $features, 'reuseport' ),
                purpose   => 'multi-process listener distribution',
            }
        ),
        keepalive => _option(
            {
                supported => 1,
                enabled   => 1,
                purpose   => 'connection liveness detection',
            }
        ),
        tcp_nodelay => _option(
            {
                supported => 1,
                enabled   => 1,
                purpose   => 'latency control for dynamic responses',
            }
        ),
        sendfile => _option(
            {
                supported => $os->supports_sendfile ? 1 : 0,
                enabled   => _feature_enabled( $features, 'sendfile' ),
                purpose   => 'delegated static and attachment transfer',
            }
        ),
    };
}

sub _option {
    my ($input) = @_;

    my $supported = $input->{supported} ? 1 : 0;
    my $requested = $input->{enabled}   ? 1 : 0;
    my $enabled   = _enabled_option( $requested, $supported );

    return {
        supported => $supported,
        enabled   => $enabled,
        degraded  => _degraded_option( $requested, $supported ),
        purpose   => $input->{purpose},
    };
}

sub _enabled_option {
    my ( $requested, $supported ) = @_;

    return $requested && $supported ? 1 : 0;
}

sub _degraded_option {
    my ( $requested, $supported ) = @_;

    return $requested && !$supported ? 1 : 0;
}

sub _feature_enabled {
    my ( $features, $name ) = @_;

    return 0 if !$features;
    return 0 if !exists $features->{$name};

    return $features->{$name}{enabled} ? 1 : 0;
}

1;
