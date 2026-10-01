# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use strict;
use warnings;

use Const::Fast;
use JSON::MaybeXS qw(encode_json);
use Mojo::File    qw(path);
use Test::Mojo;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Config;
use GPForum::Service::Admin::Diagnostics;
use GPForum::Service::Admin::Settings;
use GPForum::Test::AdminAuditLog;
use GPForum::Test::AdminWebServices;
use GPForum::Test::AllowLimiter;
use GPForum::Test::AllowPermissionGate;
use GPForum::Test::Antivirus;
use GPForum::Test::DenyPermissionGate;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $PREVIOUS_SECRETS  => 2;

# Every secret Config reads, set to a value that is easy to look for. None of
# them, nor any part marked KNOWN, may reach the page: not its HTML, not its
# JSON, not redacted to a prefix.
const my %SECRET_ENV => (
    GPFORUM_DATABASE_DSN =>
      'dbi:Pg:dbname=gpforum;host=db.example.test;password=dsn-pw-KNOWN-1a',
    GPFORUM_DATABASE_PASSWORD => 'db-password-KNOWN-2b',
    GPFORUM_METRICS_TOKEN     => 'metrics-token-KNOWN-3c',
    GPFORUM_METRICS_TOKENS    => 'old-metrics-token-KNOWN-4d',
    GPFORUM_MINION_ENABLED    => '1',
    GPFORUM_MINION_PG_URL     =>
      'postgresql://minion:minion-pw-KNOWN-5e@db.example.test/minion',
    GPFORUM_SESSION_SECRET  => 'session-secret-KNOWN-6f',
    GPFORUM_SESSION_SECRETS =>
      'previous-secret-KNOWN-7a,previous-secret-KNOWN-8b',
    GPFORUM_SMTP_HOST     => 'smtp.example.test',
    GPFORUM_SMTP_PASSWORD => 'smtp-password-KNOWN-9c',
    GPFORUM_SMTP_USERNAME => 'smtp-user-KNOWN-0d',
);
const my @SECRET_VALUES => qw(
  dsn-pw-KNOWN-1a db-password-KNOWN-2b metrics-token-KNOWN-3c
  old-metrics-token-KNOWN-4d minion-pw-KNOWN-5e session-secret-KNOWN-6f
  previous-secret-KNOWN-7a previous-secret-KNOWN-8b smtp-password-KNOWN-9c
  smtp-user-KNOWN-0d
);

# The page lists what Config reads. A GPFORUM_ variable Config gains and the
# page does not name fails here, before an operator goes looking for it.
my $config_source = path('lib/GPForum/Config.pm')->slurp;
$config_source =~ s/^__END__$ .*//msx;
my %read_by_config =
  map { $_ => 1 } $config_source =~ /\b(GPFORUM_[[:upper:][:digit:]_]+)\b/gmsx;
my @listed = @{ GPForum::Service::Admin::Settings->env_names };
my %listed = map { $_ => 1 } @listed;
is_deeply(
    [ sort keys %read_by_config ],
    [ sort keys %listed ],
    'the settings page lists exactly the variables GPForum::Config reads'
);
is( scalar @listed, scalar keys %listed, 'each of them once' );

my $defaults = GPForum::Config->new;
for my $setting (
    map { @{ $_->{settings} } }
    @{ GPForum::Service::Admin::Settings->new( config => $defaults )
          ->view->{sections}
    }
  )
{
    ok( $defaults->can( $setting->{name} ),
        "$setting->{env} is read from Config's $setting->{name}" );
}

for my $secret (
    qw(GPFORUM_SESSION_SECRET GPFORUM_SESSION_SECRETS GPFORUM_DATABASE_PASSWORD
    GPFORUM_METRICS_TOKEN GPFORUM_METRICS_TOKENS GPFORUM_SMTP_USERNAME
    GPFORUM_SMTP_PASSWORD GPFORUM_FUTURE_API_TOKEN GPFORUM_FUTURE_KEY)
  )
{
    ok( GPForum::Service::Admin::Settings->is_secret($secret),
        "$secret is a secret" );
}
ok( !GPForum::Service::Admin::Settings->is_secret('GPFORUM_DATABASE_USER'),
    'a database role name is not' );

# The service on its own: a secret is set or not, never shown.
my $configured = GPForum::Config->from_environment( {%SECRET_ENV} );
my $service    = GPForum::Service::Admin::Settings->new(
    config      => $configured,
    environment => {%SECRET_ENV},
);
my $view    = $service->view;
my $encoded = encode_json($view);
for my $secret (@SECRET_VALUES) {
    unlike( $encoded, qr/\Q$secret\E/msx, "the view never holds $secret" );
}
unlike( $encoded, qr/KNOWN/msx, 'nor any part of a secret' );

