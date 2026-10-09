# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Config;

use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;
use DateTime::TimeZone;
use List::Util qw(any first max min);
use Mojo::File qw(path);

use GPForum::Config::Report;
use GPForum::OS;
use GPForum::OS::Memory;
use GPForum::X::Config;

our $VERSION = '0.001';

const my $DEVELOPMENT_SESSION_SECRET => 'gpforum-development-secret-change-me';
const my $MAXIMUM_PROCESS_COUNT      => 512;

# Production signs sessions with a secret at least this long: 32 characters
# of `openssl rand -hex 32` is 128 bits of it.
const my $MINIMUM_PRODUCTION_SECRET => 32;
const my $SECRET_GENERATOR          => 'openssl rand -hex 32';

# GPFORUM_WEB_PROCESSES=auto runs as many web processes as the CPUs carry,
# but never more than this: each holds PostgreSQL connections -- its queries
# and its live-update LISTEN -- and PostgreSQL's default max_connections is
# 100. A larger host is one whose operator chooses the number.
const my $MAXIMUM_AUTOMATIC_WEB_PROCESSES => 16;
const my $AUTOMATIC                       => 'auto';

# GPFORUM_LOCAL_CACHE_MAX_ENTRIES=auto gives each web process an equal part
# of an eighth of the host's memory, at about 16 KiB an entry -- a rendered
# fragment, a category list -- rounded down to a power of two between 1024
# and 16384: 4096, the old fixed default, on a 1 GB host with two web
# processes. A host whose memory cannot be measured keeps 4096.
const my $CACHE_MEMORY_SHARE      => 8;
const my $CACHE_ENTRY_BYTES       => 16 * 1_024;
const my $MINIMUM_AUTOMATIC_CACHE => 1_024;
const my $MAXIMUM_AUTOMATIC_CACHE => 16_384;
const my $UNMEASURED_CACHE        => 4_096;

# The release in which the old names of a setting, and its old values, stop
# being read (audit 5.6); docs/DEPLOYMENT.md's "Renamed settings" lists them.
const my $ALIASES_UNTIL => 'v0.3.0';

# A resident clamd answers in well under a second. clamscan, run per file,
# loads its whole signature database first, which alone can take most of 30
# seconds on a small server.
const my $CLAMD_TIMEOUT   => 30;
const my $COMMAND_TIMEOUT => 120;

