# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English qw(-no_match_vars);
use Test::Exception;
use Test::More;

use lib 'lib';

use GPForum::Bootstrap::Config;
use GPForum::Config;
use GPForum::Config::Report;
use GPForum::OS;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::Doctor;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Profile;

our $VERSION = '0.001';

# GPFORUM_ENV said two things: where a node runs and how big it is
# (production-small, production-medium). The size had to be chosen by hand,
# and choosing it sized nothing: the profile raised floors the defaults did
# not meet (audit 2.3, D1'). It says where a node runs now -- development,
# staging or production -- and the size comes from the host (t/611). The old
# names still start, read as production, each with a one-line note naming the
# line to write (audit 5.6, ADR 0125).

const my $FILE => '/etc/gpforum/gpforum.env';
const my %PRODUCTION => (
    GPFORUM_MAIL_FROM       => 'forum@forum.gpforum.net',
    GPFORUM_METRICS_TOKEN   => 'metrics-token',
    GPFORUM_PUBLIC_BASE_URL => 'https://forum.gpforum.net',
    GPFORUM_SESSION_SECRET  => '0123456789abcdef' x 3,
);

subtest 'three environments, and the refusal names only them' => sub {
    for my $environment (qw(development staging production)) {
        is(
            GPForum::Config->from_environment(
                { %PRODUCTION, GPFORUM_ENV => $environment }
            )->environment,
            $environment,
            "$environment is one"
        );
    }
    throws_ok {
        GPForum::Config->from_environment( { GPFORUM_ENV => 'large' } )
    }
    'GPForum::X::Config', 'a size is not an environment';
    is(
        GPForum::Config::Report->sentence( $EVAL_ERROR->problems->[0] ),
        'GPFORUM_ENV must be one of development, test, staging, production,'
          . q{ not 'large'.},
        'and the old names are not offered'
    );
    is_deeply(
        GPForum::Service::Operations::Profile->new->names,
        [qw(development production staging)],
        'one profile for each'
    );
};

subtest 'the old names start as production, noted' => sub {
    for my $old (qw(production-small production-medium)) {
        my $config = GPForum::Config->from_environment(
            { %PRODUCTION, GPFORUM_ENV => $old } );
        is( $config->environment, 'production', "$old reads as production" );
        ok( $config->is_production && $config->requires_secure_transport,
            'and is held to everything production is' );
        is_deeply(
            $config->renamed_settings,
            [
                {
                    setting     => 'environment',
                    variable    => 'GPFORUM_ENV',
                    replacement => 'GPFORUM_ENV',
                    old         => $old,
                    value       => 'production',
                }
            ],
            'with the value written and the one it now is'
        );
        is(
            GPForum::Service::Operations::Profile->new->evaluate($config)
              ->{profile}{name},
            'production', q{and production's profile}
        );
    }
    my $built = GPForum::Config->new( environment => 'production-medium' );
    ok( $built->is_production, 'a configuration built with new reads it too' );
    is(
        GPForum::Service::Operations::Profile->new->name_for_environment(
            $built->environment
        ),
        'production',
        'under the profile it now has'
    );
};

subtest 'one line at the start, in English and in Italian' => sub {
    my ($renamed) = @{ GPForum::Config->from_environment(
            { %PRODUCTION, GPFORUM_ENV => 'production-medium' }
        )->renamed_settings
    };
    is(
        GPForum::Bootstrap::Config->renamed_warning(
            $renamed,
            GPForum::Service::I18N::CliCatalog->new( language => 'en' )
        ),
        'GPFORUM_ENV=production-medium is now called production; write'
          . ' GPFORUM_ENV=production in the environment file in its place.',
        'English'
    );
    is(
        GPForum::Bootstrap::Config->renamed_warning(
            $renamed,
            GPForum::Service::I18N::CliCatalog->new( language => 'it' )
        ),
        'GPFORUM_ENV=production-medium ora si chiama production; scrivi'
          . q{ GPFORUM_ENV=production nel file d'ambiente al suo posto.},
        'Italian'
    );
};

subtest 'doctor lists it under !, with the exact line to write' => sub {
    my %environment = ( %PRODUCTION, GPFORUM_ENV => 'production-small' );
    my $catalog = GPForum::Service::I18N::CliCatalog->new( language => 'en' );
    my $doctor  = GPForum::Service::Operations::Doctor->new(
        catalog     => $catalog,
        environment => \%environment,
        file        => $FILE,
        assigned    => [ sort keys %environment ],
        os          => GPForum::OS->from_name('linux'),
        probes      => { tls => sub { return 1 } },
    );
    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $catalog );
    ok( $doctor->settings( \%environment, $findings ),
        'an old name stops nothing' );
    my ($renamed) =
      grep { $_->{status} eq 'degraded' } @{ $findings->document };
    is(
        $renamed->{message},
        'GPFORUM_ENV=production-small is now called production; write'
          . ' GPFORUM_ENV=production in the environment file in its place.',
        'the note'
    );
    is_deeply(
        $renamed->{fixes},
        ["set GPFORUM_ENV=production in $FILE"],
        'and the line, where it is set'
    );
    like( $findings->human_text, qr/^! [ ] GPFORUM_ENV=production-small/msx,
        'marked !' );
};

done_testing();

1;
