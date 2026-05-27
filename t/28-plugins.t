package main;

use strict;
use warnings;

use Const::Fast;
use Test::More;

use lib 'lib';
use lib 't/lib';

use GPForum::Service::Plugin::FailureRecorder;
use GPForum::Service::Plugin::HookDispatcher;
use GPForum::Service::Plugin::ManifestValidator;
use GPForum::Service::Plugin::Registry;
use GPForum::Test::FixedClock;
use GPForum::Test::Id;
use GPForum::Test::ModerationResultSet;
use GPForum::Test::ModerationSchema;

our $VERSION = '0.001';

const my $EXPECTED_TESTS       => 40;
const my $ONE_ROW              => 1;
const my $TWO_ROWS             => 2;
const my $FIRST_FAILURE_INDEX  => 0;
const my $SECOND_FAILURE_INDEX => 1;
const my $ANALYTICS_ORDER      => 10;
const my $ANALYTICS_TIMEOUT_MS => 250;

plan tests => $EXPECTED_TESTS;

my $plugins  = GPForum::Test::ModerationResultSet->new;
my $hooks    = GPForum::Test::ModerationResultSet->new( filter_search => 1 );
my $failures = GPForum::Test::ModerationResultSet->new;
my $schema   = GPForum::Test::ModerationSchema->new(
    resultsets => {
        Plugin        => $plugins,
        PluginHook    => $hooks,
        PluginFailure => $failures,
    },
);

my $validator = GPForum::Service::Plugin::ManifestValidator->new;
my $invalid   = $validator->validate(
    {
        name         => 'gpforum-sso',
        version      => '0.1.0',
        author       => 'GPForum Labs',
        capabilities => 'auth',
        hooks        => [ { hook_name => 'admin.panel' } ],
    }
);

ok( !$invalid->{ok}, 'plugin manifest rejects invalid metadata' );
like( $invalid->{errors}{compatible_gpforum_range},
    qr/required/msx, 'plugin manifest requires compatibility range' );
like( $invalid->{errors}{required_permissions},
    qr/required/msx, 'plugin manifest requires permissions declaration' );
like( $invalid->{errors}{capabilities},
    qr/array/msx, 'plugin manifest requires capabilities array' );
like( $invalid->{errors}{'hooks.0.callback_name'},
    qr/required/msx, 'plugin manifest requires callback names' );

my $manifest = {
    name                     => 'gpforum-analytics',
    version                  => '1.0.0',
    author                   => 'Giacomo Picchiarelli',
    compatible_gpforum_range => '>=0.1.0 <1.0.0',
    capabilities             => ['analytics_sink'],
    required_permissions     => ['analytics.write'],
    config_schema            => { sample_rate => 'number' },
    hooks                    => [
        {
            hook_name          => 'post.created',
            callback_name      => 'analytics.record_post',
            execution_order    => $ANALYTICS_ORDER,
            timeout_ms         => $ANALYTICS_TIMEOUT_MS,
            side_effect_policy => 'external_io',
        },
        {
            hook_name     => 'admin.panel',
            callback_name => 'analytics.admin_panel',
        },
    ],
};
my $valid = $validator->validate($manifest);
ok( $valid->{ok}, 'complete plugin manifest validates' );

