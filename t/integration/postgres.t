package main;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use DBI;
use English    qw(-no_match_vars);
use Mojo::JSON qw(decode_json);
use Test::Mojo;
use Test::More;

use lib 'lib';

use GPForum::Command::AdminBootstrap;
use GPForum::Command::Migrate;
use GPForum::Command::PerformanceSeed;

our $VERSION = '0.001';

const my $HTTP_OK           => 200;
const my $HTTP_ACCEPTED     => 202;
const my $HTTP_FOUND        => 302;
const my $HTTP_BAD_REQUEST  => 400;
const my $HTTP_UNAUTHORIZED => 401;
const my $HTTP_FORBIDDEN    => 403;
const my $THREAD_PAGE_LIMIT => 3;
const my $AT_SIGN           => q{@};
const my $PASSWORD          => 'correct horse battery staple';
const my $MEMBER            => 'it_member';
const my $MODERATOR         => 'it_moderator';
const my $JSON_HEADERS      => { Accept => 'application/json' };
const my $ENTITY_SELECTOR   => 'a[href^="/t/"]';
const my $POST_SELECTOR     => 'article[id^="post-"]';
const my $SEEDED_THREAD_SQL => join q{ },
  'SELECT t.thread_id, t.category_id, u.username',
  'FROM threads t JOIN users u ON u.id = t.author_user_id',
  q{WHERE t.deleted_at IS NULL AND t.visibility = 'public'},
  q{AND t.moderation_state = 'visible'},
  'ORDER BY t.last_activity_at DESC, t.thread_id DESC LIMIT 1';

if ( !$ENV{GPFORUM_DATABASE_DSN} ) {
    plan skip_all =>
      'set GPFORUM_DATABASE_DSN to run the PostgreSQL integration test';
}

# Every run migrates and seeds its own throwaway database on the configured
# server, so the shared benchmark database is never modified.
my $integration_database = _create_database( $ENV{GPFORUM_DATABASE_DSN} );
local $ENV{GPFORUM_DATABASE_DSN}              = $integration_database->{dsn};
local $ENV{GPFORUM_MINION_ENABLED}            = 0;
local $ENV{GPFORUM_REALTIME_LISTENER_ENABLED} = 0;

_prepare_database();

my $anonymous = Test::Mojo->new('GPForum');
my $seeded    = _seeded_thread($integration_database);

_public_surfaces( $anonymous, $seeded );
_register_accounts( $anonymous->app, $integration_database );
my $member_activity = _member_flow( $anonymous->app, $seeded );
_moderator_flow( $anonymous->app, $integration_database, $member_activity );

_drop_database($integration_database);

done_testing();

sub _create_database {
    my ($admin_dsn) = @_;

    if ( $admin_dsn !~ /dbname=[^;]+/msx ) {
        croak 'GPFORUM_DATABASE_DSN must name a database with dbname=';
    }

    my $name      = sprintf 'gpforum_it_%d_%d', $PROCESS_ID, time;
    my $admin_dbh = _connect($admin_dsn);
    $admin_dbh->do( 'CREATE DATABASE ' . $admin_dbh->quote_identifier($name) );

    ( my $dsn = $admin_dsn ) =~ s/dbname=[^;]+/dbname=$name/msx;

    return {
        admin_dbh => $admin_dbh,
        dbh       => _connect($dsn),
        dsn       => $dsn,
        name      => $name,
    };
}

sub _drop_database {
    my ($database_info) = @_;

    $database_info->{dbh}->disconnect;
    my $admin_dbh = $database_info->{admin_dbh};
    $admin_dbh->do( 'DROP DATABASE IF EXISTS '
          . $admin_dbh->quote_identifier( $database_info->{name} )
          . ' WITH (FORCE)' );
    $admin_dbh->disconnect;

    return;
}

sub _connect {
    my ($dsn) = @_;

    return DBI->connect(
        $dsn,
        $ENV{GPFORUM_DATABASE_USER},
        $ENV{GPFORUM_DATABASE_PASSWORD},
        { AutoCommit => 1, PrintError => 0, RaiseError => 1 },
    );
}

sub _prepare_database {
    is( _quietly( sub { GPForum::Command::Migrate->new->run('--apply') } ),
        0, 'migrations apply to a clean PostgreSQL database' );
    is(
        _quietly(
            sub {
                GPForum::Command::PerformanceSeed->new->run( '--profile',
                    'small' );
            }
        ),
        0,
        'small seed profile loads'
    );

    return;
}

sub _seeded_thread {
    my ($database_info) = @_;

    return $database_info->{dbh}->selectrow_hashref($SEEDED_THREAD_SQL);
}

