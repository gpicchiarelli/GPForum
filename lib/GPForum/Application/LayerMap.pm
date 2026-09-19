package GPForum::Application::LayerMap;

use strict;
use warnings;

use Mojo::Base -base;

our $VERSION = '0.001';

sub layers {
    return [
        _layer( 'Application',    'GPForum::Application' ),
        _layer( 'Domain',         'GPForum::Domain' ),
        _layer( 'Infrastructure', 'GPForum::Infrastructure' ),
        _layer( 'Query',          'GPForum::Query' ),
        _layer( 'Command',        'GPForum::Command' ),
        _layer( 'Web',            'GPForum::Web' ),
        _layer( 'Jobs',           'GPForum::Jobs' ),
        _layer( 'Security',       'GPForum::Security' ),
        _layer( 'Theme',          'GPForum::Theme' ),
        _layer( 'I18N',           'GPForum::I18N' ),
    ];
}

sub namespace_for {
    my ( $self, $name ) = @_;

    for my $layer ( @{ $self->layers } ) {
        return $layer->{namespace} if $layer->{name} eq $name;
    }

    return;
}

sub _layer {
    my ( $name, $namespace ) = @_;

    return { name => $name, namespace => $namespace };
}

1;
