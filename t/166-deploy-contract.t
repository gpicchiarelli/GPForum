# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package main;

use v5.40;

use Carp qw(croak);
use Const::Fast;
use English    qw(-no_match_vars);
use File::Temp qw(tempdir);
use IPC::Open3 qw(open3);
use Mojo::File qw(path);
use Test::More;

use lib 'lib';

use GPForum::Service::Operations::DeployContract qw(
  deploy_host_unit_checks
  deploy_match_text
  deploy_nginx_checks
  deploy_unit_checks
);

our $VERSION = '0.001';

const my $EXPECTED_TESTS => 35;

const my $FRESH_CHECK  => 'script/fresh-checkout-check';
const my $EXIT_FAILURE => 1;
const my $USAGE_ERROR  => 2;
const my $STATUS_SHIFT => 8;
const my $EXECUTABLE   => oct '0755';

# A DSN no step may connect to: the runs below skip every step that would.
const my $UNREACHABLE_DSN => 'dbi:Pg:dbname=postgres;host=203.0.113.1;port=1';

# The same server in DBD::Pg's other spellings, which the throwaway
# database's DSN is derived from.
const my $SPELLED_DSN    => 'dbi:Pg:database=postgres; host=203.0.113.1;port=1';
const my $SERVER_PAIRS   => qr/host=203[.]0[.]113[.]1;port=1/msx;
const my $THROWAWAY_NAME => qr/gpforum_fresh_\d+_\d+/msx;
const my $THROWAWAY_DSN =>
  qr/\A dbi:Pg:$SERVER_PAIRS;dbname=($THROWAWAY_NAME) \z/msx;

# Quick start lines the run does not repeat, because they install or inspect
# the host. The script's usage says they must be done first.
const my $HOST_PREREQUISITE => qr/\A (?: sudo | which ) \s/msx;

# The steps that would need a real host or server, left out of the runs that
# drive the script with a stand-in `make`. The migrations run, against a
# stand-in Carton that records what it was given.
const my @NEEDS_A_HOST => map { ( '--skip', $_ ) }
  qw(system-preflight createuser createdb);
const my @MIGRATE_CALLS =>
  map { "carton exec perl -Ilib bin/gpforum-migrate $_" } qw(--plan --apply);

plan tests => $EXPECTED_TESTS;

ok( scalar( deploy_unit_checks() ) >= 4,  'unit contracts cover core units' );
ok( scalar( deploy_nginx_checks() ) >= 2, 'nginx contracts cover tcp+unix' );
is( scalar( deploy_host_unit_checks() ),
    3, 'host unit observe covers web+outbox+scheduled-jobs' );

my @host_names = map { $_->{name} } deploy_host_unit_checks();
ok(
    ( grep { $_ eq 'gpforum-scheduled-jobs.service' } @host_names ),
    'host observe includes scheduled-jobs service contract'
);

my $web = path('deploy/systemd/gpforum.service')->slurp;
my $web_match =
  deploy_match_text( $web, ( deploy_host_unit_checks() )[0] );
is( $web_match->{status}, 'pass', 'repo gpforum.service matches contract' );

my $nginx = path('deploy/nginx/gpforum.conf')->slurp;
my $nginx_match =
  deploy_match_text( $nginx, ( deploy_nginx_checks() )[0] );
is( $nginx_match->{status}, 'pass', 'repo gpforum.conf matches contract' );

my $bad = deploy_match_text( "User=root\n", ( deploy_host_unit_checks() )[0] );
is( $bad->{status}, 'fail', 'broken unit text fails contract' );
ok( @{ $bad->{missing_labels} } >= 1, 'broken unit reports missing labels' );

unlike(
    path('lib/GPForum/Service/Operations/DeployChecklistDrill.pm')->slurp,
    qr/const my \@UNIT_CHECKS/msx,
    'deploy checklist no longer owns UNIT_CHECKS'
);
unlike(
    path('lib/GPForum/Service/Operations/StagingHostVerify.pm')->slurp,
    qr/const my \@UNIT_FILE_CONTRACTS/msx,
    'staging-host verify no longer owns UNIT_FILE_CONTRACTS'
);
like(
    path('lib/GPForum/Service/Operations/StagingHostVerify.pm')->slurp,
    qr/deploy_nginx_checks|nginx_conf/msx,
    'staging-host verify uses shared nginx contracts'
);