my %by_env =
  map { $_->{env} => $_ } map { @{ $_->{settings} } } @{ $view->{sections} };
is_deeply(
    $by_env{GPFORUM_SMTP_PASSWORD},
    {
        configured => 1,
        env        => 'GPFORUM_SMTP_PASSWORD',
        list       => 0,
        name       => 'smtp_password',
        secret     => 1,
        source     => 'environment',
    },
    'a secret says only that it is set, and from where'
);
is( $by_env{GPFORUM_SESSION_SECRETS}{configured},
    $PREVIOUS_SECRETS, 'a list of secrets says how many' );
is( $by_env{GPFORUM_DATABASE_PASSWORD}{value},
    undef, 'and carries no value at all' );
is(
    $by_env{GPFORUM_DATABASE_DSN}{value},
    'dbi:Pg:dbname=gpforum;host=db.example.test;password=[redacted]',
    'a DSN shows its database and host, not its password'
);
is(
    $by_env{GPFORUM_MINION_PG_URL}{value},
    'postgresql://minion:[redacted]@db.example.test/minion',
    'a URL shows its user and host, not its password'
);
is( $by_env{GPFORUM_SMTP_HOST}{value},
    'smtp.example.test', 'an ordinary setting shows its value' );
is( $by_env{GPFORUM_SMTP_HOST}{source},
    'environment', 'taken from the environment' );
is( $by_env{GPFORUM_LOG_LEVEL}{source},
    'default', 'and one nobody set says it is the default' );
is( $by_env{GPFORUM_LOG_LEVEL}{value}, 'info', 'with the default value' );
is( $by_env{GPFORUM_SESSION_SECRET}{source},
    'environment', 'a secret says where it came from too' );