my $registry = GPForum::Service::Plugin::Registry->new(
    schema     => $schema,
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $installed = $registry->install($manifest);

ok( $installed->{ok}, 'plugin installation succeeds' );
is( $installed->{plugin}{plugin_id}, 'generated-1', 'plugin id is generated' );
is( $installed->{plugin}{name},    'gpforum-analytics', 'plugin stores name' );
is( $installed->{plugin}{version}, '1.0.0', 'plugin stores version' );
is(
    $installed->{plugin}{compatible_gpforum_range},
    '>=0.1.0 <1.0.0',
    'plugin stores compatibility range'
);
is( $installed->{plugin}{status}, 'installed', 'plugin starts installed' );
is_deeply( $installed->{plugin}{capabilities},
    ['analytics_sink'], 'plugin stores declared capabilities' );
is( scalar @{ $plugins->created }, $ONE_ROW,  'plugin row is inserted' );
is( scalar @{ $hooks->created },   $TWO_ROWS, 'plugin hooks are inserted' );
is( $hooks->created->[0]{hook_id}, 'generated-2',
    'first hook id is generated' );
is( $hooks->created->[0]{hook_name}, 'post.created', 'first hook stores name' );
is( $hooks->created->[0]{callback_name},
    'analytics.record_post', 'first hook stores callback' );
is( $hooks->created->[0]{execution_order},
    $ANALYTICS_ORDER, 'first hook stores order' );
is( $hooks->created->[0]{timeout_ms},
    $ANALYTICS_TIMEOUT_MS, 'first hook stores timeout' );
is( $hooks->created->[1]{hook_id},
    'generated-3', 'second hook id is generated' );
is( $hooks->created->[1]{side_effect_policy},
    'read_only', 'second hook defaults side-effect policy' );

my $enabled = $registry->enable('generated-1');
is( $enabled->{status}, 'enabled', 'plugin can be enabled' );
is( $plugins->find('generated-1')->get_column('status'),
    'enabled', 'plugin row stores enabled status' );

my $disabled = $registry->disable('generated-1');
is( $disabled->{status}, 'disabled', 'plugin can be disabled' );
is( $plugins->find('generated-1')->get_column('status'),
    'disabled', 'plugin row stores disabled status' );

my $rejected = $registry->install( { name => 'broken' } );
ok( !$rejected->{ok}, 'registry rejects invalid plugin manifests' );
like( $rejected->{errors}{version},
    qr/required/msx, 'registry returns manifest validation errors' );

my $failure_recorder = GPForum::Service::Plugin::FailureRecorder->new(
    schema     => $schema,
    clock      => GPForum::Test::FixedClock->new,
    id_service => GPForum::Test::Id->new,
);
my $failure = $failure_recorder->record_failure(
    {
        plugin_id     => 'generated-1',
        hook_name     => 'post.created',
        error_class   => 'timeout',
        error_message => 'callback exceeded timeout',
        context       => { payload_id => 'post-1' },
    }
);
is( $failure->{plugin_failure_id},  'generated-1', 'failure id is generated' );
is( $failure->{error_class},        'timeout',     'failure stores class' );
is( scalar @{ $failures->created }, $ONE_ROW, 'failure recorder inserts row' );

my $dispatcher = GPForum::Service::Plugin::HookDispatcher->new(
    schema           => $schema,
    failure_recorder => $failure_recorder,
    handlers         => {
        'analytics.record_post' => sub {
            my ($payload) = @_;
            return { observed_post_id => $payload->{post_id} };
        },
    },
);
my $dispatched =
  $dispatcher->dispatch( 'post.created', { post_id => 'post-1' } );
is( $dispatched->{hook_name}, 'post.created', 'dispatcher returns hook name' );
is( scalar @{ $dispatched->{results} },
    $ONE_ROW, 'dispatcher executes matching hook' );
ok( $dispatched->{results}[0]{ok}, 'registered handler succeeds' );
is( $dispatched->{results}[0]{result}{observed_post_id},
    'post-1', 'handler receives payload' );

my $missing = $dispatcher->dispatch( 'admin.panel', { panel => 'analytics' } );
is( scalar @{ $missing->{results} },
    $ONE_ROW, 'dispatcher reports missing handler' );
ok( !$missing->{results}[0]{ok}, 'missing handler is a plugin failure' );
is( scalar @{ $failures->created },
    $TWO_ROWS, 'missing handler records observable failure' );
is( $failures->created->[$SECOND_FAILURE_INDEX]{error_class},
    'missing_handler', 'missing handler failure is classified' );
ok( exists $failures->created->[$FIRST_FAILURE_INDEX]{context},
    'plugin failures store structured context' );

1;
