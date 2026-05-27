package GPForum::OS::Base;

use strict;
use warnings;

use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;
use POSIX qw(sysconf);

use GPForum::OS::Filesystem;
use GPForum::OS::Process;
use GPForum::OS::Resource;
use GPForum::OS::Socket;

our $VERSION = '0.001';

const my $DEFAULT_CPU_COUNT    => 1;
const my $DEFAULT_WEB_FLOOR    => 1;
const my $MAX_WEB_PER_CPU      => 2;
const my $FEATURE_AUTO         => 'auto';
const my $FEATURE_ON           => 'on';
const my $FEATURE_OFF          => 'off';
const my $NPROCESSORS_CONSTANT => '_SC_NPROCESSORS_ONLN';

has name           => 'unknown';
has filesystem     => sub { return GPForum::OS::Filesystem->new; };
has process_policy => sub { return GPForum::OS::Process->new; };
has resource_probe => sub { return GPForum::OS::Resource->new; };
has socket_policy  => sub { return GPForum::OS::Socket->new; };

sub supports_reuseport {
    return 0;
}

sub supports_sendfile {
    return 0;
}

sub event_backend {
    return 'select';
}

sub cpu_count {
    my ($self) = @_;

    my $code = POSIX->can($NPROCESSORS_CONSTANT);
    return $DEFAULT_CPU_COUNT if !$code;

    my $processors = eval { return sysconf( $code->() ); };
    return $DEFAULT_CPU_COUNT
      if !$processors || $processors < $DEFAULT_CPU_COUNT;

    return $processors;
}

sub recommended_worker_count {
    my ($self) = @_;

    my $count = $self->cpu_count;
    return $DEFAULT_WEB_FLOOR if $count < $DEFAULT_WEB_FLOOR;

    return $count > $MAX_WEB_PER_CPU ? $MAX_WEB_PER_CPU : $count;
}

sub feature_enabled {
    my ( $self, $feature, $setting ) = @_;

    my $value = defined $setting && length $setting ? $setting : $FEATURE_AUTO;
    return 0 if $value eq $FEATURE_OFF;
    return 1 if $value eq $FEATURE_ON;

    return $self->_auto_feature_enabled($feature);
}

sub feature_snapshot {
    my ( $self, $settings ) = @_;

    if ( !$settings ) {
        $settings = {};
    }

    return {
        reuseport => _feature_entry(
            $settings, 'reuseport',
            $self->feature_enabled( 'reuseport', $settings->{reuseport} )
        ),
        sendfile => _feature_entry(
            $settings, 'sendfile',
            $self->feature_enabled( 'sendfile', $settings->{sendfile} )
        ),
        worker_priority => _feature_entry(
            $settings,
            'worker_priority',
            $self->feature_enabled(
                'worker_priority', $settings->{worker_priority}
            )
        ),
        static_xsendfile => _feature_entry(
            $settings,
            'static_xsendfile',
            $self->feature_enabled(
                'static_xsendfile', $settings->{static_xsendfile}
            )
        ),
        affinity => {
            setting => $settings->{affinity} || 'off',
            enabled => ( $settings->{affinity} || 'off' ) eq 'manual' ? 1 : 0,
        },
    };
}

sub snapshot {
    my ($self) = @_;

    return {
        name                     => $self->name,
        perl_version             => "$PERL_VERSION",
        event_backend            => $self->event_backend,
        cpu_count                => $self->cpu_count,
        recommended_worker_count => $self->recommended_worker_count,
        supports_reuseport       => $self->supports_reuseport ? 1 : 0,
        supports_sendfile        => $self->supports_sendfile  ? 1 : 0,
        resources                => $self->resource_probe->snapshot,
        sockets                  => $self->socket_snapshot( {} ),
        processes                => $self->process_snapshot( {} ),
    };
}

sub socket_snapshot {
    my ( $self, $settings ) = @_;

    return $self->socket_policy->snapshot( $self,
        $self->feature_snapshot($settings),
    );
}

sub process_snapshot {
    my ( $self, $settings ) = @_;

    return $self->process_policy->snapshot( $self->feature_snapshot($settings),
    );
}

sub _feature_entry {
    my ( $settings, $name, $enabled ) = @_;

    return {
        setting => $settings->{$name} || $FEATURE_AUTO,
        enabled => $enabled ? 1 : 0,
    };
}

sub _auto_feature_enabled {
    my ( $self, $feature ) = @_;

    return $self->supports_reuseport if $feature eq 'reuseport';
    return $self->supports_sendfile  if $feature eq 'sendfile';
    return $self->supports_sendfile  if $feature eq 'static_xsendfile';

    return 0;
}

1;
