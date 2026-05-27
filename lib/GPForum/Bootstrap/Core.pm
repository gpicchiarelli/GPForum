package GPForum::Bootstrap::Core;

use strict;
use warnings;

use GPForum::Service::Clock;
use GPForum::Service::Id;
use GPForum::Service::Realtime::Hub;

our $VERSION = '0.001';

sub register {
    my ( undef, %input ) = @_;

    my $application = $input{application};
    my $config      = $input{config};

    $application->secrets( [ $config->session_secret ] );
    $application->mode( $config->environment );
    _configure_static_assets($application);

    $application->helper(
        gp_clock => sub { return GPForum::Service::Clock->new; } );
    $application->helper( gp_id => sub { return GPForum::Service::Id->new; } );

    my $realtime_hub;
    $application->helper(
        gp_realtime_hub => sub {
            $realtime_hub ||= GPForum::Service::Realtime::Hub->new;
            return $realtime_hub;
        }
    );

    return;
}

sub _configure_static_assets {
    my ($application) = @_;

    my $paths = $application->static->paths;
    push @{$paths},
      $application->home->rel_file('assets/css')->to_string,
      $application->home->rel_file('assets/img')->to_string;

    return;
}

1;
