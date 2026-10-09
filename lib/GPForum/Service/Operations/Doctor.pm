# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Service::Operations::Doctor;

use Const::Fast;
use List::Util qw(any);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

use GPForum::Config;
use GPForum::Config::Report;
use GPForum::Migration::Plan;
use GPForum::Migration::Runner;
use GPForum::OS::Preflight;
use GPForum::OS::RuntimePolicy;
use GPForum::Runtime;
use GPForum::Schema;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::AntivirusCheck;
use GPForum::Service::Operations::CacheFactory;
use GPForum::Service::Operations::DatabaseFailure;
use GPForum::Service::Admin::Settings;
use GPForum::Service::Operations::Dependencies;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::HttpProbe;
use GPForum::Service::Operations::MailCheck;
use GPForum::Service::Operations::OSPreflight;
use GPForum::Service::Operations::QueryBudget;
use GPForum::Service::Operations::Readiness;
use GPForum::Service::Operations::ReadinessFindings;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::Service::Operations::ServiceUnits;
use GPForum::X::Config;

our $VERSION = '0.001';

# `gpforum doctor`: every check an operator would otherwise run by hand --
# the settings, the host, the database and its schema, the readiness report,
# the outbox worker, mail, the antivirus, the installed service files and
# timers, and the public address -- each written as one line, and under each
# problem the variable, the file and the command that fix it (audit 5.2,
# item B3). It reuses what each check already says: the configuration's own
# problems, DatabaseFailure's sentences, the readiness report, mail-check's
# and antivirus-check's findings, os-preflight's, and ServiceUnits' look at
# the installed service files. With upgrade, it checks what an upgrade can
# leave behind instead: dependencies for this Perl, pending migrations,
# service files that differ from the release's and services still running
# the code before it (item C4).

# The readiness checks doctor reports through checks of its own, which say
# more: the database and the tables the migrations make, the budgets, the
# host, and the antivirus.
const my @COVERED => qw(
  antivirus database endpointquerybudget eventlog os_preflight outboxmessage
  projectiongeneration query_budget_drift
);

# A message waits for the outbox worker this long before doctor says nobody
# is sending: the worker looks every 5 seconds.
const my $OUTBOX_PATIENCE => 300;

# The secrets `gpforum secret rotate` writes into the environment file.
const my %ROTATES => (
    GPFORUM_METRICS_TOKEN  => 'metrics',
    GPFORUM_SESSION_SECRET => 'session',
);

# The names RFC 2606 keeps for examples, which no DNS will ever point at a
# forum: the template's https://forum.example.com left as copied.
const my $EXAMPLE_HOST =>
qr/(?: \A | [.] ) (?: example [.] (?: com | net | org ) | example | invalid ) \z/msxi;

const my $HTTP_OK_MIN => 200;
const my $HTTP_OK_MAX => 399;
const my $LIVE_PATH   => '/health/live';
const my $FIRST_LINE  => qr/\A ([^\n]*)/msx;
const my $CHECKOUT_UP => 5;
const my $HIDDEN      => '(hidden)';

# What every other account on the host may do with a file, and where stat
# puts the mode.
const my $OTHERS_BITS => oct '007';
const my $STAT_MODE   => 2;

# What the worker would claim now, as GPForum::Service::Outbox::ClaimQuery
# selects it, and since when each has been waiting: a message due and not
# held, and one a worker claimed and stopped renewing -- killed in the middle
# of a batch, say -- since its claim ran out.
const my $PENDING_SQL => <<'SQL';
SELECT count(*),
       EXTRACT(EPOCH FROM now() - min(
           CASE WHEN status = 'running' THEN locked_until
                ELSE GREATEST(next_attempt_at,
                              COALESCE(locked_until, next_attempt_at))
           END))
  FROM outbox_messages
 WHERE (status IN ('pending', 'failed')
        AND next_attempt_at <= now()
        AND (locked_until IS NULL OR locked_until <= now()))
    OR (status = 'running'
        AND locked_until IS NOT NULL
        AND locked_until <= now())
SQL
const my $LAST_SENT_SQL => <<'SQL';
SELECT EXTRACT(EPOCH FROM now() - max(next_attempt_at))
  FROM outbox_messages
 WHERE status = 'done'
SQL

# The checks, in the order an operator reads them.
const my @CHECKS => qw(
  preflight database readiness outbox mail antivirus services timers address
);
const my @UPGRADE_CHECKS => qw(dependencies database services);

# The account the service files run GPForum as.
const my $ACCOUNT => 'gpforum';

# Memory in the units an operator reads it in: tenths of a gigabyte below
# ten, whole ones above, megabytes below one.
const my $MEGABYTE        => 1_024**2;
const my $GIGABYTE        => 1_024**3;
const my $WHOLE_GIGABYTES => 10;
const my $HALF            => 0.5;

# What each check asks of the host, by name. A test replaces any of them
# through probes.
const my %PROBE => (
    account      => \&_probe_account,
    address      => \&_probe_address,
    antivirus    => \&_probe_antivirus,
    budgets      => \&_probe_budgets,
    database     => \&_probe_database,
    dependencies => \&_probe_dependencies,
    mail         => \&_probe_mail,
    outbox       => \&_probe_outbox,
    preflight    => \&_probe_preflight,
    readiness    => \&_probe_readiness,
    schema       => \&_probe_schema,
    sizing       => \&_probe_sizing,
    tls          => \&_probe_tls,
);

