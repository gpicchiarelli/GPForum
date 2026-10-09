# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Const::Fast;
use English    qw(-no_match_vars);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Config;
use GPForum::Config::EnvironmentFile;
use GPForum::Service::Admin::Settings;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Web::ForumAccess;

our $VERSION = '0.001';

const my $DEFAULT_LIMIT  => 60;
const my $CAPACITY_LIMIT => 100_000;
const my $CHOSEN_LIMIT   => 250;

# GPFORUM_FORUM_READ_RATE_LIMIT was read straight from %ENV by
# Web::ForumAccess: honoured in production, missing from the settings page,
# the environment file template and the validation, and a value it could not
# read was dropped without a word (audit 2.2, a "hidden security knob"). It is
# now a row of the settings table like every other.

subtest 'it is a setting, read and checked as the others are' => sub {
    is( GPForum::Config->new->forum_read_rate_limit,
        $DEFAULT_LIMIT, 'sixty pages a minute by default' );
    is(
        GPForum::Config->from_environment(
            { GPFORUM_FORUM_READ_RATE_LIMIT => "$CAPACITY_LIMIT" }
        )->forum_read_rate_limit,
        $CAPACITY_LIMIT,
        'a capacity run raises it'
    );
    is(
        _sentence( { GPFORUM_FORUM_READ_RATE_LIMIT => '0' } ),
        'GPFORUM_FORUM_READ_RATE_LIMIT must be at least 1, not 0.',
        'zero, which used to be ignored, is refused'
    );
    is(
        _sentence( { GPFORUM_FORUM_READ_RATE_LIMIT => 'lots' } ),
        q{GPFORUM_FORUM_READ_RATE_LIMIT must be a whole number, not 'lots'.},
        'and so is a word'
    );
    my ($row) = grep { $_->{env} eq 'GPFORUM_FORUM_READ_RATE_LIMIT' }
      @{ GPForum::Config->settings };
    is( $row->{section}, 'security', 'filed with the other limits' );
};

subtest 'the forum reads it from the configuration, not the process' => sub {
    local $ENV{GPFORUM_FORUM_READ_RATE_LIMIT} = '5';
    is( GPForum::Web::ForumAccess->new->read_rate_input( {} )->{limit},
        $DEFAULT_LIMIT, 'without a configuration the product default' );
    is(
        GPForum::Web::ForumAccess->new(
            config => GPForum::Config->from_environment(
                { GPFORUM_FORUM_READ_RATE_LIMIT => "$CHOSEN_LIMIT" }
            )
        )->read_rate_input( {} )->{limit},
        $CHOSEN_LIMIT,
        q{with one, the configuration's value, whatever %ENV holds}
    );
    my $handed = 'ForumAccess->new( config => $self->gp_config )';
    like( path('lib/GPForum/Controller/Forum/Base.pm')->slurp,
        qr/\Q$handed\E/msx,
        'and the forum controllers hand it the application configuration' );
    unlike(
        path('lib/GPForum/Web/ForumAccess.pm')->slurp =~ s/^__END__$ .*//msxr,
        qr/\$ENV/msx,
        'nothing in ForumAccess reads the process environment'
    );
};

subtest 'the settings page and the template list it' => sub {
    my $view = GPForum::Service::Admin::Settings->new(
        config      => GPForum::Config->new,
        environment => {},
    )->view;
    my ($security) = grep { $_->{name} eq 'security' } @{ $view->{sections} };
    my ($setting)  = grep { $_->{env} eq 'GPFORUM_FORUM_READ_RATE_LIMIT' }
      @{ $security->{settings} };
    is_deeply(
        [ @{$setting}{qw(value source secret)} ],
        [ '60', 'default', 0 ],
        'the page shows it, in the security section, with its default'
    );
    my $offered = join "\n",
      '# Forum pages one visitor may read per minute; raise it only for a load'
      . ' test from one address.',
      '#GPFORUM_FORUM_READ_RATE_LIMIT=60', q{};
    like(
        GPForum::Config::EnvironmentFile->render_reference,
        qr/^\Q$offered\E/msx,
        'the template offers it, commented out at its default'
    );
};

done_testing();

sub _sentence ($environment) {
    my $problems = [];
    eval {
        GPForum::Config->from_environment($environment);
        1;
    } or $problems = $EVAL_ERROR->problems;
    my $problem = $problems->[0] // return undef;

    return GPForum::Service::I18N::CliCatalog->new( language => 'en' )->text(
        $problem->{key},
        {
            %{ $problem->{parameters} },
            variable => $problem->{variable},
            value    => $problem->{value},
        }
    );
}

1;