is(
    $service->redact(
        'AUTH failed for smtp-user-KNOWN-0d: smtp-password-KNOWN-9c'),
    'AUTH failed for [redacted]: [redacted]',
    'redact scrubs configured secrets out of free text'
);
is(
    GPForum::Service::Admin::Settings->new(
        config      => GPForum::Config->new( smtp_password => 'pw' ),
        environment => {},
    )->redact('pw and password=pw'),
    '[redacted] and password=[redacted]',
    'a short secret cannot mangle the marker that replaced it'
);
is(
    $service->redact(
        q{dbi:Pg:dbname=gpforum;password='quoted KNOWN; pw';host=db}),
    'dbi:Pg:dbname=gpforum;password=[redacted];host=db',
    'a quoted DSN password is replaced whole, spaces and semicolons included'
);
is(
    $service->redact(q{dbi:Pg:dbname=gpforum;password='unterminated KNOWN}),
    'dbi:Pg:dbname=gpforum;password=[redacted]',
    'and one left unterminated up to the end'
);
is(
    $service->redact('dbi:Pg:host=db;sslpassword=key-pw-KNOWN;sslkey=/k.pem'),
    'dbi:Pg:host=db;sslpassword=[redacted];sslkey=/k.pem',
    q{libpq's sslpassword is a password too}
);
is(
    $service->redact('postgresql://minion:p@ss-KNOWN@db.example.test/minion'),
    'postgresql://minion:[redacted]@db.example.test/minion',
    'a URL password with an unencoded @ is replaced up to the host'
);

my $unset = GPForum::Service::Admin::Settings->new(
    config      => $defaults,
    environment => {}
)->view;
my %unset_by_env =
  map { $_->{env} => $_ } map { @{ $_->{settings} } } @{ $unset->{sections} };
is( $unset_by_env{GPFORUM_SMTP_PASSWORD}{configured},
    0, 'an empty secret says it is not set' );
is( $unset_by_env{GPFORUM_SESSION_SECRET}{source},
    'default', 'the built-in development secret says it is the default' );

# The page, from the configuration the process loaded.
my $test     = Test::Mojo->new('GPForum');
my $services = GPForum::Test::AdminWebServices->new;
_install_fakes( $test, $services );

$test->get_ok( '/admin/settings' => { Accept => 'application/json' } );
$test->status_is($HTTP_UNAUTHORIZED);
$test->get_ok('/admin/settings');
$test->status_is($HTTP_UNAUTHORIZED);

$test->get_ok('/__test/session/admin-1')->status_is($HTTP_OK);

{
    local @ENV{ keys %SECRET_ENV } = values %SECRET_ENV;
    local $ENV{GPFORUM_LOG_PATH} = '/var/log/<b>gpforum</b>.log';
    my $loaded = GPForum::Config->from_environment;
    $test->app->helper( gp_config => sub { return $loaded; } );

    $test->get_ok('/admin/settings');
    $test->status_is($HTTP_OK);
    my $html = $test->tx->res->body;
    for my $secret (@SECRET_VALUES) {
        unlike( $html, qr/\Q$secret\E/msx, "the page never shows $secret" );
    }
    unlike( $html, qr/KNOWN/msx, 'nor any part of a secret' );
    $test->element_exists(
        'section[aria-labelledby="admin-configuration-heading"] table');
    $test->text_is(
        'th[scope="row"] code' => 'GPFORUM_ENV',
        'each row names its variable'
    );
    $test->content_like( qr/password=\[redacted\]/msx,
        'the DSN is shown with its password replaced' );
    $test->content_like( qr/Set [ ] [(]hidden[)]/msx, 'a secret reads as set' );
    $test->content_like(
        qr{/etc/gpforum/gpforum[.]env}msx,
        'the page says where settings are changed'
    );
    $test->content_like( qr/systemctl [ ] restart [ ] gpforum/msx,
        'and how they take effect' );
    $test->content_like(
        qr/&lt;b&gt;gpforum&lt;\/b&gt;/msx,
        'a value is escaped, not rendered'
    );
    $test->content_unlike( qr/<b>gpforum<\/b>/msx, 'never as markup' );

    $test->get_ok( '/admin/settings' => { Accept => 'application/json' } );
    $test->status_is($HTTP_OK);
    my $json = $test->tx->res->body;
    for my $secret (@SECRET_VALUES) {
        unlike( $json, qr/\Q$secret\E/msx, "the JSON never holds $secret" );
    }
    unlike( $json, qr/KNOWN/msx, 'nor any part of a secret' );
    $test->json_is( '/sections/0/name'              => 'application' );
    $test->json_is( '/sections/0/settings/0/env'    => 'GPFORUM_ENV' );
    $test->json_is( '/sections/0/settings/0/source' => 'default' );
    $test->json_is( '/mail/recipient'               => 'admin-1@example.test' );
    $test->json_is( '/antivirus/in_request'         => 1 );
    $test->json_like( '/mail/command_id' => qr/\S/msx );

    $test->get_ok( '/admin/settings' => { 'Accept-Language' => 'it' } );
    $test->status_is($HTTP_OK);
    $test->text_is( '#admin-settings-heading' => 'Impostazioni e diagnostica' );
    $test->content_like( qr/Impostato [ ] [(]nascosto[)]/msx,
        'and in Italian' );
    unlike( $test->tx->res->body, qr/KNOWN/msx, 'still without a secret' );
}

# Reachable from the admin navigation, and linked to its own sections.
$test->get_ok('/admin');
$test->element_exists(q{nav[aria-label="Admin"] a[href="/admin/settings"]});
$test->get_ok('/admin/status');
$test->element_exists(q{a[href="/admin/settings"]});
$test->get_ok('/admin/settings');
for my $anchor (
    qw(admin-configuration-heading admin-mail-heading admin-antivirus-heading))
{
    $test->element_exists(qq{a[href="#$anchor"]});
    $test->element_exists(qq{#$anchor});
}

# A member without the console's view permission sees none of it.
$test->app->helper(
    gp_permission_gate => sub { return GPForum::Test::DenyPermissionGate->new; }
);
$test->get_ok( '/admin/settings' => { Accept => 'application/json' } );
$test->status_is($HTTP_FORBIDDEN);
$test->get_ok('/admin/settings');
$test->status_is($HTTP_FORBIDDEN);
$test->content_unlike( qr/GPFORUM_/msx, 'not even the variable names' );

done_testing();

sub _install_fakes {
    my ( $test_object, $fakes ) = @_;

    my $app = $test_object->app;
    for my $helper (
        qw(gp_role_catalog gp_category_store gp_role_binding_store
        gp_permission_review gp_admin_audit_review gp_admin_console_reader
        gp_dead_letter_replay gp_admin_maintenance)
      )
    {
        $app->helper( $helper => sub { return $fakes; } );
    }
    $app->helper(
        gp_admin_diagnostics => sub {
            my ($controller) = @_;

            return GPForum::Service::Admin::Diagnostics->new(
                accounts     => $fakes,
                antivirus    => GPForum::Test::Antivirus->new,
                audit_review => GPForum::Test::AdminAuditLog->new,
                config       => $controller->gp_config,
            );
        }
    );
    $app->helper(
        gp_permission_gate => sub {
            return GPForum::Test::AllowPermissionGate->new;
        }
    );
    $app->helper(
        gp_rate_limiter => sub { return GPForum::Test::AllowLimiter->new; } );
    $app->routes->get('/__test/session/:user_id')->to(
        cb => sub {
            my ($controller) = @_;

            $controller->session( user_id => $controller->param('user_id') );
            return $controller->render( json => { ok => 1 } );
        }
    );

    return;
}

1;
