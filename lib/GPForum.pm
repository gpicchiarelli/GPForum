# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum;

use strict;
use warnings;

use Mojo::Base 'Mojolicious', -signatures;

use GPForum::Bootstrap::Admin;
use GPForum::Bootstrap::Core;
use GPForum::Bootstrap::Discovery;
use GPForum::Bootstrap::Forum;
use GPForum::Bootstrap::I18N;
use GPForum::Bootstrap::Identity;
use GPForum::Bootstrap::Moderation;
use GPForum::Bootstrap::Operations;
use GPForum::Bootstrap::Privacy;
use GPForum::Bootstrap::Routes;
use GPForum::Bootstrap::Security;
use GPForum::Bootstrap::Workers;
use GPForum::Config;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;

our $VERSION = '0.001';

sub startup ($self) {

    # bin/gpforum started Mojolicious::Commands without registering a
    # namespace, so it listed the framework's own commands -- including
    # cpanify, "Upload distribution to CPAN" -- and none of this project's 22
    # operational ones. Registering the namespace gives `gpforum`, `gpforum
    # help <command>` and shell completion over the real commands.
    # Mojolicious::Command::Author is dropped with it: an operator front door
    # should not offer `cpanify`, "Upload distribution to CPAN", or the
    # application generators. daemon, prefork, get, routes and eval stay,
    # because those are things an operator does use.
    $self->commands->namespaces( [ 'GPForum::CLI', 'Mojolicious::Command' ] );

    my $config  = GPForum::Config->from_environment;
    my $runtime = GPForum::Runtime->from_config($config);
    my $runtime_policy =
      GPForum::OS::RuntimePolicy->new( config => $config, runtime => $runtime );

    GPForum::Bootstrap::Core->register(
        application => $self,
        config      => $config,
    );
    GPForum::Bootstrap::Security->register(
        application => $self,
        config      => $config,
    );
    GPForum::Bootstrap::I18N->register(
        application => $self,
        config      => $config,
    );
    GPForum::Bootstrap::Operations->register(
        application    => $self,
        config         => $config,
        runtime        => $runtime,
        runtime_policy => $runtime_policy,
    );
    GPForum::Bootstrap::Identity->register(
        application => $self,
        config      => $config,
    );
    GPForum::Bootstrap::Discovery->register(
        application => $self,
        config      => $config,
    );
    GPForum::Bootstrap::Forum->register(
        application => $self,
        config      => $config,
    );
    GPForum::Bootstrap::Workers->register(
        application => $self,
        config      => $config,
    );
    GPForum::Bootstrap::Admin->register( application => $self );
    GPForum::Bootstrap::Moderation->register( application => $self );
    GPForum::Bootstrap::Privacy->register( application => $self );
    GPForum::Bootstrap::Routes->register( application => $self );

    return;
}

1;

__END__

=head1 NAME

GPForum - Mojolicious application root.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $app = GPForum->new;

=head1 DESCRIPTION

Bootstraps the GPForum web application by loading configuration, building the
runtime policy, and delegating service/helper/route registration to focused
bootstrap modules.

=head1 SUBROUTINES/METHODS

=head2 startup

Configures application dependencies and routes through modular bootstrap units.

=head1 DIAGNOSTICS

Startup delegates configuration validation to L<GPForum::Config>.

=head1 CONFIGURATION AND ENVIRONMENT

Reads runtime configuration through L<GPForum::Config>.

=head1 DEPENDENCIES

Uses L<Mojolicious> plus GPForum configuration, runtime, and bootstrap modules.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The application is still an MVP. Some advanced boundaries remain operational
contracts before becoming complete product workflows.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