const my %CHECK => (
    address      => \&_address,
    antivirus    => \&_antivirus,
    database     => \&_database,
    dependencies => \&_dependencies,
    mail         => \&_mail,
    outbox       => \&_outbox,
    preflight    => \&_preflight,
    readiness    => \&_readiness,
    services     => \&_services,
    timers       => \&_timers,
);

# The settings, as the front door loaded them; a test gives its own.
has environment => sub { return \%ENV; };

# The environment file the settings were read from, which the fixes name;
# undef when they came from the shell alone.
has file => undef;    # optional: the shell's environment otherwise

# The names the environment took from the file; undef when that is not
# known. Any other name it holds came from the shell, and the file does not
# change it: the process environment wins (ADR 0120), so a fix sets it where
# it is.
has assigned => undef;    # optional: every setting is the file's otherwise

has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

# The checkout: deploy/ for the service files, cpanfile for the modules.
has root => sub {
    my $root = path(__FILE__)->realpath;
    for ( 1 .. $CHECKOUT_UP ) {
        $root = $root->dirname;
    }

    return $root->to_string;
};

# Check what an upgrade leaves behind instead of everything.
has upgrade => 0;

# What reads the installed service files, the timers and the running
# services, for a test; otherwise a GPForum::Service::Operations::ServiceUnits
# for this host.
has units => undef;    # optional: built for the configuration's host

has http => sub { return GPForum::Service::Operations::HttpProbe->new; };

# The operating system the fixes are written for; this host's otherwise.
has os => undef;       # optional: detected otherwise

# Replacements for the probes above, by name, for a test.
has probes => sub { return {} };

# Runs the checks. Returns { findings, config, waiting }: the
# GPForum::Service::Operations::Findings an operator reads, the
# configuration (undef when the settings cannot be used) and, then, waiting
# -- true when the other checks wait for the settings.
sub check ($self) {
    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $self->catalog );
    my $config = $self->settings( $self->environment, $findings );
    return { findings => $findings, config => undef, waiting => 1 }
      if !defined $config;

    my %state = ( config => $config, findings => $findings );
    for my $check ( $self->upgrade ? @UPGRADE_CHECKS : @CHECKS ) {
        $CHECK{$check}->( $self, \%state );
    }

    return { findings => $findings, config => $config, waiting => 0 };
}