# ExecReload was byte-identical to ExecStart, and running hypnotoad against a
# live instance is its hot-deploy path: the new manager sends QUIT to the old
# one, so systemd -- which reads PIDFile once at start -- was left tracking a
# dead process and the reload killed the service. `kill -USR2` is that same hot
# deploy, so there is nothing correct to put in ExecReload at all.
for my $unit (qw(gpforum.service gpforum-unix-socket.service)) {
    my $text = path("deploy/systemd/$unit")->slurp;
    like( $text, qr/^Type=forking$/msx, "$unit still forks" );
    unlike( $text, qr/^ExecReload=/msx,
        "$unit declares no ExecReload, so reload cannot kill it" );
}

# ADR 0050 requires operators to run WAL archiving and PITR. The repository
# used to state that and ship nothing to meet it; these keep the drill and the
# runbook from drifting apart from the requirement.
ok( -x 'script/pitr-drill', 'the point-in-time recovery drill is executable' );
my $drill = path('script/pitr-drill')->slurp;
for my $setting (
    qw(wal_level archive_mode archive_command restore_command
    recovery_target_time)
  )
{
    like( $drill, qr/\Q$setting\E/msx, "the drill exercises $setting" );
}

# ADR 0112: the standby, the multi-host DSN the application connects with,
# and a drill that holds the application's own connection across a failover.
ok( -x 'script/standby-drill', 'the standby and failover drill is executable' );
my $standby_drill = path('script/standby-drill')->slurp;
for my $step (
    qw(pg_create_physical_replication_slot target_session_attrs=read-write
    promote GPForum::Schema)
  )
{
    like( $standby_drill, qr/\Q$step\E/msx,
        "the standby drill exercises $step" );
}
like(
    path('docs/ops/standby-and-failover.md')->slurp,
    qr/target_session_attrs=read-write/msx,
    'the failover runbook gives the multi-host DSN'
);

my $runbook = path('docs/ops/backup-and-restore.md')->slurp;
like( $runbook, qr/recovery_target_time/msx,
    'the runbook names the recovery target setting' );
like(
    $runbook,
    qr/attachment \s root/msx,
    'the runbook says attachments are outside the database backup'
);

# The README quick start is the one document nothing else executes: every gate
# runs in a checkout that is already set up. script/fresh-checkout-check runs
# it in a clone. These keep the script, the README and the Makefile in step,
# and drive the script with a stand-in `make`, so its own behaviour is proved
# without the minutes a real dependency install takes.
subtest 'the fresh-checkout check is wired in and documented' =>
  \&_fresh_checkout_wiring;
subtest 'the run is the README quick start, then make check' =>
  \&_fresh_checkout_plan;
subtest 'every step runs in a clone of HEAD, with nothing carried over' =>
  \&_fresh_checkout_isolation;
subtest 'a failing step stops the run, and --keep keeps its log' =>
  \&_fresh_checkout_failure;
subtest 'no step runs outside the clone, even once the clone is gone' =>
  \&_fresh_checkout_gone;
subtest 'a usage error stops it before anything is cloned' =>
  \&_fresh_checkout_usage;

sub _fresh_checkout_wiring {
    ok( -x $FRESH_CHECK, 'the fresh-checkout check is executable' );
    my $makefile = path('Makefile')->slurp;
    like(
        $makefile,
        qr/^fresh-checkout:[^\n]*\n\tscript\/fresh-checkout-check\n/msx,
        'make fresh-checkout runs it'
    );
    my ($check_line) = $makefile =~ /^(check:[^\n]*)/msx;
    unlike( $check_line // q{},
        qr/fresh-checkout/msx,
        'make check does not: it installs every dependency again' );

    # The run makes each prerequisite of check, one at a time; a recipe of
    # check's own would be the one part of make check it never ran.
    unlike( $makefile, qr/^check:[^\n]*\n\t/msx,
        'make check is its prerequisites alone, so the run covers all of it' );
    like(
        _quick_start( path('README.md')->slurp ),
        qr/make [ ] fresh-checkout/msx,
        'the README quick start names it'
    );
    like(
        path('CONTRIBUTING.md')->slurp,
        qr/make [ ] fresh-checkout/msx,
        'CONTRIBUTING says when to run it'
    );

    return;
}