const my $GLIFISTORE_TCP_URL =>
  qr{\A (?:tcp://)? [[:alnum:]._-]+ : [[:digit:]]+ \z}msx;
const my $GLIFISTORE_UNIX_URL => qr{\A unix:// \S+ \z}msx;

# A public address: a scheme, a host (a name, an IPv4 address or a bracketed
# IPv6 one), an optional port and an optional path.
const my $URL_HOST =>
  qr{ [[:alnum:]] [[:alnum:].-]* | \[ [[:xdigit:]:.]+ \] }msx;
const my $URL_REST   => qr{ (?: : [[:digit:]]+ )? (?: [/?#] \S* )? }msx;
const my $PUBLIC_URL => qr{\A (https?) :// ($URL_HOST) $URL_REST \z}msxi;

# The names RFC 2606 keeps for examples, which no DNS will ever point at a
# forum and no mail server delivers from: the template's
# https://forum.example.com and forum@forum.example.com, left as copied.
const my $RESERVED_NAME =>
  qr{ example [.] (?: com | net | org ) | example | invalid }msxi;
const my $EXAMPLE_HOST => qr{ (?: \A | [.] ) (?: $RESERVED_NAME ) [.]? \z }msxi;

# The SMTP port that speaks TLS from its first byte (SMTPS); every other
# port starts in the clear and upgrades with STARTTLS.
const my $IMPLICIT_TLS_PORT => 465;

# Both kinds of TLS to an SMTP server run through this module, which
# Net::SMTP needs only once it is asked for TLS: at the first message.
const my $TLS_MODULE => 'IO::Socket::SSL';

# Where Hypnotoad listens: a URL with a scheme, as Mojo::Server::Daemon reads
# it -- http://127.0.0.1:8080, https://*:443?cert=..., http+unix://... -- not a
# bare port.
const my $LISTEN_LOCATION => qr{\A (?: https? | http[+]unix ) :// \S+ \z}msxi;

# A sender mail servers refuse to take from another host.
const my $LOCAL_SENDER =>
  qr{\@ (?: localhost | 127[.]0[.]0[.]1 | \[::1\] ) \z}msxi;

# A language tag as GPForum::Service::I18N::Locale accepts one, lowercased and
# with - between its parts: a language, then optional subtags (it, it-it,
# zh-hant-tw).
const my $LANGUAGE_TAG =>
  qr{\A [[:lower:]]{2,8} (?: - [[:lower:][:digit:]]{1,8} )* \z}msx;

# Where a node runs. test is the suite's own. The size of a node is not one
# of them: it comes from the host (automatic_web_processes,
# automatic_local_cache_max_entries), so production-small and
# production-medium are old names of production, read until $ALIASES_UNTIL.
const my @ENVIRONMENTS => qw(development test staging production);
const my @LOG_LEVELS   => qw(trace debug info warn error fatal);

# The deployed environments. They need a rotated session secret, a metrics
# token and Secure cookies, they refuse the log mail transport, and they
# default to the system's clamd and sendmail. Production, on top, needs an
# https address, a sender mail servers accept and a long session secret. The
# old names stay here for a configuration built with new, which reads no
# alias.
const my @DEPLOYED => qw(
  production
  production-medium
  production-small
  staging
);
const my %IS_DEPLOYED => map { $_ => 1 } @DEPLOYED;
const my %IS_PRODUCTION => map { $_ => 1 }
  grep { /\A production/msx } @DEPLOYED;

# How a boolean may be written. Each word reads as 1 or 0.
const my %BOOLEAN => (
    ( map { $_ => 1 } qw(1 yes true on) ),
    ( map { $_ => 0 } qw(0 no false off) ),
);

# The languages the forum ships: the catalogs in locale/ at the root of the
# checkout, two directories above the one holding lib/GPForum/Config.pm.
# Resolved while the module loads, so a later chdir cannot move it.
const my $CHECKOUT_DEPTH   => 2;
const my $LOCALE_DIRECTORY => _locale_directory_of(__FILE__);

# A suggestion for a mistyped value is offered only when it is this close:
# it shares a prefix this long, or it is one edit away for every this many
# characters typed (always at least one).
const my $MINIMUM_PREFIX       => 3;
const my $SUGGESTION_PER_CHARS => 3;

const my $SET_APPLICATION_NAME => q{SET application_name = 'gpforum'};

# UniqueConflict falls back to matching "duplicate key" and "unique
# constraint" in the server's error text when it cannot see a SQLSTATE. Those
# are English strings: under any other lc_messages a real unique violation
# would read as an unknown error and the savepoint recovery would rethrow it.
# PostgreSQL lets only a superuser set lc_messages, and production connects
# as an ordinary role: a plain SET refused every connection, migrations
# included. So it is asked for and, when refused, left at the server's
# setting -- the SQLSTATE, which UniqueConflict reads first, does not depend
# on it.
const my $SET_MESSAGE_LOCALE => join q{ },
  q{DO $$ BEGIN PERFORM set_config('lc_messages', 'C', false);},
  q{EXCEPTION WHEN insufficient_privilege THEN NULL; END $$};

# The fuzzy-title threshold for search. Searcher matches titles with the pg_trgm
# % operator, which reads this setting, because % can use the trigram index and
# the similarity(...) >= ? it replaced could not. The value is the one Searcher
# used to bind; pg_trgm's own default of 0.3 would have quietly dropped every
# match between 0.18 and 0.3. Setting a pg_trgm parameter before the extension
# is loaded is allowed: PostgreSQL keeps it as a placeholder until then.
const my $SET_SEARCH_SIMILARITY => q{SET pg_trgm.similarity_threshold = 0.18};

# Every setting, in the order from_environment reads them and validate checks
# them. One table drives the reading, the checks, the problems an operator is
# shown and deploy/gpforum.env.example. Each row is an attribute with its
# default, read from its variable:
#
#   section  where it belongs, as the settings page groups them
#   summary  one line an operator reads in the environment file template
#   operator 1 for the few settings every installation decides; the file
#            gpforum setup writes holds them, and the template lists them
#            first, uncommented
#   operator_when  [ setting, value ]: a decision only when that setting
#            holds that value, as the SMTP server when mail leaves by smtp;
#            the file setup writes offers it commented out
#   example  a value shown when the setting is wrong, and in the template
#   generate the command that makes a value, for a secret
#   retired  1 for a setting that no longer has any effect: still read, never
#            refused -- an old environment file starts, whatever it holds --
#            and named in a warning when set
#   type     text (the default), integer (digits only), boolean (on/off,
#            yes/no, true/false or 1/0, read as 1 or 0), list (comma
#            separated) or words (whitespace separated); a list's default is
#            empty
#   automatic  an integer that may be auto, which the attribute's builder
#            (automatic_NAME) works out from the host
#   check    a rule in %RULE that validate applies
#   one_of   the values validate accepts
#   within   validate refuses a value above that setting's, unless it is zero,
#            and from_environment lowers it to it
#   default_when  [ [ setting, values, default ], ... ]: the default
#            from_environment uses when a setting read before this one holds
#            one of the values; a configuration built with new keeps the plain
#            default
#   aliases  the names and values this setting had before, each read until
#            $ALIASES_UNTIL (audit 5.6) and named, with the line that
#            replaces it, in a warning when set:
#            { env => OLD, values => { old word => value }, refusal => key }
#              an old variable, read when the new one is not set, its words
#              turned into this setting's values -- any other is refused with
#              the refusal's sentence, under the old name;
#            { value => OLD, as => NEW }
#              an old value, read as the new one
const my @SETTINGS => map {
    +{
        type          => 'text',
        default       => undef,
        check         => undef,
        one_of        => undef,
        within        => undef,
        default_when  => undef,
        operator      => 0,
        operator_when => undef,
        retired       => 0,
        automatic     => 0,
        example       => undef,
        generate      => undef,
        %{$_},
        aliases => [
            map { +{ read_until => $ALIASES_UNTIL, %{$_} } }
              @{ $_->{aliases} // [] }
        ],
    }
} (
    {
        name    => 'environment',
        env     => 'GPFORUM_ENV',
        default => 'development',
        check   => 'required',
        one_of  => \@ENVIRONMENTS,
        aliases => [
            map { +{ value => $_, as => 'production' } }
              qw(production-small production-medium)
        ],
        section  => 'application',
        summary  => 'Where this node runs: development, staging or production.',
        operator => 1,
        example  => 'production',
    },
    {
        name    => 'log_level',
        env     => 'GPFORUM_LOG_LEVEL',
        default => 'info',
        check   => 'required',
        one_of  => \@LOG_LEVELS,
        section => 'application',
        summary =>
          'How much the log says: trace, debug, info, warn, error or fatal.',
    },
    {
        name    => 'log_path',
        env     => 'GPFORUM_LOG_PATH',
        default => q{},
        section => 'application',
        summary => 'A file to log to; empty logs to standard error, which'
          . q{ systemd's journal keeps.},
        example => '/var/log/gpforum/gpforum.log',
    },
    {
        name    => 'attachment_root',
        env     => 'GPFORUM_ATTACHMENT_ROOT',
        default => 'var/attachments',
        section => 'application',
        summary => 'Where uploaded files are kept; a relative path starts at'
          . ' the code directory.',
    },
    {
        name    => 'attachment_accel_redirect',
        env     => 'GPFORUM_ATTACHMENT_ACCEL_REDIRECT',
        default => q{},
        section => 'application',
        summary => 'The internal path the proxy serves attachments from'
          . ' (X-Accel-Redirect); empty serves them from GPForum.',
        example => '/protected-attachments',
    },
    {
        name    => 'default_locale',
        env     => 'GPFORUM_DEFAULT_LOCALE',
        default => 'en',
        check   => 'locale',
        section => 'application',
        summary => 'The language visitors see before they choose one,'
          . ' such as en or it.',
    },
    {
        name    => 'default_theme',
        env     => 'GPFORUM_DEFAULT_THEME',
        default => 'auto',
        one_of  => [qw(auto default dark high_contrast)],
        section => 'application',
        summary => 'The theme visitors see before they choose one: auto,'
          . ' default, dark or high_contrast.',
    },

    # The IANA zone dates are shown in for visitors and for members who have
    # not chosen their own (9.3).
    {
        name    => 'default_timezone',
        env     => 'GPFORUM_DEFAULT_TIMEZONE',
        default => 'UTC',
        check   => 'timezone',
        section => 'application',
        summary => 'The IANA time zone dates are shown in until a member'
          . ' chooses one.',
        example => 'Europe/Rome',
    },
    {
        name    => 'public_base_url',
        env     => 'GPFORUM_PUBLIC_BASE_URL',
        default => 'http://127.0.0.1:3000',
        check   => 'public_url',
        section => 'application',
        summary => 'The address members reach the forum at, used in every'
          . ' link GPForum mails; https in production.',
        operator => 1,
        example  => 'https://forum.example.com',
    },
    {
        name    => 'session_secret',
        env     => 'GPFORUM_SESSION_SECRET',
        default => $DEVELOPMENT_SESSION_SECRET,
        check   => 'session_secret',
        section => 'security',
        summary => 'Signs session cookies: a long random string, at least'
          . " $MINIMUM_PRODUCTION_SECRET characters in production.",
        operator => 1,
        generate => $SECRET_GENERATOR,
    },
    {
        name    => 'previous_session_secrets',
        env     => 'GPFORUM_SESSION_SECRETS',
        type    => 'list',
        check   => 'previous_secrets',
        section => 'security',
        summary => 'Earlier session secrets, comma separated, still accepted'
          . ' while a new one rolls out.',
    },
    {
        name     => 'database_dsn',
        env      => 'GPFORUM_DATABASE_DSN',
        default  => 'dbi:Pg:dbname=gpforum;host=127.0.0.1;port=5432',
        check    => 'required',
        section  => 'database',
        summary  => 'The PostgreSQL database, as a DBI data source.',
        operator => 1,
    },
    {
        name     => 'database_user',
        env      => 'GPFORUM_DATABASE_USER',
        default  => 'gpforum',
        check    => 'required',
        section  => 'database',
        summary  => 'The PostgreSQL role GPForum connects as.',
        operator => 1,
    },
    {
        name    => 'database_password',
        env     => 'GPFORUM_DATABASE_PASSWORD',
        default => q{},
        section => 'database',
        summary => q{That role's password; empty when PostgreSQL trusts the}
          . ' connection or ~/.pgpass holds it.',
        operator => 1,
    },
    {
        name    => 'database_statement_timeout_ms',
        env     => 'GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS',
        default => 15_000,
        type    => 'integer',
        check   => 'non_negative',
        section => 'database',
        summary => 'Milliseconds a query may run before PostgreSQL cancels it;'
          . ' 0 means no limit.',
    },
    {
        name    => 'database_idle_in_transaction_timeout_ms',
        env     => 'GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS',
        default => 10_000,
        type    => 'integer',
        check   => 'non_negative',
        section => 'database',
        summary => 'Milliseconds a transaction may sit idle before PostgreSQL'
          . ' ends it; 0 means no limit.',
    },
    {
        name    => 'database_lock_timeout_ms',
        env     => 'GPFORUM_DATABASE_LOCK_TIMEOUT_MS',
        default => 3_000,
        type    => 'integer',
        check   => 'non_negative',
        section => 'database',
        summary => 'Milliseconds a statement waits for a lock; 0 means no'
          . ' limit.',
    },

    # Search's own budget (8.10). A search holds a web worker for as long as
    # the database takes, and there are few workers, so it is cut off well
    # before the statement_timeout every other query gets; the page then says
    # search is degraded. An operator who lowered
    # GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS below it -- to shed load, say --
    # would have given search more time than anything else, so it is held to
    # the connection's. Zero there is no timeout at all, and zero for search
    # already means the connection's: both are left as they are. Search ranks
    # only the newest search_candidate_limit matches, so a word most documents
    # hold costs the same on any forum size.
    {
        name    => 'search_statement_timeout_ms',
        env     => 'GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS',
        default => 2_000,
        type    => 'integer',
        check   => 'non_negative',
        within  => 'database_statement_timeout_ms',
        section => 'search',
        summary => q{Milliseconds a search may run, at most the database's}
          . ' limit; 0 uses that limit.',
    },
    {
        name    => 'search_candidate_limit',
        env     => 'GPFORUM_SEARCH_CANDIDATE_LIMIT',
        default => 1_000,
        type    => 'integer',
        check   => 'positive',
        section => 'search',
        summary => 'How many of the newest matches a search ranks.',
    },

    # auto, the default, is worked out from the host by
    # automatic_web_processes; a number is taken as it is.
    {
        name      => 'web_processes',
        env       => 'GPFORUM_WEB_PROCESSES',
        default   => $AUTOMATIC,
        type      => 'integer',
        automatic => 1,
        check     => 'process_count',
        section   => 'processes',
        summary   => 'Web processes; auto runs as many as the CPUs carry.',
    },
    {
        name    => 'worker_processes',
        env     => 'GPFORUM_WORKER_PROCESSES',
        default => 2,
        type    => 'integer',
        check   => 'process_count',
        section => 'processes',
        summary => 'No longer used.',
        retired => 1,
    },
    {
        name    => 'realtime_processes',
        env     => 'GPFORUM_REALTIME_PROCESSES',
        default => 1,
        type    => 'integer',
        check   => 'process_count',
        section => 'processes',
        summary => 'No longer used.',
        retired => 1,
    },
    {
        name    => 'runtime_listen',
        env     => 'GPFORUM_RUNTIME_LISTEN',
        default => 'http://127.0.0.1:8080',
        check   => 'listen',
        section => 'processes',
        summary => 'Where the web server listens, comma separated; the proxy'
          . ' forwards here.',
    },
    {
        name    => 'runtime_pid_file',
        env     => 'GPFORUM_RUNTIME_PID_FILE',
        default => 'hypnotoad.pid',
        check   => 'required',
        section => 'processes',
        summary => q{Hypnotoad's pid file; a relative path starts at the}
          . ' runtime directory systemd makes, or the code directory.',
    },
    {
        name    => 'runtime_worker_policy',
        env     => 'GPFORUM_RUNTIME_WORKER_POLICY',
        default => 'cap-to-cpu',
        one_of  => [qw(configured cap-to-cpu)],
        section => 'processes',
        summary => 'configured runs the web processes as set; cap-to-cpu'
          . ' holds them to what the CPUs carry.',
    },
    {
        name    => 'runtime_max_web_per_cpu',
        env     => 'GPFORUM_RUNTIME_MAX_WEB_PER_CPU',
        default => 2,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Web processes per CPU that auto and cap-to-cpu allow.',
    },
    {
        name    => 'runtime_backlog',
        env     => 'GPFORUM_RUNTIME_BACKLOG',
        default => 256,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Connections the kernel queues before the web server'
          . ' accepts them.',
    },
    {
        name    => 'runtime_clients',
        env     => 'GPFORUM_RUNTIME_CLIENTS',
        default => 250,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Connections each web process serves at once.',
    },
    {
        name    => 'runtime_requests',
        env     => 'GPFORUM_RUNTIME_REQUESTS',
        default => 1_000,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Requests a web process serves before it is replaced.',
    },
    {
        name    => 'runtime_keep_alive',
        env     => 'GPFORUM_RUNTIME_KEEP_ALIVE_TIMEOUT',
        default => 5,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Seconds an idle keep-alive connection stays open.',
    },
    {
        name    => 'runtime_inactivity',
        env     => 'GPFORUM_RUNTIME_INACTIVITY_TIMEOUT',
        default => 30,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Seconds a connection may stay silent before it is closed.',
    },
    {
        name    => 'runtime_graceful_timeout',
        env     => 'GPFORUM_RUNTIME_GRACEFUL_TIMEOUT',
        default => 20,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Seconds a stopping web process has to finish its requests.',
    },
    {
        name    => 'runtime_heartbeat_interval',
        env     => 'GPFORUM_RUNTIME_HEARTBEAT_INTERVAL',
        default => 5,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => q{Seconds between a web process's heartbeats.},
    },
    {
        name    => 'runtime_heartbeat_timeout',
        env     => 'GPFORUM_RUNTIME_HEARTBEAT_TIMEOUT',
        default => 5,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Seconds without a heartbeat before a web process is'
          . ' replaced.',
    },
    {
        name    => 'runtime_upgrade_timeout',
        env     => 'GPFORUM_RUNTIME_UPGRADE_TIMEOUT',
        default => 60,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Seconds a zero-downtime upgrade waits for the new'
          . ' processes.',
    },
    {
        name    => 'runtime_spare_processes',
        env     => 'GPFORUM_RUNTIME_SPARE_PROCESSES',
        default => 1,
        type    => 'integer',
        check   => 'positive',
        section => 'processes',
        summary => 'Extra web processes started ahead of need during a'
          . ' graceful restart.',
    },
    {
        name    => 'runtime_proxy',
        env     => 'GPFORUM_RUNTIME_PROXY',
        default => 1,
        type    => 'boolean',
        check   => 'boolean',
        section => 'processes',
        summary => 'A reverse proxy is in front (on or off); on believes its'
          . ' X-Forwarded-For.',
    },
    {
        name    => 'runtime_trusted_proxies',
        env     => 'GPFORUM_RUNTIME_TRUSTED_PROXIES',
        default => '127.0.0.1,::1',
        check   => 'trusted_when_proxied',
        section => 'processes',
        summary => 'The proxies whose X-Forwarded-For is believed, comma'
          . ' separated; the shipped proxies run on this host.',
        example => '10.0.0.5',
    },
    {
        name    => 'os_reuseport',
        env     => 'GPFORUM_OS_REUSEPORT',
        default => 'auto',
        one_of  => [qw(auto on off)],
        section => 'operating_system',
        summary => 'SO_REUSEPORT on the listen socket: auto, on or off.',
    },
    {
        name    => 'os_sendfile',
        env     => 'GPFORUM_OS_SENDFILE',
        default => 'auto',
        one_of  => [qw(auto on off)],
        section => 'operating_system',
        summary => 'sendfile for static files: auto, on or off.',
    },
    {
        name    => 'os_worker_priority',
        env     => 'GPFORUM_OS_WORKER_PRIORITY',
        default => 'auto',
        one_of  => [qw(auto on off)],
        section => 'operating_system',
        summary => 'A lower priority for background work: auto, on or off.',
    },
    {
        name    => 'os_static_xsendfile',
        env     => 'GPFORUM_OS_STATIC_XSENDFILE',
        default => 'auto',
        one_of  => [qw(auto on off)],
        section => 'operating_system',
        summary => q{Static files through the proxy's X-Sendfile: auto, on or}
          . ' off.',
    },
    {
        name    => 'os_affinity',
        env     => 'GPFORUM_OS_AFFINITY',
        default => 'off',
        one_of  => [qw(off manual)],
        section => 'operating_system',
        summary => 'No longer used.',
        retired => 1,
    },
    {
        name    => 'os_min_recommended_workers',
        env     => 'GPFORUM_OS_MIN_RECOMMENDED_WORKERS',
        default => 2,
        type    => 'integer',
        check   => 'positive',
        section => 'operating_system',
        summary => 'The worker count below which the host preflight warns.',
    },
    {
        name    => 'os_max_open_file_descriptors',
        env     => 'GPFORUM_OS_MAX_OPEN_FILE_DESCRIPTORS',
        default => 65_536,
        type    => 'integer',
        check   => 'positive',
        section => 'operating_system',
        summary => 'The open-file limit the host preflight expects.',
    },

    # auto, the default, is sized from the host's memory by
    # automatic_local_cache_max_entries.
    {
        name      => 'local_cache_max_entries',
        env       => 'GPFORUM_LOCAL_CACHE_MAX_ENTRIES',
        default   => $AUTOMATIC,
        type      => 'integer',
        automatic => 1,
        check     => 'positive',
        section   => 'cache',
        summary   => 'Entries each web process keeps in its own cache; auto'
          . q{ sizes them from the host's memory.},
    },
    {
        name    => 'category_cache_ttl_seconds',
        env     => 'GPFORUM_CATEGORY_CACHE_TTL_SECONDS',
        default => 60,
        type    => 'integer',
        check   => 'positive',
        section => 'cache',
        summary => 'Seconds a cached category list is kept.',
    },
    {
        name    => 'realtime_listener_enabled',
        env     => 'GPFORUM_REALTIME_LISTENER_ENABLED',
        default => 1,
        type    => 'boolean',
        check   => 'boolean',
        section => 'realtime',
        summary => 'Internal: live updates through PostgreSQL LISTEN; leave'
          . ' it on.',
    },
    {
        name    => 'realtime_listener_poll_interval_seconds',
        env     => 'GPFORUM_REALTIME_LISTENER_POLL_INTERVAL_SECONDS',
        default => 1,
        type    => 'integer',
        check   => 'positive',
        section => 'realtime',
        summary => 'Seconds between checks for live-update notifications.',
    },
    {
        name    => 'realtime_listener_reconnect_backoff_seconds',
        env     => 'GPFORUM_REALTIME_LISTENER_RECONNECT_BACKOFF_SECONDS',
        default => 5,
        type    => 'integer',
        check   => 'positive',
        section => 'realtime',
        summary => 'Seconds before the live-update listener reconnects.',
    },
    {
        name    => 'realtime_listener_heartbeat_interval_seconds',
        env     => 'GPFORUM_REALTIME_LISTENER_HEARTBEAT_INTERVAL_SECONDS',
        default => 30,
        type    => 'integer',
        check   => 'positive',
        section => 'realtime',
        summary => 'Seconds between live-update heartbeats.',
    },
    {
        name    => 'warmup_enabled',
        env     => 'GPFORUM_WARMUP_ENABLED',
        default => 1,
        type    => 'boolean',
        check   => 'boolean',
        section => 'processes',
        summary => 'Render the main pages once before the workers fork, so'
          . ' their first requests are as fast as the rest (on or off).',
    },
    {
        name    => 'minion_enabled',
        env     => 'GPFORUM_MINION_ENABLED',
        default => 0,
        type    => 'boolean',
        check   => 'boolean',
        section => 'jobs',
        summary => 'Also run background jobs through Minion (on or off); the'
          . ' outbox worker needs no Minion.',
    },
    {
        name    => 'minion_pg_url',
        env     => 'GPFORUM_MINION_PG_URL',
        default => q{},
        check   => 'required_by_minion',
        section => 'jobs',
        summary => q{Minion's PostgreSQL URL, required while Minion is on.},
        example => 'postgresql://gpforum@/gpforum',
    },

    # How long the event log is kept: the partitions job lists each monthly
    # partition older than this as due to detach. It was the size profile's
    # (365 days in production-small, 730 in production-medium); it is one
    # setting now, at production-small's value.
    {
        name    => 'event_retention_days',
        env     => 'GPFORUM_EVENT_RETENTION_DAYS',
        default => 365,
        type    => 'integer',
        check   => 'positive',
        section => 'jobs',
        summary => 'Days the event log is kept before its monthly partitions'
          . ' are listed as due to detach.',
    },
    {
        name    => 'metrics_token',
        env     => 'GPFORUM_METRICS_TOKEN',
        default => q{},
        check   => 'metrics_token',
        section => 'security',
        summary => 'The token /metrics and the full /health/ready report ask'
          . ' for; required in staging and production.',
        operator => 1,
        generate => $SECRET_GENERATOR,
    },
    {
        name    => 'previous_metrics_tokens',
        env     => 'GPFORUM_METRICS_TOKENS',
        type    => 'list',
        section => 'security',
        summary => 'Earlier metrics tokens, comma separated, still accepted'
          . ' while scrapers move to the new one.',
    },

    # Optional everywhere (D2): without one each process keeps its own cache,
    # which is all a single host needs.
    {
        name    => 'glifistore_url',
        env     => 'GPFORUM_GLIFISTORE_URL',
        default => q{},
        check   => 'glifistore',
        section => 'cache',
        summary => 'A GlifiStore shared cache; empty keeps each process to its'
          . ' own cache, which suits one host.',
        example => 'tcp://127.0.0.1:7379',
    },
    {
        name    => 'session_touch_interval_seconds',
        env     => 'GPFORUM_SESSION_TOUCH_INTERVAL_SECONDS',
        default => 300,
        type    => 'integer',
        check   => 'positive',
        section => 'security',
        summary => q{How often, at most, a signed-in member's session is}
          . ' marked as used.',
    },

    # Forum pages are read through a rate limit per visitor -- a member, or
    # an address -- so one client cannot read the whole forum in a loop. A
    # capacity run from one address raises it for its window (stress-load.md).
    {
        name    => 'forum_read_rate_limit',
        env     => 'GPFORUM_FORUM_READ_RATE_LIMIT',
        default => 60,
        type    => 'integer',
        check   => 'positive',
        section => 'security',
        summary => 'Forum pages one visitor may read per minute; raise it only'
          . ' for a load test from one address.',
    },

    # log writes each message, link included, to the log: development's
    # default, so a laptop without a mail server can still verify an account.
    # test keeps messages in memory for the test suite.
    {
        name         => 'mail_transport',
        env          => 'GPFORUM_MAIL_TRANSPORT',
        default      => 'test',
        check        => 'mail_transport',
        one_of       => [qw(sendmail smtp log test)],
        default_when => [
            [ environment => \@DEPLOYED,      'sendmail' ],
            [ environment => ['development'], 'log' ],
        ],
        section => 'mail',
        summary => 'How mail leaves: sendmail (the local mail server), smtp,'
          . ' or log (development only: writes it to the log).',
        operator => 1,
        example  => 'sendmail',
    },
    {
        name    => 'mail_from',
        env     => 'GPFORUM_MAIL_FROM',
        default => 'noreply@localhost',
        check   => 'mail_from',
        section => 'mail',
        summary => 'The sender of every message: an address at the forum'
          . q{'s own domain.},
        operator => 1,
        example  => 'forum@forum.example.com',
    },
    {
        name          => 'smtp_host',
        env           => 'GPFORUM_SMTP_HOST',
        default       => q{},
        check         => 'smtp_host',
        section       => 'mail',
        summary       => 'The SMTP server, when mail leaves by smtp.',
        example       => 'smtp.example.com',
        operator_when => [ mail_transport => 'smtp' ],
    },
    {
        name          => 'smtp_port',
        env           => 'GPFORUM_SMTP_PORT',
        default       => 587,
        type          => 'integer',
        check         => 'positive',
        section       => 'mail',
        summary       => 'The SMTP port; 587 is the submission port.',
        operator_when => [ mail_transport => 'smtp' ],
    },
    {
        name          => 'smtp_username',
        env           => 'GPFORUM_SMTP_USERNAME',
        default       => q{},
        section       => 'mail',
        summary       => 'The SMTP login, when the server asks for one.',
        operator_when => [ mail_transport => 'smtp' ],
    },
    {
        name          => 'smtp_password',
        env           => 'GPFORUM_SMTP_PASSWORD',
        default       => q{},
        section       => 'mail',
        summary       => 'The SMTP password.',
        operator_when => [ mail_transport => 'smtp' ],
    },

    # TLS follows the port unless the operator says otherwise: STARTTLS on
    # 587, the submission port, implicit TLS on 465. GPFORUM_SMTP_SSL, a
    # boolean that meant STARTTLS and defaulted to off -- a password sent in
    # the clear on 587 -- is still read, on as starttls and off as off.
    {
        name         => 'smtp_tls',
        env          => 'GPFORUM_SMTP_TLS',
        default      => 'starttls',
        one_of       => [qw(starttls implicit off)],
        default_when => [ [ smtp_port => [$IMPLICIT_TLS_PORT], 'implicit' ] ],
        aliases      => [
            {
                env     => 'GPFORUM_SMTP_SSL',
                refusal => 'config.not_boolean',
                values  => {
                    ( map { $_ => 'starttls' } qw(1 yes true on) ),
                    ( map { $_ => 'off' } qw(0 no false off) ),
                },
            }
        ],
        section => 'mail',
        summary => 'TLS to the SMTP server: starttls, implicit or off; it'
          . ' follows the port, starttls on 587 and implicit on 465.',
    },

    # The free antivirus the operating system installed (ADR 0108): clamd, a
    # command, or none. The socket defaults to the one the OS package
    # declares. Deployed profiles scan uploads with the system's clamd unless
    # the operator says otherwise; development and test do not assume one is
    # installed.
    {
        name         => 'antivirus',
        env          => 'GPFORUM_ANTIVIRUS',
        default      => 'none',
        one_of       => [qw(clamd command none)],
        default_when => [ [ environment => \@DEPLOYED, 'clamd' ] ],
        section      => 'antivirus',
        summary      => 'How uploads are scanned: clamd, command or none.',
        operator     => 1,
        example      => 'clamd',
    },
    {
        name    => 'antivirus_socket',
        env     => 'GPFORUM_ANTIVIRUS_SOCKET',
        default => q{},
        section => 'antivirus',
        summary => q{The clamd socket; empty uses the one the system's package}
          . ' installs.',
        example => '/var/run/clamav/clamd.ctl',
    },
    {
        name    => 'antivirus_command',
        env     => 'GPFORUM_ANTIVIRUS_COMMAND',
        type    => 'words',
        check   => 'command_for_antivirus',
        section => 'antivirus',
        summary => 'The scanner run on each upload when the antivirus is'
          . ' command.',
        example => 'clamscan --no-summary',
    },
    {
        name         => 'antivirus_timeout_seconds',
        env          => 'GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS',
        default      => $CLAMD_TIMEOUT,
        type         => 'integer',
        check        => 'positive',
        default_when => [ [ antivirus => ['command'], $COMMAND_TIMEOUT ] ],
        section      => 'antivirus',
        summary      => 'Seconds a scan may take.',
    },
);
const my %SETTING_NAMED => map { $_->{name}          => $_ } @SETTINGS;
const my %POSITION      => map { $SETTINGS[$_]{name} => $_ } 0 .. $#SETTINGS;

# What validate refuses, by the name a setting's check gives. Each rule
# returns a problem (see _problem_of), or undef when the value is fine.
# Const::Fast cannot copy code references, so the table is a plain hash.
my %RULE = (
    required              => \&_rule_required,
    positive              => \&_rule_positive,
    non_negative          => \&_rule_non_negative,
    boolean               => \&_rule_boolean,
    process_count         => \&_rule_process_count,
    timezone              => \&_rule_timezone,
    locale                => \&_rule_locale,
    public_url            => \&_rule_public_url,
    session_secret        => \&_rule_session_secret,
    previous_secrets      => \&_rule_previous_secrets,
    metrics_token         => \&_rule_metrics_token,
    listen                => \&_rule_listen,
    trusted_when_proxied  => \&_rule_trusted_when_proxied,
    required_by_minion    => \&_rule_required_by_minion,
    glifistore            => \&_rule_glifistore,
    mail_transport        => \&_rule_mail_transport,
    mail_from             => \&_rule_mail_from,
    smtp_host             => \&_rule_smtp_host,
    command_for_antivirus => \&_rule_command_for_antivirus,
);

# A list's default is a fresh empty array for each configuration; an
# automatic setting's is worked out when first read.
for my $setting (@SETTINGS) {
    my $name = $setting->{name};
    if ( $setting->{automatic} ) {
        my $builder = "automatic_$name";
        has $name => sub ($self) { return $self->$builder; };
        next;
    }

    my $is_list = $setting->{type} eq 'list' || $setting->{type} eq 'words';
    has $name => $is_list ? sub { return [] } : $setting->{default};
}

# The variables of retired settings the environment set, for the warning the
# start-up logs (Bootstrap::Config).
has retired_settings => sub { return [] };

# The old names the environment still set, each as { setting, variable,
# replacement, value }: the old variable, the new one and the value it now
# holds, for the warning the start-up logs. An old value (GPFORUM_ENV=
# production-small) is named under its own variable, with old, the value
# the environment wrote.
has renamed_settings => sub { return [] };

sub from_environment ( $class, $environment = undef ) {
    $environment //= \%ENV;

    my ( %read, @problems, @retired, @renamed );
    for my $setting (@SETTINGS) {
        my ( $source, $misread ) =
          _renamed( $environment, $setting, \@renamed, \%read );
        my ( $value, $problem ) = _read( $source, $setting, \%read );
        $problem //= $misread;
        $value = _old_value( $setting, $value, \@renamed );

        # A retired setting never stops a start, whatever an old environment
        # file holds: a value that does not parse keeps the default, and the
        # start names the variable to remove.
        if ( $setting->{retired} ) {
            if ( _is_set( $environment, $setting ) ) {
                push @retired, $setting->{env};
            }
            $problem = undef;
        }
        push @problems, $problem // ();
        next if !defined $value;

        $read{ $setting->{name} } = $value;
    }
    push @problems, _test_transport_problem( $environment, \%read ) // ();

    my $self = $class->new(
        %read,
        retired_settings => \@retired,
        renamed_settings =>
          [ map { +{ %{$_}, value => $read{ $_->{setting} } } } @renamed ],
    );
    my %refused = map { $_->{variable} => 1 } @problems;
    push @problems, grep { !$refused{ $_->{variable} } } @{ $self->problems };
    _refuse(
        [
            sort { $POSITION{ $a->{setting} } <=> $POSITION{ $b->{setting} } }
              @problems
        ]
    );

    return $self;
}

sub validate ($self) {
    _refuse( $self->problems );

    return $self;
}

# Every problem, not just the first: an operator fixes them all in one edit
# instead of learning of one per start.
sub problems ($self) {
    return [ grep { defined } map { _problem( $self, $_ ) } @SETTINGS ];
}

sub settings ($class) {
    return [ map { +{ %{$_} } } @SETTINGS ];
}

# GlifiStore is optional everywhere (D2). Kept, always false, for the callers
# that still ask.
sub requires_glifistore ($self) {
    return 0;
}

sub requires_secure_transport ($self) {
    return _is_deployed( $self->environment );
}

sub is_production ($self) {
    return _is_production( $self->environment );
}

sub signing_secrets ($self) {
    return _unique_head( $self->session_secret,
        $self->previous_session_secrets );
}

sub accepted_metrics_tokens ($self) {
    return _unique_head( $self->metrics_token, $self->previous_metrics_tokens );
}

sub environment_requires_glifistore ( $, $environment ) {
    return 0;
}

# GPFORUM_SMTP_SSL's old reading, for the callers that still ask: 1 when the
# SMTP connection is encrypted, either way.
sub smtp_ssl ($self) {
    return $self->smtp_tls eq 'off' ? 0 : 1;
}

# Mail sent by smtp with TLS on, from a Perl that cannot load the TLS module,
# fails at the first message -- a sign-up's confirmation, a password reset --
# long after the start. It is not one of problems(): what this Perl has
# installed is a fact about the host, not the settings, and the test suite
# builds configurations on hosts without it. Every place that checks the
# settings the way the service's start does asks it here, so doctor,
# mail-check and the front door answer as the start-up does
# (Bootstrap::Config). undef when mail does not leave by smtp, TLS is off, or
# the module loads ($can_tls, by default smtp_can_tls's answer).
sub smtp_tls_problem ( $self, $can_tls = undef ) {
    return undef
      if $self->mail_transport ne 'smtp' || $self->smtp_tls eq 'off';
    return undef if $can_tls // $self->smtp_can_tls;

    return {
        key        => 'config.smtp_tls_module',
        setting    => 'smtp_tls',
        variable   => $SETTING_NAMED{smtp_tls}{env},
        value      => $self->smtp_tls,
        parameters => { module => $TLS_MODULE },
        generate   => undef,
        example    => undef,
    };
}

# The configuration, or GPForum::X::Config for its smtp_tls_problem, in
# English like every other refusal of from_environment.
sub assert_smtp_tls ( $self, $can_tls = undef ) {
    my $problem = $self->smtp_tls_problem($can_tls);
    _refuse( $problem ? [$problem] : [] );

    return $self;
}

# Whether Net::SMTP, under Email::Sender, can speak TLS, asked of Net::SMTP
# itself: it loads the TLS module, at the version it needs, when it is
# loaded. Asked once per process; the answer does not change while it runs.
sub smtp_can_tls ($invocant) {
    state $can = do {
        require Net::SMTP;
        Net::SMTP->can_ssl ? 1 : 0;
    };

    return $can;
}

# As many web processes as cap-to-cpu lets the CPUs carry, at least one and
# at most $MAXIMUM_AUTOMATIC_WEB_PROCESSES. The CPUs are the ones the host's
# profile counts for a worker (OS::Base::worker_cpu_count: all of them, or
# fewer where some cores are worth less), counted once per process: a host
# does not gain any while GPForum runs, and counting them can mean running
# sysctl.
sub automatic_web_processes ($self) {
    return min(
        $MAXIMUM_AUTOMATIC_WEB_PROCESSES,
        max(
            1,
            ( $self->host_worker_cpus || 1 ) * $self->runtime_max_web_per_cpu
        )
    );
}

# Each web process's own cache, sized from the host's memory: an equal part,
# for each web process, of an eighth of it, at about 16 KiB an entry, rounded
# down to a power of two between 1024 and 16384; 4096 when the memory cannot
# be measured.
sub automatic_local_cache_max_entries ($self) {
    my $bytes = $self->host_memory_bytes;
    return $UNMEASURED_CACHE if !$bytes;

    my $entries =
      $bytes / $CACHE_MEMORY_SHARE /
      max( 1, $self->web_processes ) /
      $CACHE_ENTRY_BYTES;
    my $power = $MINIMUM_AUTOMATIC_CACHE;
    while ( $power * 2 <= $entries && $power < $MAXIMUM_AUTOMATIC_CACHE ) {
        $power *= 2;
    }

    return $power;
}

# What the host gives GPForum, each asked once per process: a host does not
# gain CPUs or memory while GPForum runs, and asking can mean running sysctl.
# The CPUs a worker counts (OS::Base::worker_cpu_count: all of them, or fewer
# where some cores are worth less), every logical CPU, and the memory in
# bytes (undef when it cannot be measured).
sub host_worker_cpus ($self) {
    state $cpus = GPForum::OS->detect->worker_cpu_count;

    return $cpus;
}

sub host_cpus ($self) {
    state $cpus = GPForum::OS->detect->cpu_count;

    return $cpus;
}

sub host_memory_bytes ($self) {
    state $bytes =
      GPForum::OS::Memory->new->detect( GPForum::OS->detect->name )->{bytes};

    return $bytes;
}

# How this node is sized, for gpforum doctor: the host's CPUs and memory,
# and each size worked out from them that the node runs with -- a size the
# operator set to something else is theirs, not the host's (audit D1').
sub sizing ($self) {
    my %sizes;
    for my $setting ( grep { $_->{automatic} } @SETTINGS ) {
        my $name    = $setting->{name};
        my $builder = "automatic_$name";
        my $value   = $self->$name;
        if ( $value == $self->$builder ) {
            $sizes{$name} = $value;
        }
    }

    return {
        cpus         => $self->host_cpus,
        memory_bytes => $self->host_memory_bytes,
        sizes        => \%sizes,
    };
}

sub os_feature_settings ($self) {
    return {
        reuseport        => $self->os_reuseport,
        sendfile         => $self->os_sendfile,
        worker_priority  => $self->os_worker_priority,
        static_xsendfile => $self->os_static_xsendfile,
        affinity         => $self->os_affinity,
    };
}

sub os_preflight_settings ($self) {
    return {
        min_recommended_workers   => $self->os_min_recommended_workers,
        max_open_file_descriptors => $self->os_max_open_file_descriptors,
    };
}

# The addresses whose X-Forwarded-For is believed. Only the loopback by
# default: the shipped proxies run on the same host. Believing any sender, as
# before, let a client that reached the application directly name its own
# address, and with it its rate-limit bucket.
sub runtime_trusted_proxy_list ($self) {
    return [ _csv_items( $self->runtime_trusted_proxies ) ];
}

sub runtime_listen_locations ($self) {
    return [ _csv_items( $self->runtime_listen ) ];
}

# The statements every connection runs once it is made: the timeouts, the
# application's name, the message locale and the search similarity. The
# query statistics know them by these texts, so a worker's first request,
# which makes its connection, is not charged six statements it did not ask
# for.
sub database_session_settings ($self) {
    return [
        'SET statement_timeout = ' . $self->database_statement_timeout_ms,
        'SET idle_in_transaction_session_timeout = '
          . $self->database_idle_in_transaction_timeout_ms,
        'SET lock_timeout = ' . $self->database_lock_timeout_ms,
        $SET_APPLICATION_NAME,
        $SET_MESSAGE_LOCALE,
        $SET_SEARCH_SIMILARITY,
    ];
}

sub database_connect_info ($self) {
    return (
        $self->database_dsn,
        $self->database_user,
        $self->database_password,
        {
            AutoCommit     => 1,
            RaiseError     => 1,
            PrintError     => 0,
            on_connect_do  => $self->database_session_settings,
            pg_enable_utf8 => 1,
        },
    );
}

# Throws one X::Config carrying every problem, its message the whole report
# in English. Bootstrap::Config renders the same problems in the operator's
# language.
sub _refuse ($problems) {
    return if !@{$problems};

    GPForum::X::Config->throw(
        message  => GPForum::Config::Report->render($problems),
        problems => $problems,
    );
}

# One setting's value from the environment, and the problem reading it when
# there is one. An unset or empty variable takes the default; a value that
# does not parse is a problem, and the setting keeps its default so the rest
# can still be checked. An automatic setting left at auto reads as undef, for
# its builder. A variable that is not there is asked about with exists, never
# read: a read-only hash, such as a Const::Fast one, refuses a read of a key it
# does not hold.
sub _read ( $environment, $setting, $read ) {
    my $raw =
      _is_set( $environment, $setting )
      ? $environment->{ $setting->{env} }
      : undef;
    my $value = $raw // _default( $setting, $read );
    my $type  = $setting->{type};

    if ( $type eq 'list' ) {
        return [ _csv_items($value) ];
    }
    if ( $type eq 'words' ) {
        return [ grep { length } split /\s+/msx, $value ];
    }
    if ( $type eq 'boolean' ) {
        return _read_boolean( $setting, $value );
    }
    if ( $type eq 'integer' ) {
        return _read_integer( $setting, $value, $read );
    }

    return $value;
}

sub _read_boolean ( $setting, $value ) {
    my $word = lc trim($value);
    if ( exists $BOOLEAN{$word} ) {
        return $BOOLEAN{$word};
    }

    return ( $setting->{default},
        _problem_of( $setting, 'config.not_boolean', $value ) );
}

sub _read_integer ( $setting, $value, $read ) {
    if ( $setting->{automatic} && lc($value) eq $AUTOMATIC ) {
        return undef;
    }
    if ( $value !~ /\A [[:digit:]]+ \z/msx ) {
        my $key =
          $setting->{automatic}
          ? 'config.not_integer_or_auto'
          : 'config.not_integer';
        my $default = $setting->{default};
        return (
            $default eq $AUTOMATIC ? undef : $default,
            _problem_of( $setting, $key, $value )
        );
    }

    my $number = int $value;
    my $limit  = $setting->{within} && $read->{ $setting->{within} };

    return $limit && $number > $limit ? $limit : $number;
}

# The environment as a renamed setting reads it, and the problem reading it:
# when only the old variable is set, its word turned into the new one's
# value, and either way the old name noted for the warning. A word the old
# variable never took is a problem under the name the operator wrote, and
# the setting keeps its default. A setting never renamed, or whose old name
# is not set, reads the environment as it is.
sub _renamed ( $environment, $setting, $renamed, $read ) {
    my ($old) =
      grep { exists $_->{env} && _is_set( $environment, $_ ) }
      @{ $setting->{aliases} };
    return ($environment) if !$old;

    push @{$renamed},
      {
        setting     => $setting->{name},
        variable    => $old->{env},
        replacement => $setting->{env},
      };
    return ($environment) if _is_set( $environment, $setting );

    my $raw  = $environment->{ $old->{env} };
    my $word = lc trim($raw);
    return { $setting->{env} => $old->{values}{$word} }
      if exists $old->{values}{$word};

    return (
        {},
        {
            %{ _problem_of( $setting, $old->{refusal}, $raw ) },
            variable   => $old->{env},
            example    => undef,
            suggestion => "$setting->{env}=" . _default( $setting, $read ),
        }
    );
}

# The value an old one stands for, noted for the warning: GPFORUM_ENV=
# production-medium reads as production. Any other value is left as it is.
sub _old_value ( $setting, $value, $renamed ) {
    return $value if !defined $value || ref $value;

    my ($old) =
      grep { exists $_->{value} && $_->{value} eq $value }
      @{ $setting->{aliases} };
    return $value if !$old;

    push @{$renamed},
      {
        setting     => $setting->{name},
        variable    => $setting->{env},
        replacement => $setting->{env},
        old         => $value,
      };

    return $old->{as};
}

sub _is_set ( $environment, $setting ) {
    my $variable = $setting->{env};

    return
         exists $environment->{$variable}
      && defined $environment->{$variable}
      && length $environment->{$variable} ? 1 : 0;
}

# The default from_environment reads a setting with: the first default_when
# whose setting holds one of its values, else the plain default.
sub _default ( $setting, $read ) {
    for my $case ( @{ $setting->{default_when} // [] } ) {
        my ( $other, $values, $default ) = @{$case};
        if ( any { $_ eq $read->{$other} } @{$values} ) {
            return $default;
        }
    }

    return $setting->{default} // q{};
}

# The first thing wrong with one setting's value, or undef.
sub _problem ( $self, $setting ) {
    my $name = $setting->{name};

    # An automatic setting not given a number is worked out from the host when
    # first read, and is in bounds by construction. Reading it here would count
    # the CPUs -- run sysctl or nproc -- for every configuration checked, in
    # every command, whether it needs the number or not.
    return undef if $setting->{automatic} && !exists $self->{$name};

    # Nothing runs from a retired setting, so no value of it is wrong.
    return undef if $setting->{retired};

    my $value = $self->$name;

    my $rule    = $setting->{check};
    my $problem = $rule ? $RULE{$rule}->( $self, $setting, $value ) : undef;
    if ( defined $problem ) {
        return $problem;
    }

    # An old value -- production-small, in a configuration built with new --
    # is one of them, under the name it now has; the refusal lists only the
    # current ones.
    my $choices = $setting->{one_of};
    my @old =
      map { exists $_->{value} ? $_->{value} : () } @{ $setting->{aliases} };
    if ( $choices && !any { $_ eq ( $value // q{} ) } @{$choices}, @old ) {
        return _choice_problem( $setting, $value, $choices );
    }

    # Held only to a positive limit: zero is no limit, and a negative one is
    # its own setting's problem.
    my $limit = $setting->{within};
    if ( $limit && $self->$limit > 0 && $value > $self->$limit ) {
        return _problem_of(
            $setting,
            'config.not_above',
            $value,
            limit_variable => $SETTING_NAMED{$limit}{env},
            limit          => $self->$limit,
        );
    }

    return undef;
}

# A problem: the catalog key of its sentence, the variable it names, the
# value it refused and the sentence's other placeholders, with an example or
# the command that makes a secret.
sub _problem_of ( $setting, $key, $value, %parameters ) {
    my $example = $setting->{example} // _example_default($setting);

    return {
        key        => $key,
        setting    => $setting->{name},
        variable   => $setting->{env},
        value      => ref $value ? join( q{,}, @{$value} ) : $value // q{},
        parameters => \%parameters,
        generate   => $setting->{generate},
        example    => $example,
    };
}

# The default, as an operator writes it, when a setting has no example of its
# own: on or off for a boolean, nothing for a list.
sub _example_default ($setting) {
    my $type = $setting->{type};
    return undef if $type eq 'list' || $type eq 'words';
    return $setting->{default} ? 'on' : 'off' if $type eq 'boolean';

    return $setting->{default};
}

sub _choice_problem ( $setting, $value, $choices ) {
    my $problem = _problem_of(
        $setting, 'config.one_of', $value,
        choices => join q{, },
        @{$choices}
    );
    my $nearest = _nearest( $value, $choices );
    if ( defined $nearest ) {
        $problem->{suggestion} = "$setting->{env}=$nearest";
        $problem->{example}    = undef;
    }

    return $problem;
}

sub _rule_required ( $self, $setting, $value ) {
    return defined $value && length $value
      ? undef
      : _problem_of( $setting, 'config.required', $value );
}

sub _rule_required_in ( $self, $setting, $value ) {
    return defined $value && length $value
      ? undef
      : _problem_of( $setting, 'config.required_in', $value,
        environment => $self->environment );
}

sub _rule_positive ( $self, $setting, $value ) {
    return _at_least( $setting, $value, 1 );
}

sub _rule_non_negative ( $self, $setting, $value ) {
    return _at_least( $setting, $value, 0 );
}

sub _at_least ( $setting, $value, $minimum ) {
    return $value < $minimum
      ? _problem_of( $setting, 'config.at_least', $value, minimum => $minimum )
      : undef;
}

sub _rule_boolean ( $self, $setting, $value ) {
    return defined $value && "$value" =~ /\A [01] \z/msx
      ? undef
      : _problem_of( $setting, 'config.not_boolean', $value );
}

sub _rule_process_count ( $self, $setting, $value ) {
    if ( $value < 1 ) {
        return _at_least( $setting, $value, 1 );
    }

    return $value > $MAXIMUM_PROCESS_COUNT
      ? _problem_of( $setting, 'config.at_most', $value,
        maximum => $MAXIMUM_PROCESS_COUNT )
      : undef;
}

sub _rule_timezone ( $self, $setting, $value ) {
    return DateTime::TimeZone->is_valid_name($value)
      ? undef
      : _problem_of( $setting, 'config.timezone', $value );
}

# A language tag the forum reads as one of its locales, as
# GPForum::Service::I18N::Locale reads it: any case, - or _ between the parts,
# so it, IT, it-IT and it_IT are all Italian. it_IT.UTF-8, a POSIX locale
# rather than a tag, the forum would quietly show in English: it is refused,
# with the locale it names as the suggestion.
sub _rule_locale ( $self, $setting, $value ) {
    my $required = _rule_required( $self, $setting, $value );
    return $required if $required;

    my $locales = _shipped_locales();
    return undef if !@{$locales};

    my $tag        = ( lc trim($value) ) =~ tr/_/-/r;
    my ($language) = $tag =~ /\A ([[:lower:]]{2,8}) /msx;
    my $shipped    = defined $language && any { $_ eq $language } @{$locales};
    return undef if $shipped && $tag =~ $LANGUAGE_TAG;

    my $problem = _choice_problem( $setting, $value, $locales );
    if ($shipped) {
        $problem->{suggestion} = "$setting->{env}=$language";
        $problem->{example}    = undef;
    }

    return $problem;
}

sub _rule_public_url ( $self, $setting, $value ) {
    my $required = _rule_required( $self, $setting, $value );
    return $required if $required;

    my ( $scheme, $host ) = $value =~ $PUBLIC_URL;
    if ( !$scheme ) {
        return _problem_of( $setting, 'config.url', $value );
    }

    my $environment = $self->environment;
    if ( _is_production($environment) && lc $scheme ne 'https' ) {
        return _problem_of( $setting, 'config.https', $value,
            environment => $environment );
    }

    return _is_deployed($environment)
      ? _placeholder( $setting, 'config.placeholder_url', $value, $host,
        $environment )
      : undef;
}

# An address under a name kept for examples, which a deployed forum would
# put in every link and every sender it mails. No example is offered: the
# template's is the one that was refused.
sub _placeholder ( $setting, $key, $value, $host, $environment ) {
    return undef if $host !~ $EXAMPLE_HOST;

    return {
        %{
            _problem_of( $setting, $key, $value, environment => $environment )
        },
        example => undef,
    };
}

# Staging and production sign with their own secret; production's is long.
sub _rule_session_secret ( $self, $setting, $value ) {
    my $environment = $self->environment;
    if ( _is_deployed($environment) && $value eq $DEVELOPMENT_SESSION_SECRET ) {
        return _rule_required_in( $self, $setting, q{} );
    }
    my $required = _rule_required( $self, $setting, $value );
    return $required if $required;

    return _is_production($environment)
      && length $value < $MINIMUM_PRODUCTION_SECRET
      ? _problem_of(
        $setting, 'config.short_secret',
        $value,
        environment => $environment,
        length      => length $value,
        minimum     => $MINIMUM_PRODUCTION_SECRET,
      )
      : undef;
}

sub _rule_previous_secrets ( $self, $setting, $value ) {
    return undef if !_is_deployed( $self->environment );

    my $development =
      any { defined && $_ eq $DEVELOPMENT_SESSION_SECRET } @{ $value || [] };

    return $development
      ? _problem_of( $setting, 'config.development_secret', q{} )
      : undef;
}

# /metrics never answers unauthenticated where it is deployed.
sub _rule_metrics_token ( $self, $setting, $value ) {
    return _is_deployed( $self->environment )
      ? _rule_required_in( $self, $setting, $value )
      : undef;
}

sub _rule_listen ( $self, $setting, $value ) {
    my $required = _rule_required( $self, $setting, $value );
    return $required if $required;

    my @locations  = _csv_items($value);
    my $unreadable = !@locations || any { $_ !~ $LISTEN_LOCATION } @locations;

    return $unreadable
      ? _problem_of( $setting, 'config.listen', $value )
      : undef;
}

sub _rule_trusted_when_proxied ( $self, $setting, $value ) {
    return $self->runtime_proxy && !@{ $self->runtime_trusted_proxy_list }
      ? _problem_of( $setting, 'config.trusted_proxies', $value,
        proxy_variable => $SETTING_NAMED{runtime_proxy}{env} )
      : undef;
}

sub _rule_required_by_minion ( $self, $setting, $value ) {
    return ( $self->minion_enabled // 0 ) eq '1'
      && !( defined $value && length $value )
      ? _problem_of( $setting, 'config.minion_url', $value,
        minion_variable => $SETTING_NAMED{minion_enabled}{env} )
      : undef;
}

sub _rule_glifistore ( $self, $setting, $value ) {
    return
         defined $value
      && length $value
      && $value !~ $GLIFISTORE_TCP_URL && $value !~ $GLIFISTORE_UNIX_URL
      ? _problem_of( $setting, 'config.glifistore_url', $value )
      : undef;
}

# log only writes mail where an operator reads it: never where members wait
# for it.
sub _rule_mail_transport ( $self, $setting, $value ) {
    my $required = _rule_required( $self, $setting, $value );
    return $required if $required;

    return _is_deployed( $self->environment ) && $value eq 'log'
      ? _problem_of(
        $setting, 'config.log_transport',
        $value,   environment => $self->environment
      )
      : undef;
}

# test keeps mail in memory and sends nothing. It is the plain default, which
# a configuration built with new keeps for the test suite; read from the
# environment, production defaults to sendmail, so test there is one an
# operator wrote, and members would wait for mail that never leaves.
sub _test_transport_problem ( $environment, $read ) {
    my $setting = $SETTING_NAMED{mail_transport};
    return undef
      if !_is_production( $read->{environment} )
      || !_is_set( $environment, $setting )
      || $read->{mail_transport} ne 'test';

    return _problem_of(
        $setting, 'config.test_transport',
        'test',   environment => $read->{environment}
    );
}

# The address a sender names: the part between < and > of one with a
# display name, Forum <forum@forum.example.com>, which the checks below read
# the domain of; the value itself otherwise. Its closing > had kept the
# template's domain from being recognized.
sub _sender_address ($value) {
    my ($address) = $value =~ /< \s* ([^<>]+?) \s* > \s* \z/msx;

    return $address // $value;
}

sub _rule_mail_from ( $self, $setting, $value ) {
    my $required = _rule_required( $self, $setting, $value );
    return $required if $required;

    my $environment = $self->environment;
    my $address     = _sender_address($value);
    if ( _is_production($environment) && $address =~ $LOCAL_SENDER ) {
        return _problem_of(
            $setting, 'config.mail_from_local',
            $value,   environment => $environment
        );
    }

    my ($domain) = $address =~ /\@ ([^@]+) \z/msx;
    return _is_deployed($environment)
      && defined $domain
      ? _placeholder( $setting, 'config.placeholder_mail_from',
        $value, $domain, $environment )
      : undef;
}

sub _rule_smtp_host ( $self, $setting, $value ) {
    return ( $self->mail_transport // q{} ) eq 'smtp'
      && !( defined $value && length $value )
      ? _problem_of( $setting, 'config.smtp_host', $value,
        transport_variable => $SETTING_NAMED{mail_transport}{env} )
      : undef;
}

sub _rule_command_for_antivirus ( $self, $setting, $value ) {
    return $self->antivirus eq 'command' && !@{$value}
      ? _problem_of( $setting, 'config.antivirus_command', $value,
        antivirus_variable => $SETTING_NAMED{antivirus}{env} )
      : undef;
}

# The choice an operator most likely meant: one the value begins (prod for
# production), one that begins the value (warning for warn), or one a couple
# of keystrokes away (producton). Undef when none is close.
sub _nearest ( $value, $choices ) {
    my $typed = lc( $value // q{} );
    return undef if !length $typed;

    my ($longer) = sort { length $a <=> length $b }
      grep { length $typed >= $MINIMUM_PREFIX && index( $_, $typed ) == 0 }
      @{$choices};
    return $longer if defined $longer;

    my $shorter =
      first { length $_ >= $MINIMUM_PREFIX && index( $typed, $_ ) == 0 }
      @{$choices};
    return $shorter if defined $shorter;

    my $allowed = max( 1, int( length($typed) / $SUGGESTION_PER_CHARS ) );
    my ($closest) =
      sort { $a->[1] <=> $b->[1] }
      grep { $_->[1] <= $allowed }
      map  { [ $_, _distance( $typed, $_ ) ] } @{$choices};

    return $closest ? $closest->[0] : undef;
}

# Levenshtein distance: the fewest single-character edits from one to the
# other.
sub _distance ( $from, $to ) {
    my @previous = ( 0 .. length $to );
    for my $i ( 1 .. length $from ) {
        my @current = ($i);
        for my $j ( 1 .. length $to ) {
            my $cost =
              substr( $from, $i - 1, 1 ) eq substr( $to, $j - 1, 1 ) ? 0 : 1;
            push @current,
              min(
                $previous[$j] + 1,
                $current[ $j - 1 ] + 1,
                $previous[ $j - 1 ] + $cost
              );
        }
        @previous = @current;
    }

    return $previous[-1];
}

# The locales whose catalogs ship in locale/. None found -- a tree without
# its catalogs -- leaves the setting unchecked rather than refusing them all.
sub _shipped_locales {
    state $locales = [ sort map { $_->basename('.po') }
          path($LOCALE_DIRECTORY)->list->grep(qr/[.]po\z/msx)->each ];

    return $locales;
}

sub _locale_directory_of ($file) {
    my $directory = path($file)->to_abs->dirname;
    for ( 1 .. $CHECKOUT_DEPTH ) {
        $directory = $directory->dirname;
    }

    return $directory->child('locale')->to_string;
}

sub _is_deployed ($environment) {
    return $environment && exists $IS_DEPLOYED{$environment} ? 1 : 0;
}

sub _is_production ($environment) {
    return $environment && exists $IS_PRODUCTION{$environment} ? 1 : 0;
}

sub _csv_items ($raw) {
    return grep { length } map { trim($_) } split /,/msx, $raw;
}

# The first value, then each later one not seen before; empty ones are
# dropped.
sub _unique_head ( $first, $rest ) {
    my %seen = ( $first => 1 );

    return [ $first,
        grep { defined && length && !$seen{$_}++ } @{ $rest || [] } ];
}

1;

__END__

=head1 NAME

GPForum::Config - Environment-backed configuration object.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $config = GPForum::Config->from_environment;

=head1 DESCRIPTION

Loads and validates the configuration, including the multi-process runtime
profile. Every setting is one row of a table: its attribute, its
C<GPFORUM_*> variable, its default, the rule L</validate> applies, the
section it belongs to and a one-line summary. The same table drives the
reading, the checks, the problems an operator is shown and
C<deploy/gpforum.env.example>.

=head1 SUBROUTINES/METHODS

=head2 from_environment

Builds configuration from an environment hash (C<%ENV> by default). Every
problem -- a value that does not parse and a value L</validate> refuses -- is
reported at once, in one L<GPForum::X::Config>.

=head2 validate

Throws L<GPForum::X::Config> when L</problems> finds any; returns the
configuration otherwise.

=head2 problems

Every problem with the configuration, in table order, as an array reference
of hash references: C<key> (the catalog key of its sentence), C<setting>,
C<variable>, C<value>, C<parameters>, and what helps fix it -- C<example>,
C<generate> or C<suggestion>. L<GPForum::Config::Report> renders them.

=head2 settings

Class method. A copy of the settings table, one hash reference per setting
with C<name>, C<env>, C<default>, C<type>, C<section>, C<summary>,
C<operator>, C<operator_when>, C<example>, C<generate>, C<retired> and
C<aliases>, in table order. Each alias is an old variable (C<env>, with the C<values> its words
read as) or an old value (C<value>, read C<as> the current one), with
C<read_until>, the release that stops reading it.

=head2 requires_glifistore

Always false: GlifiStore is optional in every environment. Kept for callers
that still ask.

=head2 requires_secure_transport

True for staging and production profiles. Those environments require a
rotated session secret, Secure cookies, and HSTS.

=head2 is_production

True for production (and its old names production-small and
production-medium, in a configuration built with C<new>): the environment
that also requires an https address, a sender mail servers
accept and a long session secret, and that never send the benchmark query
headers.

=head2 signing_secrets

Returns the Mojolicious secret list. The current session secret is first
and signs new cookies. Previous secrets from
C<GPFORUM_SESSION_SECRETS> still validate existing cookies.

=head2 accepted_metrics_tokens

Returns the current metrics token followed by previous tokens from
C<GPFORUM_METRICS_TOKENS>. Scrapers may present either during rotation.
Staging and production refuse to start without C<GPFORUM_METRICS_TOKEN>, so
the list is never empty there and C</metrics> cannot fail open. Development
and test may leave it unset and keep C</metrics> unauthenticated.

=head2 environment_requires_glifistore

Class helper for the same answer as L</requires_glifistore>: always false.

=head2 smtp_ssl

1 when the SMTP connection is encrypted (C<smtp_tls> is C<starttls> or
C<implicit>), 0 when it is C<off>: what C<GPFORUM_SMTP_SSL> used to say,
for the callers that still ask.

=head2 smtp_tls_problem

Takes, optionally, whether this Perl can speak TLS to an SMTP server (by
default L</smtp_can_tls>'s answer) and returns the problem the service's
start stops with -- C<config.smtp_tls_module>, under C<GPFORUM_SMTP_TLS> --
when mail leaves by C<smtp> with C<smtp_tls> on and it cannot, or undef. It
is not one of L</problems>: it is a fact about the host, which doctor,
mail-check, the front door and L<GPForum::Bootstrap::Config> ask for.

=head2 assert_smtp_tls

Takes the same optional argument and returns the configuration, or throws
L<GPForum::X::Config> with L</smtp_tls_problem>'s problem, in English, as
L</from_environment> throws its own.

=head2 smtp_can_tls

Class or instance method: 1 when L<Net::SMTP> can speak TLS (it can only
with IO::Socket::SSL installed), else 0. Asked once per process.

=head2 automatic_web_processes

The web process count C<GPFORUM_WEB_PROCESSES=auto> stands for: the CPUs
(L</host_worker_cpus>) times C<GPFORUM_RUNTIME_MAX_WEB_PER_CPU>, at least 1
and at most 16. It is the default, and C<web_processes> reads it unless a
number is set.

=head2 automatic_local_cache_max_entries

The cache size C<GPFORUM_LOCAL_CACHE_MAX_ENTRIES=auto> stands for: each web
process's equal part of an eighth of L</host_memory_bytes>, at 16 KiB an
entry, rounded down to a power of two from 1024 to 16384, or 4096 when the
memory cannot be measured. It is the default, and C<local_cache_max_entries>
reads it unless a number is set.

=head2 host_worker_cpus

The CPUs a web worker counts on this host (L<GPForum::OS::Base/worker_cpu_count>),
asked once per process.

=head2 host_cpus

Every logical CPU of this host, asked once per process.

=head2 host_memory_bytes

This host's memory in bytes, or a container's limit when it is less
(L<GPForum::OS::Memory>); undef when it cannot be measured. Asked once per
process.

=head2 sizing

How the node is sized, for C<gpforum doctor>: C<cpus>, C<memory_bytes>, and
C<sizes>, each automatic setting (C<web_processes>,
C<local_cache_max_entries>) the node runs at the host's size, by name. One the
operator set to another number is left out.

=head2 os_feature_settings

The C<os_*> feature switches, keyed without the prefix.

=head2 os_preflight_settings

The operating-system preflight thresholds, keyed without the prefix.

=head2 runtime_trusted_proxy_list

The addresses and networks (C<GPFORUM_RUNTIME_TRUSTED_PROXIES>, comma
separated; C<127.0.0.1,::1> by default) whose C<X-Forwarded-For> Hypnotoad
believes when C<runtime_proxy> is on.

=head2 runtime_listen_locations

The comma-separated C<runtime_listen> locations as a list.

=head2 database_session_settings

The statements every connection runs once it is made, as an array
reference: the timeouts, the application name, the message locale and the
search similarity threshold. C<database_connect_info> passes them as
C<on_connect_do>; the query statistics know them by these texts.

=head2 database_connect_info

Returns DBI connection arguments for DBIx::Class. Session
C<statement_timeout>, C<idle_in_transaction_session_timeout>,
C<lock_timeout>, and C<application_name> are applied on connect. Zero
milliseconds disables that PostgreSQL timeout. C<gpforum-migrate --apply>
clears C<statement_timeout> after connect so DDL is not capped at the web
budget.

=head1 DIAGNOSTICS

Throws L<GPForum::X::Config> with every problem found. Its C<problems> are
the records L</problems> describes; its message is the English report
L<GPForum::Config::Report> renders from them: a header, each problem naming
its variable with an example, a suggestion for a mistyped choice or the
command that generates a secret, and a footer, ending in a newline.

=head1 CONFIGURATION AND ENVIRONMENT

Reads C<GPFORUM_*> environment variables, including PostgreSQL connection
settings (C<GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS>,
C<GPFORUM_DATABASE_IDLE_IN_TRANSACTION_TIMEOUT_MS>,
C<GPFORUM_DATABASE_LOCK_TIMEOUT_MS>), search's bounds (below), session
rotation (C<GPFORUM_SESSION_SECRET>, comma-separated
C<GPFORUM_SESSION_SECRETS>), metrics scrape tokens
(C<GPFORUM_METRICS_TOKEN>, comma-separated C<GPFORUM_METRICS_TOKENS>),
and mail delivery (C<GPFORUM_MAIL_TRANSPORT>, C<GPFORUM_MAIL_FROM>,
and optional SMTP host, port, credentials, and TLS). Development defaults to
the C<log> transport, which writes each message to the log; test to C<test>;
staging and production to C<sendmail>, and they refuse C<log>. Upload
scanning (C<GPFORUM_ANTIVIRUS>: C<clamd>, C<command> or C<none>, with
C<GPFORUM_ANTIVIRUS_SOCKET>, C<GPFORUM_ANTIVIRUS_COMMAND> and
C<GPFORUM_ANTIVIRUS_TIMEOUT_SECONDS>) defaults to C<clamd> in staging and
production and C<none> elsewhere. Staging and production reject the
development session secret in both the current secret and
C<GPFORUM_SESSION_SECRETS>, and require a non-empty C<GPFORUM_METRICS_TOKEN>
so the C</metrics> scrape endpoint is never left unauthenticated.

C<GPFORUM_ENV> is one of development, staging and production (and test, the
suite's own), and a mistyped one is answered with the nearest (C<prod>:
production). The size of a node is not an environment: web processes and
the cache are sized from the host. C<production-small> and
C<production-medium> are old names of production, read as it until v0.3.0;
L</from_environment> notes each in C<renamed_settings>, with C<old>, the
value written. C<GPFORUM_EVENT_RETENTION_DAYS> (365) is how long the event
log is kept, which the size profiles used to set. Production also requires an C<https://>
C<GPFORUM_PUBLIC_BASE_URL>, a C<GPFORUM_MAIL_FROM> that is not at
localhost and a session secret of at least 32 characters. Booleans read
C<on>/C<off>, C<yes>/C<no>, C<true>/C<false> or C<1>/C<0>.
C<GPFORUM_GLIFISTORE_URL> is optional everywhere and empty by default.
C<GPFORUM_WORKER_PROCESSES>, C<GPFORUM_REALTIME_PROCESSES> and
C<GPFORUM_OS_AFFINITY> no longer have any effect; they are still read but
never refused (a value that does not parse keeps the default), and
L</from_environment> lists those set in C<retired_settings>.

Staging and production refuse a C<GPFORUM_PUBLIC_BASE_URL> or a
C<GPFORUM_MAIL_FROM> under a name RFC 2606 keeps for examples
(C<example.com>, C<.net>, C<.org>, C<.example>, C<.invalid>): the template's
placeholders, left as copied. L</from_environment> also refuses
C<GPFORUM_MAIL_TRANSPORT=test> in production, where it would send nothing;
a configuration built with C<new> keeps C<test>, its plain default, for the
test suite.

C<GPFORUM_SMTP_TLS> is C<starttls>, C<implicit> or C<off>, and defaults to
C<implicit> when C<GPFORUM_SMTP_PORT> is 465 and to C<starttls> otherwise.
It was C<GPFORUM_SMTP_SSL>, a boolean, which is still read when
C<GPFORUM_SMTP_TLS> is not set (on as C<starttls>, off as C<off>);
L</from_environment> lists each old name the environment set in
C<renamed_settings>, as C<variable>, C<replacement> and the C<value> it now
holds. C<GPFORUM_FORUM_READ_RATE_LIMIT> is the forum pages one visitor may
read per minute, 60 by default.

Search and autocomplete run under their own C<statement_timeout>,
C<GPFORUM_SEARCH_STATEMENT_TIMEOUT_MS> (C<search_statement_timeout_ms>, 2000
by default), set for the transaction each one runs in; a search it cancels
renders degraded. Zero leaves them under
C<GPFORUM_DATABASE_STATEMENT_TIMEOUT_MS>, and a value above that one (when
it is not zero) is lowered to it: search is never given longer than every
other query. Search ranks only the newest
C<GPFORUM_SEARCH_CANDIDATE_LIMIT> matches (C<search_candidate_limit>, 1000 by
default) and the page says when it did. L</validate> refuses a negative timeout,
a search timeout above a non-zero C<database_statement_timeout_ms>, and a limit
below 1.

=head1 DEPENDENCIES

Uses L<Const::Fast>, L<DateTime::TimeZone>, L<List::Util>, L<Mojo::Base>,
L<Mojo::File>, L<GPForum::Config::Report>, L<GPForum::OS>,
L<GPForum::OS::Memory> and L<GPForum::X::Config>; L<Net::SMTP>, loaded by L</smtp_can_tls>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The configuration checks the shape of the database connection but does not
connect unless a caller asks the schema layer to do so.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