sub _public_surfaces {
    my ( $client, $thread ) = @_;

    _page_has( $client, q{/},                        $ENTITY_SELECTOR );
    _page_has( $client, '/categories',               'a[href^="/c/"]' );
    _page_has( $client, "/c/$thread->{category_id}", $ENTITY_SELECTOR );
    _page_has( $client, "/t/$thread->{thread_id}",   $POST_SELECTOR );
    _thread_next_page( $client, $thread );
    _page_has( $client, '/search?q=performance', $ENTITY_SELECTOR );
    _json_has_items( $client, '/search/autocomplete?q=per' );
    _page_has( $client, "/u/$thread->{username}", 'h1' );
    _text_has( $client, '/robots.txt',  qr/Sitemap:/msx );
    _text_has( $client, '/sitemap.xml', qr{<loc>[^<]+/t/}msx );
    _text_has( $client, '/feed.atom',   qr/<entry>/msx );

    return;
}

sub _thread_next_page {
    my ( $client, $thread ) = @_;

    my $path = "/t/$thread->{thread_id}?limit=$THREAD_PAGE_LIMIT";
    $client->get_ok( $path => $JSON_HEADERS );
    $client->status_is($HTTP_OK);
    my $cursor =
      _find_key( decode_json( $client->tx->res->body ), 'next_cursor' );
    ok( $cursor, 'first thread page exposes a keyset cursor' );

    _page_has( $client, "$path&after=$cursor", $POST_SELECTOR );

    return;
}

sub _register_accounts {
    my ( $app, $database_info ) = @_;

    for my $username ( $MODERATOR, $MEMBER ) {
        my $client = Test::Mojo->new($app);
        _register( $client, $username );
        _verify_registered_email( $client, $database_info, $username );
        _login( $client, $username );
    }

    my $user_id = _user_id( $database_info, $MODERATOR );
    is(
        _quietly(
            sub {
                GPForum::Command::AdminBootstrap->new->run( '--user-id',
                    $user_id );
            }
        ),
        0,
        'moderator account receives the bootstrap moderation role'
    );

    return;
}

sub _register {
    my ( $client, $username ) = @_;

    $client->get_ok('/register');
    $client->status_is($HTTP_OK);
    $client->post_ok(
        '/register' => form => {
            command_id   => _form_value( $client, 'command_id' ),
            csrf_token   => _form_value( $client, 'csrf_token' ),
            username     => $username,
            display_name => "Integration $username",
            email        => "$username\@example.test",
            password     => $PASSWORD,
        }
    );
    $client->status_is($HTTP_ACCEPTED);

    return;
}

sub _verify_registered_email {
    my ( $client, $database_info, $username ) = @_;

    my $token = _verification_token( $database_info, $username );
    ok( $token, "verification token issued for $username" );

    $client->get_ok("/email/verify/$token");
    $client->status_is($HTTP_OK);
    $client->post_ok(
        '/email/verify/complete' => form => {
            command_id => _form_value( $client, 'command_id' ),
            csrf_token => _form_value( $client, 'csrf_token' ),
            token      => $token,
        }
    );
    $client->status_is($HTTP_ACCEPTED);

    return;
}

sub _verification_token {
    my ( $database_info, $username ) = @_;

    my $email = "$username\@example.test";
    my ($token) = $database_info->{dbh}->selectrow_array(
        join( q{ },
            q{SELECT payload->'mail'->>'token'},
            'FROM outbox_messages',
            q{WHERE payload->'mail'->>'kind' = 'email_verification'},
            q{AND payload->'mail'->>'to' = ?},
            'ORDER BY created_at DESC LIMIT 1' ),
        undef, $email
    );

    return defined $token ? $token : q{};
}

sub _login {
    my ( $client, $username ) = @_;

    $client->get_ok('/login');
    $client->status_is($HTTP_OK);
    $client->post_ok(
        '/login' => form => {
            command_id => _form_value( $client, 'command_id' ),
            csrf_token => _form_value( $client, 'csrf_token' ),
            identifier => $username,
            password   => $PASSWORD,
        }
    );
    $client->status_is($HTTP_ACCEPTED);
    $client->element_exists('form[action="/logout"]');

    return;
}

sub _logout {
    my ($client) = @_;

    $client->get_ok('/settings');
    $client->post_ok(
        '/logout' => form => {
            command_id => _form_value( $client, 'command_id' ),
            csrf_token => _form_value( $client, 'csrf_token' ),
        }
    );
    $client->get_ok('/bookmarks');
    $client->status_is($HTTP_UNAUTHORIZED);

    return;
}