sub _fresh_checkout_plan {
    if ( !_in_git_checkout() ) {
        plan skip_all => 'not a git checkout: there is no commit to clone';
        return;
    }
    local $ENV{MAKE}                  = 'make';
    local $ENV{GPFORUM_DATABASE_DSN}  = $UNREACHABLE_DSN;
    local $ENV{GPFORUM_DATABASE_USER} = 'gpforum';
    my ( $status, $plan ) = _run( $FRESH_CHECK, '--plan' );
    is( $status, 0, '--plan succeeds' ) or diag $plan;
    my @steps      = _plan_steps($plan);
    my %command_of = map { @{$_} } @steps;
    my @names      = map { $_->[0] } @steps;

    my @positions;
    my @readme_commands = grep { $_ !~ $HOST_PREREQUISITE }
      _quick_start_commands( path('README.md')->slurp );
    for my $command (@readme_commands) {
        my ($position) =
          grep { _same_step( $command, @{ $steps[$_] } ) } 0 .. $#steps;
        ok( defined $position, "the run includes the quick start's $command" );
        push @positions, $position // ();
    }
    is_deeply(
        \@positions,
        [ sort { $a <=> $b } @positions ],
        'in the order the README gives them'
    );

    for my $target ( 'system-perl', _check_targets() ) {
        is( $command_of{$target}, "make $target",
            "the run includes make check's $target" );
    }
    is_deeply( [ @names[ $#names - 1, $#names ] ],
        [qw(integration dropdb)],
        'with a DSN the integration tier runs last, then the database goes' );

    local $ENV{GPFORUM_DATABASE_DSN} = q{};
    my ( undef, $bare ) = _run( $FRESH_CHECK, '--plan' );
    is_deeply(
        [
            grep {
/\A (?: createuser | createdb | migrate- | integration | dropdb )/msx
            }
            map { $_->[0] } _plan_steps($bare)
        ],
        [],
        'without a DSN no step needs a database'
    );

    return;
}

sub _fresh_checkout_isolation {
    if ( !_in_git_checkout() ) {
        plan skip_all => 'not a git checkout: there is no commit to clone';
        return;
    }
    my $stand_in = _stand_in();
    local @ENV{qw(MAKE GPFORUM_CARTON TMPDIR STAND_IN_RECORD)} =
      @{$stand_in}{qw(make carton tmp record)};
    local $ENV{PERL5LIB}              = '/nonexistent/perl5lib';
    local $ENV{GPFORUM_LEFTOVER}      = 'from the working shell';
    local $ENV{GPFORUM_DATABASE_DSN}  = $SPELLED_DSN;
    local $ENV{GPFORUM_DATABASE_USER} = 'gpforum';

    # What `make -i fresh-checkout` hands its recipe: every inner make would
    # ignore its errors, and a failing test tier would pass.
    local @ENV{qw(MAKEFLAGS MFLAGS MAKELEVEL)} = qw(i -i 1);
    local $ENV{HARNESS_PERL_SWITCHES}          = '-I/nonexistent/harness';
    local $ENV{PERL_CARTON_MIRROR}             = 'file:///nonexistent/mirror';
    my ( $status, $output ) = _run( $FRESH_CHECK, @NEEDS_A_HOST );
    is( $status, 0, 'every step passed' ) or diag $output;
    like(
        $output,
        qr/^fresh-checkout-check [ ] status=pass [ ] commit=/msx,
        'and the run says so'
    );
    like(
        $output,
        qr/does [ ] not [ ] prove [ ] a [ ] green [ ] make [ ] check/msx,
        'and that, with steps left out, it proves less than make check'
    );

    my @calls = _calls($stand_in);
    is_deeply(
        [ map { $_->{target} } @calls ],
        [
            qw(system-perl install-deps-postgres), @MIGRATE_CALLS,
            _check_targets(),                      'integration'
        ],
        'the quick start, then make check, then the integration tier'
    );
    my $inside = path( $stand_in->{tmp} )->realpath;
    is_deeply( [ grep { index( $_->{cwd}, "$inside/" ) != 0 } @calls ],
        [], 'every step ran inside the temporary directory, none here' );
    my ( undef, $head ) = _run( 'git', 'rev-parse', 'HEAD' );
    is_deeply( [ grep { $_->{head} ne $head } @calls ],
        [], 'in a checkout of HEAD' );
    is_deeply(
        [ grep { $_->{perl5lib} ne q{} || $_->{leftover} ne q{} } @calls ],
        [], 'with neither PERL5LIB nor a GPFORUM_ setting carried over' );
    is_deeply(
        [
            map  { "$_->{target}:$_->{carried}" }
            grep { $_->{carried} ne q{} } @calls
        ],
        [],
        'nor make flags, harness switches or a CPAN mirror'
    );
    is_deeply(
        [ grep { index( $_->{cpanm_home}, "$stand_in->{tmp}/" ) != 0 } @calls ],
        [],
        'and with cpanm building inside the temporary directory'
    );

    my %call_to     = map { $_->{target} => $_ } @calls;
    my @migrations  = map { $call_to{$_} // {} } @MIGRATE_CALLS;
    my ($throwaway) = ( $migrations[0]{dsn} // q{} ) =~ $THROWAWAY_DSN;
    ok(
        defined $throwaway,
        'the migrations run on a throwaway database on the server the DSN names'
    ) or diag explain \@migrations;
    is_deeply(
        [ map { [ $_->{dsn},           $_->{user} ] } @migrations ],
        [ map { [ $migrations[0]{dsn}, $throwaway ] } @MIGRATE_CALLS ],
        'both as the throwaway role of the same name'
    );
    like(
        $migrations[1]{password} // q{},
        qr/\A [[:alnum:]]{32} \z/msx,
        'which has a password of its own'
    );
    is_deeply(
        [
            map  { "$_->{target} $_->{dsn} $_->{user}" }
            grep { $_->{dsn} ne q{} && $_->{target} !~ /\A carton [ ]/msx }
              @calls
        ],
        ["integration $SPELLED_DSN gpforum"],
        'only the integration tier is given the DSN itself'
    );
    is( _left_behind($stand_in), 0,
        'and the temporary directory is removed afterwards' );

    return;
}

sub _fresh_checkout_failure {
    if ( !_in_git_checkout() ) {
        plan skip_all => 'not a git checkout: there is no commit to clone';
        return;
    }
    my $stand_in = _stand_in();
    local @ENV{qw(MAKE TMPDIR STAND_IN_RECORD)} =
      @{$stand_in}{qw(make tmp record)};
    local $ENV{GPFORUM_DATABASE_DSN} = q{};
    local $ENV{STAND_IN_FAIL}        = 'test';
    my ( $status, $output ) =
      _run( $FRESH_CHECK, '--skip', 'system-preflight' );
    is( $status, $EXIT_FAILURE, 'the run fails' );
    like( $output, qr/^[ ]+test[ ]+fail[ ]/msx, 'naming the step' );
    like( $output, qr/status=fail/msx,          'and saying it did not pass' );
    my @targets = map { $_->{target} } _calls($stand_in);
    is( $targets[-1], 'test', 'nothing runs after the failing step' );
    is( _left_behind($stand_in), 0,
        'and the temporary directory is still removed' );

    _run( $FRESH_CHECK, '--keep', '--skip', 'system-preflight' );
    my ($kept) = path( $stand_in->{tmp} )->list( { dir => 1 } )->each;
    ok( $kept && -f $kept->child( 'logs', 'test.log' ),
        '--keep keeps one log per step' );
    ok( $kept && -d $kept->child( 'gpforum', '.git' ), 'and the clone' );

    my $calls_before = () = _calls($stand_in);
    my ( $going, $going_output ) =
      _run( $FRESH_CHECK, '--keep-going', '--skip', 'system-preflight' );
    my @going = map { $_->{target} } _calls($stand_in);
    is( $going, $EXIT_FAILURE, '--keep-going still fails the run' );
    is_deeply(
        [ @going[ $calls_before .. $#going ] ],
        [ 'system-perl', 'install-deps-postgres', _check_targets() ],
        'but runs every step after the failing one'
    );
    like(
        $going_output,
        qr/status=fail [ ] commit=\S+ [ ] steps=\d+ [ ] failed=test [ ]/msx,
        'and names the step that failed'
    );

    return;
}

# A step runs in a subshell that changes into the clone first. Should that
# fail, the step would run wherever the script is: in this checkout, where
# install-deps-postgres writes local/.
sub _fresh_checkout_gone {
    if ( !_in_git_checkout() ) {
        plan skip_all => 'not a git checkout: there is no commit to clone';
        return;
    }
    my $stand_in = _stand_in();
    local @ENV{qw(MAKE TMPDIR STAND_IN_RECORD)} =
      @{$stand_in}{qw(make tmp record)};
    local $ENV{GPFORUM_DATABASE_DSN} = q{};
    local $ENV{STAND_IN_REMOVE}      = 'install-deps-postgres';
    my ( $status, $output ) =
      _run( $FRESH_CHECK, '--keep-going', '--skip', 'system-preflight' );
    is( $status, $EXIT_FAILURE, 'the run fails once the clone is gone' );
    like( $output, qr/failed=syntax,/msx, 'at the first step after it' );

    my @calls  = _calls($stand_in);
    my $inside = path( $stand_in->{tmp} )->realpath;
    is_deeply( [ grep { index( $_->{cwd}, "$inside/" ) != 0 } @calls ],
        [], 'and not one step ran anywhere else' );
    is_deeply(
        [ map { $_->{target} } @calls ],
        [qw(system-perl install-deps-postgres)],
        'none ran at all after the clone went'
    );
    is( _left_behind($stand_in), 0, 'and the temporary directory is removed' );

    return;
}

sub _fresh_checkout_usage {
    if ( !_in_git_checkout() ) {
        plan skip_all => 'not a git checkout: there is no commit to clone';
        return;
    }
    my $stand_in = _stand_in();
    local @ENV{qw(MAKE TMPDIR STAND_IN_RECORD)} =
      @{$stand_in}{qw(make tmp record)};

    # Each case: what it is, the DSN, and the arguments.
    my @refused = (
        [ 'a misspelt --skip', q{}, '--skip', 'tset' ],

        # A --skip naming no step runs the step it meant to leave out, so it
        # must match a step's name exactly, never as a pattern.
        [
            'a --skip that only matches as a pattern',
            q{}, qw(--plan --skip te.t)
        ],
        [ 'an unknown commit',        q{}, '--ref', 'no-such-commit' ],
        [ 'an unknown option',        q{},                         '--fast' ],
        [ 'a value left out',         q{},                         '--ref' ],
        [ 'a DSN for another driver', 'dbi:SQLite:dbname=gpforum', '--plan' ],
    );
    for my $refusal (@refused) {
        my ( $case, $dsn, @arguments ) = @{$refusal};
        local $ENV{GPFORUM_DATABASE_DSN} = $dsn;
        my ( $status, $output ) = _run( $FRESH_CHECK, @arguments );
        is( $status, $USAGE_ERROR, "$case is a usage error" )
          or diag $output;
    }
    local $ENV{GPFORUM_DATABASE_DSN} = q{};
    my ( undef, $glob ) = _run( $FRESH_CHECK, qw(--plan --skip *) );
    like(
        $glob,
        qr/--skip [ ] [*] [ ] names [ ] no [ ] step/msx,
        'a --skip is never expanded against the files in this checkout'
    );
    _run( $FRESH_CHECK, '--plan' );
    my @calls = _calls($stand_in);
    is( scalar @calls, 0, 'no step ran' );
    is( _left_behind($stand_in), 0,
        'and no temporary directory was made, not even by --plan' );

    return;
}

sub _in_git_checkout {
    my ($status) = _run( 'git', 'rev-parse', '--verify', '--quiet', 'HEAD' );
    return $status == 0;
}

# The quick start section of the README, up to the next heading.
sub _quick_start {
    my ($readme) = @_;
    my ($section) =
      $readme =~ /^[#]{2} [ ] Quick [ ] start\n(.*?)^[#]{2} [ ]/msx;
    return $section // q{};
}

# The commands of the quick start's first shell block, without comments.
sub _quick_start_commands {
    my ($readme) = @_;
    my ($block)  = _quick_start($readme) =~ /^```sh\n(.*?)^```/msx;
    my @lines    = map { s/\A \s+//msxr =~ s/\s+ [#] .* \z//msxr }
      split /\n/msx, $block // q{};
    return grep { $_ ne q{} && !/\A [#]/msx } @lines;
}

# Whether a step of the plan is the README's command. The README's createuser
# and createdb make the application's role and database; the run's make a
# throwaway pair on the server the DSN names.
sub _same_step {
    my ( $command, $name, $step_command ) = @_;
    my ($client) = $command =~ /\A (createuser|createdb) \s/msx;
    if ( defined $client ) {
        return $name eq $client;
    }
    return $step_command eq $command;
}

# The "  name  command" lines --plan prints, as [name, command] pairs.
sub _plan_steps {
    my ($plan) = @_;
    return map { /\A [ ]{2} (\S+) [ ]+ (\S.*) \z/msx ? [ $1, $2 ] : () }
      split /\n/msx, $plan;
}

# make check's prerequisites at HEAD, after the system-perl the quick start
# has already run.
sub _check_targets {
    my ( undef, $makefile ) = _run( 'git', 'show', 'HEAD:Makefile' );
    my ($prerequisites) = $makefile =~ /^check:([^#\n]*)/msx;
    return grep { $_ ne 'system-perl' } split q{ }, $prerequisites // q{};
}

# A `make` that records each call -- the target, where it ran, and what the
# environment held -- instead of building anything, and a Carton that does the
# same for `carton exec ...`; STAND_IN_FAIL names a target it fails, and
# STAND_IN_REMOVE one after which it deletes the directory it ran in. The
# caller points TMPDIR at a directory of the test's own, so what the script
# leaves behind there can be counted.
sub _stand_in {
    my $scratch = path( tempdir( CLEANUP => 1 ) );
    my %tool;
    for my $name (qw(make carton)) {
        $tool{$name} = $scratch->child($name);
        $tool{$name}->spew(<<'STAND_IN');
#!/bin/sh
case "${0##*/}" in
    carton) target="carton $*" ;;
    *) target=$1 ;;
esac
carried=''
for name in MAKEFLAGS MFLAGS MAKELEVEL HARNESS_PERL_SWITCHES PERL_CARTON_MIRROR; do
    eval "value=\${$name-}"
    [ -z "$value" ] || carried="$carried $name=$value"
done
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$target" "$(pwd -P)" \
    "$(git rev-parse HEAD 2>/dev/null)" "${PERL5LIB-}" "${GPFORUM_LEFTOVER-}" \
    "${GPFORUM_DATABASE_DSN-}" "${PERL_CPANM_HOME-}" \
    "${GPFORUM_DATABASE_USER-}" "${GPFORUM_DATABASE_PASSWORD-}" "$carried" \
    >> "$STAND_IN_RECORD"
[ "$target" != "${STAND_IN_FAIL-}" ] || exit 1
if [ "$target" = "${STAND_IN_REMOVE-}" ]; then
    rm -rf "$(pwd -P)"
fi
STAND_IN
        chmod $EXECUTABLE, "$tool{$name}"
          or croak "chmod $tool{$name}: $ERRNO";
    }
    return {
        make   => "$tool{make}",
        carton => "$tool{carton}",
        tmp    => $scratch->child('tmp')->make_path->to_string,
        record => $scratch->child('calls')->to_string,
    };
}

sub _calls {
    my ($stand_in) = @_;
    my @fields =
      qw(target cwd head perl5lib leftover dsn cpanm_home user password carried);
    if ( !-f $stand_in->{record} ) {
        return;
    }
    return map { _call( \@fields, $_ ) } split /\n/msx,
      path( $stand_in->{record} )->slurp;
}

# One recorded call, as a hash of the fields the stand-in wrote.
sub _call {
    my ( $fields, $line ) = @_;
    my %call;
    @call{ @{$fields} } = split /\t/msx, $line, scalar @{$fields};
    return \%call;
}

sub _left_behind {
    my ($stand_in) = @_;
    return path( $stand_in->{tmp} )->list( { dir => 1, hidden => 1 } )->size;
}

# Runs a command without a shell and returns its exit status and its combined
# output, without the trailing newline.
sub _run {
    my (@command) = @_;

    my $pid = open3( my $input, my $output, undef, @command );
    close $input or croak "close child input: $ERRNO";
    my $text = do {
        local $INPUT_RECORD_SEPARATOR = undef;
        <$output>;
    };
    waitpid $pid, 0;
    my $status = $CHILD_ERROR >> $STATUS_SHIFT;
    $text //= q{};
    chomp $text;
    return ( $status, $text );
}

1;