# The settings an environment holds, checked as the service checks them at
# its start: every problem a finding, with what fixes it; a retired setting,
# or one still under its old name, a warning; one line when they are fine.
# The start also stops when mail leaves by smtp with TLS on and this Perl
# cannot speak it (GPForum::Config::smtp_tls_problem): doctor said the
# settings were fine, then the service refused them. Returns the
# configuration, or undef when the settings cannot be used.
sub settings ( $self, $environment, $findings ) {
    my ( $config, $problems );
    try {
        $config = GPForum::Config->from_environment($environment);
    }
    catch ($error) {
        my $invalid = GPForum::X::Config->caught($error);
        die $error if !$invalid || !@{ $invalid->problems };    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
        $problems = $invalid->problems;
    };
    if ( !$problems ) {
        my $tls = $config->smtp_tls_problem( $self->_probe('tls') );
        $problems = $tls ? [$tls] : undef;
    }

    my $host = $self->_host( $environment->{GPFORUM_ENV} // 'development' );
    if ($problems) {
        for my $problem ( @{$problems} ) {
            $findings->add(
                name    => 'settings',
                status  => 'fail',
                message => GPForum::Config::Report->sentence(
                    { %{$problem}, value => _shown_value($problem) },
                    $self->catalog->translator
                ),
                fixes => $self->_setting_fixes( $problem, $host ),
            );
        }
        return undef;
    }

    my $file = $self->file;
    $findings->add(
        name    => 'settings',
        status  => 'ok',
        message => defined $file
        ? [
            'doctor.settings_file',
            { environment => $config->environment, file => $file }
          ]
        : [ 'doctor.settings_shell', { environment => $config->environment } ],
    );
    $self->_sizing( $findings, $config );
    $self->_open_file( $findings, $host );
    for my $variable ( @{ $config->retired_settings } ) {
        $findings->add(
            name    => 'settings',
            status  => 'degraded',
            message => [ 'config.retired', { variable => $variable } ],
            fixes   => [
                $self->_from_shell($variable)
                ? "unset $variable"
                : [
                    'doctor.fix_remove',
                    {
                        variable => $variable,
                        file     => $file // $host->settings_file
                    }
                ]
            ],
        );
    }
    $self->_renamed( $findings, $config, $host );

    return $config;
}

# A setting the environment still names by its old name is read, and the
# start logs the line that replaces it (Bootstrap::Config); doctor says the
# same, with the old line to remove, as it does for a retired setting. An
# old value -- GPFORUM_ENV=production-medium -- is fixed by the line that
# replaces it, where it is set.
sub _renamed ( $self, $findings, $config, $host ) {
    for my $renamed ( @{ $config->renamed_settings } ) {
        my $variable = $renamed->{variable};
        my $message  = GPForum::Config::Report->renamed($renamed);
        my $fix =
          defined $renamed->{old}
          ? $self->_set_fix( $host, $variable, $message )
          : $self->_from_shell($variable) ? "unset $variable"
          : [
            'doctor.fix_remove',
            {
                variable => $variable,
                file     => $self->file // $host->settings_file
            }
          ];
        $findings->add(
            name    => 'settings',
            status  => 'degraded',
            message => $message,
            fixes   => [$fix],
        );
    }

    return;
}

sub _set_fix ( $self, $host, $variable, $message ) {
    return [
        'doctor.fix_set',
        {
            assignment => $message->[1]{assignment},
            where      => $self->_where( $host, $variable ),
        }
    ];
}

# How the node is sized for this host: its CPUs and memory, and the web
# processes and cache it runs at their size (audit D1'). Nothing when the
# operator set both.
sub _sizing ( $self, $findings, $config ) {
    my $sizing = $self->_probe( 'sizing', $config );
    my $sizes  = $sizing->{sizes};
    my @parts;
    if ( defined( my $web = $sizes->{web_processes} ) ) {
        push @parts,
          $self->catalog->text(
            $web == 1 ? 'doctor.size_web_one' : 'doctor.size_web',
            { count => $web } );
    }
    if ( defined( my $cache = $sizes->{local_cache_max_entries} ) ) {
        push @parts,
          $self->catalog->text( 'doctor.size_cache', { count => $cache } );
    }
    return if !@parts;

    my $cpus = $sizing->{cpus} || 1;
    my $key =
        'doctor.sized'
      . ( $cpus == 1                      ? '_one_cpu' : q{} )
      . ( defined $sizing->{memory_bytes} ? q{}        : '_cpus_only' );
    $findings->add(
        name    => 'settings',
        status  => 'ok',
        message => [
            $key,
            {
                cpus   => $cpus,
                memory => _memory( $sizing->{memory_bytes} ),
                sizes  => join( q{, }, @parts ),
            }
        ],
    );

    return;
}

# Memory as an operator reads it: 512 MB, 3.8 GB, 64 GB.
sub _memory ($bytes) {
    return q{} if !defined $bytes;

    my $gigabytes = $bytes / $GIGABYTE;
    return sprintf '%d MB', $bytes / $MEGABYTE if $gigabytes < 1;
    return sprintf( '%.1f', $gigabytes ) =~ s/[.]0 \z//rmsx . ' GB'
      if $gigabytes < $WHOLE_GIGABYTES;

    return sprintf '%d GB', $gigabytes + $HALF;
}

# A deployed host's environment file holds its secrets, so every account on
# the host reading it is a problem: said with the chmod that closes it, as
# gpforum secret rotate says it (the FreeBSD rc scripts refuse such a file).
sub _open_file ( $self, $findings, $host ) {
    my $file = $self->file;
    return if !defined $file || !$host->is_deployed;

    my $mode = ( stat $file )[$STAT_MODE];
    return if !defined $mode || !( $mode & $OTHERS_BITS );

    $findings->add(
        name    => 'settings',
        status  => 'degraded',
        message => [ 'doctor.settings_open', { file => $file } ],
        fixes   => [ ( -O $file ? q{} : 'sudo ' ) . "chmod 0640 $file" ],
    );

    return;
}

# The settings' problems an environment holds, for a check that reads an
# environment file without starting anything: [ { variable, key, sentence
# } ], in English, the values of secrets left out -- and the password a
# value carries inside it, a DSN's password= or a URL's user:password@.
sub settings_problems ( $class, $environment ) {
    try {
        GPForum::Config->from_environment($environment);
    }
    catch ($error) {
        my $invalid = GPForum::X::Config->caught($error);
        die $error if !$invalid;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
        return [
            map {
                {
                    key      => $_->{key},
                    sentence => GPForum::Config::Report->sentence(
                        { %{$_}, value => _shown_value($_) }
                    ),
                    variable => $_->{variable},
                }
            } @{ $invalid->problems }
        ];
    };

    return [];
}

sub _shown_value ($problem) {
    my $settings = 'GPForum::Service::Admin::Settings';
    return $HIDDEN if $settings->is_secret( $problem->{variable} // q{} );

    return $settings->new->redact( $problem->{value}, [] );
}

# Each problem's fixes: the setting it suggests, the secret gpforum makes, or
# the value to set, in the file the operator edits.
sub _setting_fixes ( $self, $problem, $host ) {

    # Its sentence names both fixes, the module to install or TLS to turn
    # off; "correct GPFORUM_SMTP_TLS" would name neither.
    return [] if $problem->{key} eq 'config.smtp_tls_module';

    my $variable = $problem->{variable};
    my $where    = $self->_where( $host, $variable );
    my @fixes;
    if ( defined $problem->{suggestion} ) {
        return [
            [
                'doctor.fix_set',
                { assignment => $problem->{suggestion}, where => $where }
            ]
        ];
    }
    if ( my $rotate = $self->_rotation($variable) ) {
        push @fixes, $rotate;
    }
    elsif ( defined $problem->{generate} ) {
        push @fixes, [ 'config.generate', { command => $problem->{generate} } ];
    }
    elsif ( defined $problem->{example} && length $problem->{example} ) {
        push @fixes,
          [
            'doctor.fix_set',
            {
                assignment => GPForum::Config::Report->assignment(
                    $variable, $problem->{example}
                ),
                where => $where,
            }
          ];
    }
    if ( !@fixes ) {
        push @fixes,
          [ 'doctor.fix_correct', { variable => $variable, where => $where } ];
    }

    return \@fixes;
}

# The command that writes a secret the settings lack into the file they were
# read from, with sudo when this process cannot write it, as every other
# command offers it; undef with no file to write, or for a secret the shell
# holds. The command layer adds the --env-file a file not the host's needs.
sub _rotation ( $self, $variable ) {
    my $file = $self->file;
    return undef
      if !exists $ROTATES{$variable}
      || !defined $file
      || $self->_from_shell($variable);

    return ( -w $file ? q{} : 'sudo ' )
      . "gpforum secret rotate $ROTATES{$variable}";
}

sub _from_shell ( $self, $variable ) {
    my $assigned = $self->assigned;
    return 0 if !defined $self->file || !defined $assigned;
    return 0 if !exists $self->environment->{$variable};

    return ( any { $_ eq $variable } @{$assigned} ) ? 0 : 1;
}

sub _preflight ( $self, $state ) {
    my $report = $self->_probe( 'preflight', $state->{config} );

    GPForum::Service::Operations::OSPreflight->new(
        host => $self->_host( $state->{config}->environment ) )
      ->findings( $report, $state->{findings} );

    return;
}

# The database, then what lives in it: the schema and the budgets. A
# database doctor cannot reach is one sentence, which names the setting,
# the file and the command; the checks that need it wait.
sub _database ( $self, $state ) {
    my $config = $state->{config};
    my $database;
    try {
        $database = $self->_probe( 'database', $config );
    }
    catch ($error) {
        $self->_database_failed( $state, $error );
        return;
    };
    $state->{schema} = $database->{schema};

    my %dsn = _dsn_parts( $config->database_dsn );
    $state->{findings}->add(
        name    => 'database',
        status  => 'ok',
        message => [
            'doctor.database',
            {
                version  => $database->{version} // q{?},
                database => $dsn{dbname}         // 'gpforum',
                server   => $dsn{server},
            }
        ],
    );
    $self->_schema($state);
    $self->_budgets($state);

    return;
}

sub _database_failed ( $self, $state, $error ) {
    my $text  = _trimmed($error);
    my $parts = GPForum::Service::Operations::DatabaseFailure->new(
        language         => $self->catalog->language,
        environment      => $state->{config}->environment,
        environment_file => $self->file,
        ( $self->os ? ( os => $self->os ) : () ),
    )->parts($text);
    if ( !defined $parts ) {
        $state->{findings}->add(
            name    => 'database',
            status  => 'fail',
            message => [
                'doctor.database_failed',
                {
                    error => GPForum::Service::Admin::Settings->new(
                        config => $state->{config}
                    )->redact( _first_line($text) )
                }
            ],
            fixes => [
                [
                    'doctor.fix_database',
                    { where => $self->_where( $self->_host_of($state) ) }
                ]
            ],
        );
        return;
    }

    $state->{findings}->add(
        name    => 'database',
        status  => 'fail',
        message => [
            'doctor.database_problem',
            { problem => _after_label( $parts->{problem} ) }
        ],
        notes => defined $parts->{note} ? [ $parts->{note} ] : [],
        fixes => length $parts->{fix}   ? [ $parts->{fix} ]  : [],
    );

    return;
}

sub _schema ( $self, $state ) {
    my $schema = $self->_probe( 'schema', $state->{schema} );
    my $prefix = $self->_prefix($state);
    my $count  = scalar @{ $schema->{pending} };

    if ( defined $schema->{changed} ) {
        $state->{findings}->add(
            name    => 'schema',
            status  => 'fail',
            message => [
                'doctor.schema_changed',
                {
                    versions => $schema->{changed} =~ s/\A [^:]* : \s*//rmsx
                }
            ],
            fixes => [ [ 'doctor.fix_changed', { root => $self->root } ] ],
        );
        return;
    }
    if ( !$count ) {
        $state->{findings}->add(
            name    => 'schema',
            status  => 'ok',
            message =>
              [ 'doctor.schema_current', { version => $schema->{latest} } ],
        );
        return;
    }

    my $first = $schema->{pending}[0];
    $state->{findings}->add(
        name    => 'schema',
        status  => 'fail',
        message => [
            $count == 1
            ? 'doctor.schema_pending_one'
            : 'doctor.schema_pending_many',
            {
                count       => $count,
                description => $first->{description},
                first       => $first->{version},
                last        => $schema->{pending}[-1]{version},
                version     => $first->{version},
            }
        ],
        fixes => ["${prefix}gpforum migrate"],
    );
    $state->{pending} = 1;

    return;
}

# The budgets are synced by gpforum migrate; with migrations pending, that
# is the fix already named.
sub _budgets ( $self, $state ) {
    return if $state->{pending};

    my $report = $self->_probe( 'budgets', $state->{schema} );
    my $count =
      scalar map { @{ $report->{$_} // [] } } qw(missing extra mismatched);
    if ( !$count ) {
        $state->{findings}->add(
            name    => 'budgets',
            status  => 'ok',
            message => ['doctor.budgets']
        );
        return;
    }

    $state->{findings}->add(
        name    => 'budgets',
        status  => 'fail',
        message => [ 'doctor.budgets_drift', { count => $count } ],
        fixes   => [ $self->_prefix($state) . 'gpforum budgets --sync' ],
    );

    return;
}

# The rest of what /health/ready checks, as the running service would
# answer it, through the same words gpforum status uses.
sub _readiness ( $self, $state ) {
    return if !$state->{schema} || $state->{pending};

    my $report =
      $self->_probe( 'readiness', $state->{config}, $state->{schema} );
    GPForum::Service::Operations::ReadinessFindings->new(
        catalog        => $self->catalog,
        command_prefix => $self->_prefix($state),
    )->findings(
        $report,
        collapse => 1,
        findings => $state->{findings},
        skip     => [@COVERED],
    );

    return;
}

# Whether something sends the outbox: a message ready this long with
# nobody taking it means the worker is not running. Migrations pending do
# not stop the worker, so they do not stop this check.
sub _outbox ( $self, $state ) {
    return if !$state->{schema};

    # A schema too far behind to have the table says so in its own line.
    my $outbox;
    try {
        $outbox = $self->_probe( 'outbox', $state->{schema} );
    }
    catch ($error) {
        return;
    };
    my $waiting = $outbox->{waiting} // 0;
    my $oldest  = $outbox->{oldest_seconds};
    my $sent    = $outbox->{last_sent_seconds};

    if ( $waiting && ( $oldest // 0 ) > $OUTBOX_PATIENCE ) {
        $state->{findings}->add(
            name    => 'outbox',
            status  => 'fail',
            message => [
                $waiting == 1
                ? 'doctor.outbox_stalled_one'
                : 'doctor.outbox_stalled',
                { count => $waiting, age => $self->age($oldest) }
            ],
            fixes => $self->_outbox_fixes($state),
        );
        return;
    }

    my $message =
      $waiting
      ? [
        $waiting == 1 ? 'doctor.outbox_busy_one' : 'doctor.outbox_busy',
        { count => $waiting, age => $self->age( $oldest // 0 ) }
      ]
      : defined $sent ? [ 'doctor.outbox_idle', { age => $self->age($sent) } ]
      :                 ['doctor.outbox_quiet'];
    $state->{findings}
      ->add( name => 'outbox', status => 'ok', message => $message );

    return;
}

sub _outbox_fixes ( $self, $state ) {
    my $host = $self->_host_of($state);
    return ['gpforum outbox --loop'] if !$host->is_deployed;

    my @fixes;
    my $start = $host->start_command('gpforum-outbox');
    if ( defined $start ) {
        push @fixes, $start;
    }
    if ( ( $host->service_manager // q{} ) eq 'systemd' ) {
        push @fixes,
          [
            'status.fix_says_why', { command => 'journalctl -u gpforum-outbox' }
          ];
    }

    return \@fixes;
}

sub _mail ( $self, $state ) {
    my $evidence = $self->_probe( 'mail', $state->{config} );
    GPForum::Service::Operations::MailCheck->new(
        config => $state->{config},
        host   => $self->_host_of($state),
    )->findings( $evidence, $state->{findings} );

    return;
}

sub _antivirus ( $self, $state ) {
    my $evidence = $self->_probe( 'antivirus', $state->{config} );
    GPForum::Service::Operations::AntivirusCheck->new(
        config => $state->{config},
        host   => $self->_host_of($state),
    )->findings( $evidence, $state->{findings} );

    return;
}

# The service files a deployed host runs GPForum under, installed and as
# this release ships them, and the web service and the outbox worker
# running the code on disk (GPForum::Service::Operations::ServiceUnits).
sub _services ( $self, $state ) {
    my $units = $self->_units($state);
    return if !$self->_host_of($state)->is_deployed || !$units->applies;

    # The account every unit, rc script and plist runs as: without it none
    # starts, and the fixes below begin with commands that name it.
    if ( !$self->_probe('account') ) {
        $state->{findings}->add(
            name    => 'account',
            status  => 'fail',
            message => [ 'setup.account_missing', { user => $ACCOUNT } ],
            fixes   => ['sudo gpforum setup'],
        );
    }
    $units->units( $state->{findings} );
    $units->running( $state->{findings} );

    return;
}

# The hourly and daily timers: on, and their last run recent and
# successful.
sub _timers ( $self, $state ) {
    my $units = $self->_units($state);
    return if !$self->_host_of($state)->is_deployed || !$units->applies;

    $units->timers( $state->{findings} );

    return;
}

# The forum's public address, as a member's browser reaches it: through the
# proxy, over TLS once deployed.
sub _address ( $self, $state ) {
    my $config = $state->{config};
    my $url    = $config->public_base_url =~ s{/+\z}{}rmsx;
    my $answer = $self->_probe( 'address', $url );
    my $host   = $self->_host_of($state);
    my ($name) = $url =~ m{\A \w+ :// ( \[ [^\]]+ \] | [^:/]+ )}msx;
    my %values = ( url => $url, host => $name // $url );

    if ( !defined $answer->{error} ) {
        my $code = $answer->{code} // 0;
        if ( $code >= $HTTP_OK_MIN && $code <= $HTTP_OK_MAX ) {
            return $state->{findings}->add(
                name    => 'address',
                status  => 'ok',
                message => [
                    $url =~ m{\A https://}msxi
                    ? 'doctor.address_tls'
                    : 'doctor.address_ok',
                    \%values
                ],
            );
        }
        return $state->{findings}->add(
            name    => 'address',
            status  => 'degraded',
            message => [ 'doctor.address_status', { %values, code => $code } ],
            fixes   => $self->_service_fixes($host),
        );
    }

    my $kind = $answer->{kind} // 'other';
    $values{reason} = $self->http->reason( $answer, $self->catalog );
    my %by_kind = (

        # Most often a port that answers plain HTTP: the proxy's TLS, not a
        # certificate, is what is missing.
        handshake => [
            'degraded', 'doctor.address_handshake', $self->_proxy_fixes($host)
        ],
        tls => [
            'fail', 'doctor.address_certificate',
            ["sudo certbot certonly --nginx -d $values{host}"]
        ],
        unsupported =>
          [ 'degraded', 'doctor.address_unchecked', [ ['doctor.fix_curl'] ] ],
        unresolved => [
            'degraded',
            'doctor.address_down',
            [
                [
                    $values{host} =~ $EXAMPLE_HOST
                    ? 'doctor.fix_correct'
                    : 'doctor.fix_dns',
                    {
                        host     => $values{host},
                        variable => 'GPFORUM_PUBLIC_BASE_URL',
                        where    =>
                          $self->_where( $host, 'GPFORUM_PUBLIC_BASE_URL' )
                    }
                ]
            ]
        ],
    );
    my ( $status, $key, $fixes ) =
      @{ $by_kind{$kind}
          // [ 'degraded', 'doctor.address_down', $self->_proxy_fixes($host) ]
      };

    # A failed handshake is said in words; what the TLS library said --
    # "LibreSSL/3.3.6: error:1404B42E:SSL routines:..." -- is for whoever
    # wants it, on a line of its own, as the antivirus check writes the
    # scanner's.
    $state->{findings}->add(
        name    => 'address',
        status  => $status,
        message => [ $key, \%values ],
        notes   => $kind eq 'handshake' && length $values{reason}
        ? [ [ 'antivirus.detail', { detail => $values{reason} } ] ]
        : [],
        fixes => $fixes,
    );

    return;
}

# The proxy in front of the forum, put in place as gpforum service print
# writes it for this host -- nginx's site where this operating system's
# nginx reads it -- and the forum behind it started.
sub _proxy_fixes ( $self, $host ) {
    return ['gpforum start --foreground'] if !$host->is_deployed;

    my $files = GPForum::Service::Operations::ServiceFiles->new(
        environment => $self->environment,
        host        => $host,
        root        => $self->root,
        defined $self->file ? ( environment_file => $self->file ) : (),
    );

    return [
        ['doctor.fix_proxy'],
        @{ $files->steps('nginx') },
        @{ $self->_service_fixes($host) },
    ];
}

sub _service_fixes ( $self, $host ) {
    return ['gpforum start --foreground'] if !$host->is_deployed;

    my @fixes;
    my $start = $host->start_command('gpforum');
    if ( defined $start ) {
        push @fixes, $start;
    }
    if ( ( $host->service_manager // q{} ) eq 'systemd' ) {
        push @fixes,
          [ 'status.fix_says_why', { command => 'journalctl -u gpforum' } ];
    }

    return \@fixes;
}

# The modules this release needs, installed at the versions it names, and
# the compiled ones built for the Perl running this
# (GPForum::Service::Operations::Dependencies): an upgrade of either the
# release or the Perl needs them installed again.
sub _dependencies ( $self, $state ) {
    my $dependencies =
      GPForum::Service::Operations::Dependencies->new( root => $self->root );
    $dependencies->findings(
        $self->_probe('dependencies'),
        $state->{findings},
        $dependencies->install_command( $self->_host_of($state)->is_deployed ),
    );

    return;
}

# A duration as an operator reads it, in the catalog's language.
sub age ( $self, $seconds ) {
    return GPForum::Service::Operations::ServiceUnits->new(
        host => $self->_host('development') )->age($seconds);
}

sub _probe ( $self, $name, @arguments ) {
    my $probe = $self->probes->{$name} // $PROBE{$name};

    return $probe->( $self, @arguments );
}

sub _probe_preflight ( $self, $config ) {
    return GPForum::OS::Preflight->from_runtime(
        GPForum::Runtime->from_config($config),
        min_recommended_workers   => $config->os_min_recommended_workers,
        max_open_file_descriptors => $config->os_max_open_file_descriptors,
    )->report;
}

sub _probe_sizing ( $self, $config ) {
    return $config->sizing;
}

sub _probe_database ( $self, $config ) {
    my $schema = GPForum::Schema->connect_from_config($config);
    my ($version) =
      $schema->storage->dbh->selectrow_array('SHOW server_version');
    $version =~ s/\s.*\z//msx;

    return { schema => $schema, version => $version };
}

sub _probe_schema ( $self, $schema ) {
    my $runner = GPForum::Migration::Runner->new( schema => $schema );
    my $plan   = GPForum::Migration::Plan->new->summary;
    my $changed;
    try {
        $runner->verify_applied;
    }
    catch ($error) {
        $changed = _trimmed($error);
    };

    return {
        changed => $changed,
        latest  => @{$plan} ? $plan->[-1]{version} : q{-},
        pending => $runner->pending,
    };
}

sub _probe_budgets ( $self, $schema ) {
    return GPForum::Service::Operations::QueryBudget->new( schema => $schema )
      ->drift_report;
}

sub _probe_readiness ( $self, $config, $schema ) {
    my $runtime = GPForum::Runtime->from_config($config);

    return GPForum::Service::Operations::Readiness->new(
        cache  => GPForum::Service::Operations::CacheFactory->build($config),
        config => $config,
        environment    => $config->environment,
        glifistore_url => $config->glifistore_url,
        runtime        => $runtime,
        runtime_policy => GPForum::OS::RuntimePolicy->new(
            config  => $config,
            runtime => $runtime,
        ),
        schema => $schema,
    )->check;
}

sub _probe_outbox ( $self, $schema ) {
    my $dbh = $schema->storage->dbh;
    my ( $waiting, $oldest ) = $dbh->selectrow_array($PENDING_SQL);
    my ($sent) = $dbh->selectrow_array($LAST_SENT_SQL);

    return {
        last_sent_seconds => $sent,
        oldest_seconds    => $oldest,
        waiting           => $waiting,
    };
}

# Whether this Perl can speak TLS to an SMTP server.
sub _probe_tls ($self) {
    return GPForum::Config->smtp_can_tls;
}

sub _probe_mail ( $self, $config ) {
    return GPForum::Service::Operations::MailCheck->new( config => $config )
      ->run( { mode => 'dry_run' } );
}

sub _probe_antivirus ( $self, $config ) {
    return GPForum::Service::Operations::AntivirusCheck->new(
        config => $config )->run;
}

sub _probe_address ( $self, $url ) {
    return $self->http->get( $url . $LIVE_PATH );
}

# Whether the services' account is on this host.
sub _probe_account ($self) {
    my @entry = getpwnam $ACCOUNT;

    return @entry ? 1 : 0;
}

sub _probe_dependencies ($self) {
    return GPForum::Service::Operations::Dependencies->new(
        root => $self->root )->check;
}

sub _host ( $self, $environment ) {
    return GPForum::Service::Operations::Host->new(
        catalog          => $self->catalog,
        environment      => $environment,
        environment_file => $self->file,
        ( $self->os ? ( os => $self->os ) : () ),
    );
}

sub _units ( $self, $state ) {
    $state->{units} //= $self->units
      // GPForum::Service::Operations::ServiceUnits->new(
        host => $self->_host_of($state),
        root => $self->root,
        now  => $self->_now,
      );

    return $state->{units};
}

sub _host_of ( $self, $state ) {
    $state->{host} //= $self->_host( $state->{config}->environment );

    return $state->{host};
}

sub _prefix ( $self, $state ) {
    return
      GPForum::Service::Operations::ReadinessFindings->service_user_prefix(
        $self->_host_of($state) );
}

# Where an operator changes a setting: the shell's environment for one it
# holds over the file, else the file this run read, else the host's, as a
# phrase that ends a sentence.
sub _where ( $self, $host, $variable = undef ) {
    return $self->catalog->text( 'database.where_shell', {} )
      if defined $variable && $self->_from_shell($variable);

    my $file = $self->file;
    return $host->where if !defined $file;

    return $self->catalog->text( 'database.where_file', { path => $file } );
}

sub _now ($self) {
    return $self->probes->{now} ? $self->probes->{now}->() : time;
}

# The host, port and database a DSN names, the server as host:port.
sub _dsn_parts ($dsn) {
    my ($rest) = ( $dsn // q{} ) =~ /\A dbi:Pg: (.*) \z/msxi;
    my %parts =
      map { /\A \s* ([^=\s]+) \s* = \s* (.*?) \s* \z/msx ? ( lc $1, $2 ) : () }
      split /;/msx, $rest // q{};
    $parts{dbname} //= $parts{database} // $parts{db};
    my $host = $parts{host} // 'localhost';
    $parts{server} =
      $host =~ m{\A /}msx ? $host : "$host:" . ( $parts{port} // '5432' );

    return %parts;
}

# An error's text without croak's " at FILE line N." or the newline after it.
sub _trimmed ($error) {
    my $text = defined $error ? "$error" : q{};
    while ( $text =~ s/\s+ at \s+ \S+ \s+ line \s+ \d+ [.]? \s*\z//msx ) {
    }

    return $text =~ s/\s+\z//rmsx;
}

# A sentence written to stand alone, put after a label ("database: "): its
# first word lowercased, unless that word is a name with capitals of its own,
# such as PostgreSQL.
sub _after_label ($sentence) {
    return $sentence =~
      s/\A (\p{Lu}) (?= [^\s\p{Lu}]* (?: \s | \z ) )/\l$1/rmsx;
}

sub _first_line ($text) {
    my ($line) = ( $text // q{} ) =~ $FIRST_LINE;

    return ( $line // q{} ) =~ s/\s+\z//rmsx;
}

1;

__END__

=head1 NAME

GPForum::Service::Operations::Doctor - Every check of a GPForum host, with
what fixes each problem.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $result = GPForum::Service::Operations::Doctor->new->check;
    print $result->{findings}->human_text;

    # what an upgrade leaves behind
    GPForum::Service::Operations::Doctor->new( upgrade => 1 )->check;

=head1 DESCRIPTION

What C<gpforum doctor> checks, in the order an operator reads it, as
L<GPForum::Service::Operations::Findings>:

=over 4

=item the settings

Every problem the service would refuse to start with, each with the
variable, the file and what to set or run (C<gpforum secret rotate> for a
missing secret); a retired setting, or an old name or value, as a warning
with the line to write; what the host's CPUs and memory size the node for;
and, deployed, an environment file every account on the host can read.
With a problem here the other checks wait.

=item the host

os-preflight's findings (L<GPForum::Service::Operations::OSPreflight>).

=item the database, the schema and the budgets

A database that cannot be used is one sentence from
L<GPForum::Service::Operations::DatabaseFailure>; migrations pending and
budgets that differ from the code name C<gpforum migrate> and C<gpforum
budgets --sync>.

=item the readiness report

The rest of what C</health/ready> checks, through
L<GPForum::Service::Operations::ReadinessFindings>.

=item the outbox worker

A message ready for more than five minutes with nobody sending it fails,
with the command that starts the worker.

=item mail and the antivirus

mail-check's dry run and antivirus-check's findings, as those commands
write them.

=item the services and timers

Deployed: each service file GPForum ships for this host's service manager
installed and as this release ships it; under systemd the web service and
the outbox worker running the code on disk, and the hourly and daily timers
on, their last run recent and successful
(L<GPForum::Service::Operations::ServiceUnits>).

=item the public address

C<GPFORUM_PUBLIC_BASE_URL/health/live> answering, over TLS with a
certificate this host accepts once deployed
(L<GPForum::Service::Operations::HttpProbe>).

=back

With C<upgrade>, it checks the settings, the modules this release needs
for this Perl (L<GPForum::Service::Operations::Dependencies>), the database,
its schema and budgets, and the service files and running services as
above.

=head1 SUBROUTINES/METHODS

=head2 environment

The settings to check, as a hash reference; C<%ENV> by default.

=head2 file

The environment file the settings were read from, which the fixes name.

=head2 assigned

The names the environment took from the file, as an array reference: a fix
for a setting the environment holds that is not among them sets it in the
shell's environment, where it came from, not in the file.

=head2 catalog

The L<GPForum::Service::I18N::CliCatalog> the words come from.

=head2 root

The checkout, whose F<deploy/> holds this release's service files.

=head2 upgrade

True to check what an upgrade leaves behind instead.

=head2 units

The L<GPForum::Service::Operations::ServiceUnits> that reads the installed
service files, the timers and the running services; one for the
configuration's host by default.

=head2 http

The L<GPForum::Service::Operations::HttpProbe> the public address is asked
with.

=head2 os

The L<GPForum::OS> the fixes are written for; this host's by default.

=head2 probes

A hash reference of code references that replace what a check asks of the
host -- C<database>, C<schema>, C<budgets>, C<readiness>, C<preflight>,
C<outbox>, C<mail>, C<antivirus>, C<address>, C<dependencies>, C<tls>
(whether this Perl can speak TLS to an SMTP server), C<sizing> (the
configuration's L<GPForum::Config/sizing>) -- and C<now>, the
clock; each is given the doctor and what the check
passes it. For tests.

=head2 check

Runs the checks. Returns C<{ findings, config, waiting }>.

=head2 settings

Takes an environment hash reference and a findings list; adds the settings'
findings -- each problem the service's start would refuse, TLS to an SMTP
server this Perl cannot speak among them; a warning for each retired
setting and each old name or old value still set, with the line that
replaces it; and, when they are fine, what the node is sized for on this
host ("sized for 2 CPUs, 2 GB: 4 web processes, 4096 cache entries a
process") -- and returns the configuration, or undef when it cannot be
used.

=head2 settings_problems

Class method. Takes an environment hash reference and returns its settings'
problems as C<{ variable, key, sentence }>, in English and without values,
for a report that is archived.

=head2 age

A number of seconds as an operator reads a duration, in the catalog's
language.

=head1 DIAGNOSTICS

Each check catches what it asks fail and says it as a finding; an error
that is not a check's answer is rethrown.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the settings L<GPForum::Config> reads.

=head1 DEPENDENCIES

L<GPForum::Config>, L<GPForum::Migration::Runner>, L<GPForum::Schema>,
L<GPForum::Service::Operations::Readiness>,
L<GPForum::Service::Operations::ReadinessFindings>,
L<GPForum::Service::Operations::DatabaseFailure>,
L<GPForum::Service::Operations::MailCheck>,
L<GPForum::Service::Operations::AntivirusCheck>,
L<GPForum::Service::Operations::OSPreflight>,
L<GPForum::Service::Operations::ServiceFiles>,
L<GPForum::Service::Operations::ServiceUnits>,
L<GPForum::Service::Operations::Dependencies>,
L<GPForum::Service::Operations::HttpProbe>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The timers and the services' running state are read from systemd only; on
FreeBSD and macOS the service files are checked, and the outbox worker
through the age of what waits for it.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