sub _member_flow {
    my ( $app, $seeded_thread ) = @_;

    my $client = Test::Mojo->new($app);
    _login( $client, $MEMBER );

    my $thread_id = _create_thread( $client, $seeded_thread->{category_id} );
    my $post_id   = _create_reply( $client, $thread_id );
    _community_actions( $client, $thread_id, $post_id );
    _personal_pages($client);
    _logout($client);

    return { thread_id => $thread_id, post_id => $post_id };
}

sub _create_thread {
    my ( $client, $category_id ) = @_;

    $client->get_ok("/new-thread?category_id=$category_id");
    $client->status_is($HTTP_OK);
    $client->post_ok(
        '/threads' => form => {
            csrf_token  => _form_value( $client, 'csrf_token' ),
            command_id  => _form_value( $client, 'command_id' ),
            category_id => $category_id,
            title       => 'Integration thread about performance',
            body_source => 'Opening post written by the integration test',
            visibility  => 'public',
        }
    );
    $client->status_is($HTTP_FOUND);
    my ($thread_id) = _location($client) =~ m{/t/([^/?#]+)}msx;
    ok( $thread_id, 'thread creation redirects to the new thread' );

    $client->get_ok("/t/$thread_id");
    $client->status_is($HTTP_OK);
    $client->content_like(qr/Integration [ ] thread [ ] about/msx);

    return $thread_id;
}

sub _create_reply {
    my ( $client, $thread_id ) = @_;

    my $post_id = _reply( $client, $thread_id,
        'A reply that mentions ' . $AT_SIGN . $MODERATOR );
    $client->status_is($HTTP_FOUND);
    ok( $post_id, 'reply redirects to the new post anchor' );

    $client->get_ok("/t/$thread_id");
    $client->status_is($HTTP_OK);
    $client->element_exists("article[id=\"post-$post_id\"]");

    return $post_id;
}

sub _reply {
    my ( $client, $thread_id, $body ) = @_;

    $client->get_ok("/t/$thread_id");
    $client->post_ok(
        "/t/$thread_id/replies" => form => {
            csrf_token  => _form_value( $client, 'csrf_token' ),
            command_id  => _form_value( $client, 'command_id' ),
            body_source => $body,
            visibility  => 'public',
        }
    );
    my ($post_id) = _location($client) =~ /\#post-(.+)\z/msx;

    return $post_id;
}

sub _community_actions {
    my ( $client, $thread_id, $post_id ) = @_;

    my %forms = (
        "/t/$thread_id/bookmark"  => { note => 'Integration bookmark' },
        "/t/$thread_id/subscribe" => {},
        "/p/$post_id/report"      =>
          { reason => 'spam', details => 'Integration report' },
    );
    for my $path ( sort keys %forms ) {
        _post_form( $client, "/t/$thread_id", $path, $forms{$path} );
        _status_below( $client, $HTTP_BAD_REQUEST, "$path succeeds" );
    }

    _page_has( $client, '/bookmarks', "a[href^=\"/t/$thread_id\"]" );

    return;
}

sub _personal_pages {
    my ($client) = @_;

    for my $path (qw(/notifications /mentions /feed /settings)) {
        _page_has( $client, $path, 'main' );
    }

    return;
}

sub _moderator_flow {
    my ( $app, $database_info, $activity ) = @_;

    my $client = Test::Mojo->new($app);
    _login( $client, $MODERATOR );

    _page_has( $client, '/mentions',      'main li' );
    _page_has( $client, '/notifications', 'main li' );

    _moderate_post( $client, $activity );
    _moderate_thread( $client, $activity->{thread_id} );
    _moderate_user( $client, _user_id( $database_info, $MEMBER ) );
    _logout($client);

    return;
}

sub _moderate_post {
    my ( $client, $activity ) = @_;

    my $post_path   = "/moderation/posts/$activity->{post_id}";
    my $thread_path = "/t/$activity->{thread_id}";
    my $post_anchor = "article[id=\"post-$activity->{post_id}\"]";

    _moderation_action( $client, "$post_path/hide" );
    $client->get_ok($thread_path);
    $client->element_exists_not($post_anchor);

    _moderation_action( $client, "$post_path/restore" );
    $client->get_ok($thread_path);
    $client->element_exists($post_anchor);

    return;
}

sub _moderate_thread {
    my ( $client, $thread_id ) = @_;

    my $thread_path = "/moderation/threads/$thread_id";

    _moderation_action( $client, "$thread_path/lock" );
    $client->get_ok("/t/$thread_id");
    $client->status_is($HTTP_OK);
    $client->content_like(qr/This [ ] thread [ ] is [ ] locked/msx);
    _reply( $client, $thread_id, 'Reply attempt on a locked thread' );
    $client->status_is($HTTP_FORBIDDEN);

    _moderation_action( $client, "$thread_path/unlock" );
    $client->get_ok("/t/$thread_id");
    $client->content_unlike(qr/This [ ] thread [ ] is [ ] locked/msx);
    _reply( $client, $thread_id, 'Reply after the thread is unlocked' );
    $client->status_is($HTTP_FOUND);

    return;
}

sub _moderate_user {
    my ( $client, $member_user_id ) = @_;

    _moderation_action( $client, "/moderation/users/$member_user_id/suspend" );
    $client->get_ok('/moderation/suspensions');
    $client->status_is($HTTP_OK);
    my ($suspension_id) =
      $client->tx->res->body =~ m{/moderation/suspensions/([^/"]+)/revoke}msx;
    ok( $suspension_id, 'suspension is listed with a revoke action' );

    _moderation_action( $client,
        "/moderation/suspensions/$suspension_id/revoke" );
    $client->get_ok('/moderation/suspensions');
    $client->element_exists_not(
        "form[action=\"/moderation/suspensions/$suspension_id/revoke\"]");

    return;
}

sub _moderation_action {
    my ( $client, $path ) = @_;

    _post_form( $client, '/moderation/reports', $path,
        { reason => 'Integration moderation' } );
    _status_below( $client, $HTTP_BAD_REQUEST, "$path succeeds" );

    return;
}

sub _post_form {
    my ( $client, $form_page, $path, $fields ) = @_;

    $client->get_ok($form_page);
    my $command_id = _form_command_id( $client, $path );
    if ( !length $command_id ) {
        $command_id = $client->app->gp_id->uuid;
    }
    $client->post_ok(
        $path => form => {
            command_id => $command_id,
            csrf_token => _form_value( $client, 'csrf_token' ),
            %{$fields},
        }
    );

    return;
}

sub _status_below {
    my ( $client, $limit, $name ) = @_;

    my $code = $client->tx->res->code;
    ok( $code < $limit, $name ) or diag "HTTP status $code";

    return;
}

sub _user_id {
    my ( $database_info, $username ) = @_;

    my ($user_id) =
      $database_info->{dbh}
      ->selectrow_array( 'SELECT id FROM users WHERE username = ?',
        undef, $username );

    return $user_id;
}

sub _page_has {
    my ( $client, $path, $selector ) = @_;

    $client->get_ok($path);
    $client->status_is($HTTP_OK);
    $client->element_exists($selector);

    return;
}

sub _text_has {
    my ( $client, $path, $pattern ) = @_;

    $client->get_ok($path);
    $client->status_is($HTTP_OK);
    $client->content_like($pattern);

    return;
}

sub _json_has_items {
    my ( $client, $path ) = @_;

    $client->get_ok( $path => $JSON_HEADERS );
    $client->status_is($HTTP_OK);
    my $payload = decode_json( $client->tx->res->body );
    my $items =
         _find_key( $payload, 'suggestions' )
      || _find_key( $payload, 'results' )
      || [];
    ok( scalar @{$items}, "$path returns items" );

    return;
}

sub _find_key {
    my ( $data, $key ) = @_;

    if ( ref $data ne 'HASH' ) {
        return;
    }
    if ( defined $data->{$key} ) {
        return $data->{$key};
    }

    for my $value ( values %{$data} ) {
        my $found = _find_key( $value, $key );
        if ( defined $found ) {
            return $found;
        }
    }

    return;
}

sub _location {
    my ($client) = @_;

    my $headers = $client->tx->res->headers;

    return $headers->location || q{};
}

sub _form_value {
    my ( $client, $name ) = @_;

    my $body = $client->tx->res->body;
    my ($value) = $body =~ /name="\Q$name\E" [^>]+ value="([^"]+)"/msx;

    return defined $value ? $value : q{};
}

sub _form_command_id {
    my ( $client, $form_action ) = @_;

    const my $FORM_SNIPPET => 800;
    my $body   = $client->tx->res->body;
    my $quote  = q{"};
    my $marker = 'action=' . $quote . $form_action . $quote;
    my $start  = index $body, $marker;
    if ( $start < 0 ) {
        return q{};
    }

    my $chunk        = substr $body, $start, $FORM_SNIPPET;
    my ($command_id) = $chunk =~ /name="command_id" [^>]+ value="([^"]+)"/msx;

    return defined $command_id ? $command_id : q{};
}

sub _quietly {
    my ($code) = @_;

    my $output = q{};
    open my $handle, '>', \$output
      or croak 'failed to open output capture';
    my $status = do {
        local *STDOUT = $handle;
        $code->();
    };
    close $handle or croak 'failed to close output capture';

    return $status;
}

1;
