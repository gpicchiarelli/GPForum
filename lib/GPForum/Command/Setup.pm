# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Setup;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS ();
use List::Util    qw(any first);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File   qw(path);
use Mojo::Loader qw(load_class);
use Mojo::Util   qw(decode encode trim);
use Net::Domain  ();

use GPForum::Command::Migrate;
use GPForum::Command::Secret;
use GPForum::Command::Support::EnvironmentFileEdit;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Terminal;
use GPForum::Command::Support::Verbs;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Config::EnvironmentFile;
use GPForum::Config::Report;
use GPForum::OS;
use GPForum::Schema;
use GPForum::Service::Admin::Bootstrapper;
use GPForum::Service::I18N::CliCatalog;
use GPForum::Service::Operations::DatabaseFailure;
use GPForum::Service::Operations::DatabaseProvisioning;
use GPForum::Service::Operations::Findings;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceAccount;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-setup';
const my $EDIT    => 'GPForum::Command::Support::EnvironmentFileEdit';

# The environments setup writes, and the deployed ones among them, which run
# as services under the account and refuse mail that only reaches the log.
const my @ENVIRONMENTS => qw(production staging development);
const my $DEPLOYED     => qr/\A (?: staging | production )/msx;

# What "create" means: the forum's database and role, named as the template
# names them, on this host.
const my $DATABASE_NAME => 'gpforum';
const my $LOCAL_SERVER  => 'host=127.0.0.1;port=5432';

const my $SMTP_PORT => 587;
const my $SENDER    => 'forum';

# The address a development forum answers at: gpforum start --foreground's.
const my $DEVELOPMENT_ADDRESS => 'http://127.0.0.1:3000';

# The file: readable by the services' group and nobody else, in a directory
# anyone may enter.
const my $FILE_MODE      => oct '640';
const my $DIRECTORY_MODE => oct '755';
const my $MODE_BITS      => oct '777';
const my $OTHERS_BITS    => oct '007';

# Where stat puts the mode, the owner and the group.
const my $STAT_MODE => 2;
const my $STAT_UID  => 4;
const my $STAT_GID  => 5;

# What each answer sets, in the order the file is written.
const my @SECRETS => qw(GPFORUM_SESSION_SECRET GPFORUM_METRICS_TOKEN);
const my @SMTP => qw(
  GPFORUM_SMTP_HOST GPFORUM_SMTP_PORT GPFORUM_SMTP_USERNAME GPFORUM_SMTP_PASSWORD
);

# The template's example addresses, which a copied file may still hold.
const my %PLACEHOLDER => map { $_ => 1 }
  qw(GPFORUM_PUBLIC_BASE_URL GPFORUM_MAIL_FROM);

# The settings whose value is never shown, in a conflict or anywhere else.
const my %SECRET => map { $_ => 1 }
  ( @SECRETS, qw(GPFORUM_DATABASE_PASSWORD GPFORUM_SMTP_PASSWORD) );

# The failures of the forum's role that the role and the database setup
# makes would put right, and what each leaves to make: a refused password is
# how PostgreSQL answers for a role it does not have, when it asks for one;
# a database it does not have, it says only once the role has logged in.
const my %MAKES => (
    'database.unknown_role'     => 'role',
    'database.authentication'   => 'role',
    'database.unknown_database' => 'database',
);

# The superuser role a fix names, where the operating system's is not known.
const my $SUPERUSER_ROLE => 'postgres';

# What the operator answers "yes" with, in either language.
const my $YES =>
  qr/\A (?: [ys] | yes | si | s\N{LATIN SMALL LETTER I WITH GRAVE} ) \z/msxi;

has input  => sub { return \*STDIN; };
has prompt => sub { return \*STDERR; };
has output => sub { return \*STDOUT; };

# Where the questions are asked; a test gives its own.
has terminal => sub ($self) {
    return GPForum::Command::Support::Terminal->new(
        input  => $self->input,
        prompt => $self->prompt,
    );
};

has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };
has os      => sub { return GPForum::OS->detect; };

# Who runs it: root makes the account, gives the file to its group and may
# reach PostgreSQL as its own account.
has effective_uid => sub { return $EFFECTIVE_USER_ID; };

# The checkout the services run from, which holds the uploads.
has root => sub {
    return path(__FILE__)->to_abs->dirname->dirname->dirname->dirname;
};

# Where root links gpforum, so it runs from any directory: /usr/local/bin,
# on the PATH of Debian, FreeBSD and macOS alike. None for anyone else, whose
# PATH is their own; a test gives its own.
has links_into => sub ($self) {
    return $self->_is_root ? '/usr/local/bin' : undef;
};

has account => sub ($self) {
    return GPForum::Service::Operations::ServiceAccount->new( os => $self->os );
};

# PostgreSQL's superuser is tried with the login the shell gives too
# (GPFORUM_DATABASE_USER, GPFORUM_DATABASE_PASSWORD): read here, when the run
# starts, before the file it writes is loaded over the shell's settings.
has database => sub ($self) {
    my $class = 'GPForum::Service::Operations::DatabaseProvisioning';
    return $class->new(
        os            => $self->os,
        effective_uid => $self->effective_uid,
        given_logins  => $class->logins_of( \%ENV ),
    );
};

# Makes a secret: gpforum secret rotate's.
has generate => sub { return GPForum::Command::Secret->new->generate; };

# This host's fully qualified name, the address suggested in production.
has host_name => sub { return Net::Domain::hostfqdn() // 'localhost'; };

# Brings the schema up to date as gpforum migrate does, under the settings
# the file holds, and returns { status, summary }: its exit status and its
# one-line summary. A test gives its own.
has migrate => sub { return \&_migrate; };

# Whether the forum has an owner: 1, 0, or undef when it cannot tell. A test
# gives its own.
has owner_check => sub { return \&_has_owner; };

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options;
    try {
        $options = $self->_options(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() )
          if GPForum::Command::Usage->is_usage($error);
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };
    if ( !$options->{yes} && !$self->terminal->is_interactive ) {
        return $self->_refused( $self->_said('setup.no_terminal') );
    }

    my $status;
    try {
        $status = $self->_setup($options);
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            $options->{json}
            ? ( $self->output, { command => $COMMAND, findings => [] } )
            : () );
    };

    return $status;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text --help prints.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: gpforum setup [--yes] [--public-url URL] [--database create|DSN]
                     [--mail sendmail|'smtp HOST[:PORT] [USER]'|log]
                     [--environment production|staging|development]
                     [--database-user ROLE] [--smtp-password-stdin]
                     [--force] [--dry-run] [--json] [--env-file FILE]

Sets this host up to run the forum. It asks three questions -- the public
address, the database, and how mail leaves -- and Enter accepts each
suggestion. On a fresh clone it first installs the dependencies, as make
install-deps-production does. Then it:

  - makes the account gpforum the services run as, with the directory its
    uploads go in, when run as root (useradd, pw, or dscl on macOS);
  - links gpforum into /usr/local/bin when run as root, so it runs from
    any directory;
  - writes the environment file the service reads (/etc/gpforum/gpforum.env,
    /usr/local/etc/gpforum/gpforum.env on FreeBSD, Homebrew's etc/ on
    macOS), mode 0640, root:gpforum when run as root, with a new session
    secret and metrics token;
  - makes the database role and the database, as PostgreSQL's superuser,
    when it can reach one, and otherwise prints the two psql commands;
  - brings the schema up to date, as gpforum migrate does;
  - and says what to do next.

Run again, it changes nothing that is already right and says so. It never
replaces a setting the file has unless you say so -- an answer typed at the
prompt, yes when it asks, or --force -- and never prints a secret. A sender
it derived from the address follows a new address; one you wrote stays.

  --yes                 take every suggestion and ask nothing, for scripts
  --public-url URL      the address members reach the forum at
  --database create     make the database gpforum on this host (default)
  --database DSN        use this DBI data source, such as
                        dbi:Pg:dbname=gpforum;host=db.internal;port=5432
  --database-user ROLE  the role the forum connects as (default gpforum)
  --mail sendmail       hand mail to this host's mail server (default)
  --mail 'smtp HOST[:PORT] [USER]'
                        send through an SMTP server; port 587 by default; a
                        password for USER is asked, or read with
                        --smtp-password-stdin
  --mail log            write mail to the log: development only
  --environment NAME    production (default), staging or development
  --force               replace settings the file already has
  --dry-run             say what it would do, changing nothing
  --json                one JSON object on stdout instead of sentences
  --env-file FILE       write FILE instead of this host's environment file
  --help                show this help

Exit status: 0 the host is set up; 1 a step failed, or the file has
settings it would replace without --force; 2 usage error; 78 settings the
service could not use.
USAGE
}

sub _options ( $self, @arguments ) {
    my %options = ( yes => 0, force => 0, dry_run => 0, json => 0 );
    my $usage   = _usage();
    my $value   = sub ($name) {
        return sub ( $options, $given ) {
            GPForum::Command::Usage->option_value( $given, qr/\S/msx, $usage,
                "--$name" =~ tr/_/-/r );
            $options->{$name} = $name eq 'env_file' ? $given : _text($given);
        };
    };

    GPForum::Command::Usage->parse_options(
        \@arguments,
        \%options,
        {
            switches => {
                '--yes'                 => { yes                 => 1 },
                '--force'               => { force               => 1 },
                '--dry-run'             => { dry_run             => 1 },
                '--json'                => { json                => 1 },
                '--smtp-password-stdin' => { smtp_password_stdin => 1 },
            },
            values => {
                '--public-url'    => $value->('public_url'),
                '--database'      => $value->('database'),
                '--database-user' => $value->('database_user'),
                '--mail'          => $value->('mail'),
                '--env-file'      => $value->('env_file'),
                '--environment'   => sub ( $options, $given ) {
                    $options->{environment} =
                      GPForum::Command::Usage->option_choice( $given,
                        [@ENVIRONMENTS], $usage, '--environment' );
                },
            },
            usage => $usage,
        }
    );

    return \%options;
}

# The whole run: the answers, the plan, then each step, said as it is done.
sub _setup ( $self, $options ) {
    $self->database;
    my $state = $self->_read_file($options);
    my $plan  = $self->_answers( $options, $state );
    return $plan if !ref $plan;

    my $refused = $self->_conflicts( $options, $state, $plan );
    return $refused if defined $refused;
    $self->_plan_sender( $state, $plan );

    my $database = $self->_inspect_database( $state, $plan );
    my $lines    = $self->_planned_lines( $state, $plan );
    my $problems = $self->_settings_problems($lines);
    if ( @{$problems} ) {
        print {*STDERR} encode(
            'UTF-8',
            GPForum::Command::Support::Words->new->config_report(
                $problems, $state->{file}
            )
        ) or croak 'failed to write the settings report';
        return $GPForum::Command::Usage::EXIT_CONFIG;
    }

    my $findings =
      GPForum::Service::Operations::Findings->new( catalog => $self->catalog );
    return $self->_dry_run( $options, $state, $plan, $database, $lines,
        $findings )
      if $options->{dry_run};

    my %changed;
    my $continue =
         $self->_ensure_account( $state, $lines, $findings, \%changed )
      && $self->_write_file( $state, $lines, $findings, \%changed )
      && $self->_ensure_link( $findings, \%changed );
    if ($continue) {
        local %ENV = %ENV;
        $self->_load($state);
        $continue =
          $self->_ensure_database( $state, $plan, $database, $findings,
            \%changed )
          && $self->_ensure_schema( $findings, \%changed );
        $state->{owned} = $continue ? $self->owner_check->($self) : 1;
    }

    return $self->_report( $options, $state, $findings, \%changed );
}

# The file as it is: its lines and values, or the template's when there is
# none yet.
sub _read_file ( $self, $options ) {
    my $environment = GPForum::Command::Support::ServiceEnvironment->new;
    my $file =
      path( $options->{env_file} // $environment->default_file )
      ->to_abs->to_string;
    my $template = [ split /^/msx, GPForum::Config::EnvironmentFile->render ];

    my %state = (
        file     => $file,
        exists   => -e $file ? 1 : 0,
        template => $EDIT->values_of($template),
    );
    if ( $state{exists} ) {
        GPForum::Command::Support::ServiceEnvironment->new( file => $file )
          ->read_file($file);
        $state{lines} = [ split /^/msx, _text( path($file)->slurp ) ];
    }
    else {
        $state{lines} = $template;
    }
    $state{values}   = $EDIT->values_of( $state{lines} );
    $state{deployed} = 0;

    return \%state;
}

# A value the operator gave the file: set, and not one of the template's
# placeholder addresses left as copied, which the service would refuse.
sub _given ( $self, $state, $name ) {
    return undef if !$state->{exists};
    my $value = $state->{values}{$name};
    return undef if !defined $value || !length $value;
    return undef
      if exists $PLACEHOLDER{$name}
      && $value eq ( $state->{template}{$name} // q{} );

    return $value;
}

# The three answers, asked or taken from the options, and what they set.
# Returns the plan, or the exit status when the operator stopped.
sub _answers ( $self, $options, $state ) {
    my $environment = $options->{environment}
      // $self->_given( $state, 'GPFORUM_ENV' ) // 'production';
    $state->{environment} = $environment;
    $state->{deployed}    = $environment =~ $DEPLOYED ? 1 : 0;

    my $asking = !$options->{yes};
    if ($asking) {
        $self->_ask_line( $self->_said('setup.intro') );
    }

    my %plan    = ( GPFORUM_ENV => $environment );
    my $address = $self->_answer(
        $options,
        'public_url',
        $self->_said('setup.ask_address'),
        $self->_suggested_address($state),
        sub ($answer) { return $self->_address_problem( $state, $answer ); }
    );
    return $address if !ref $address;
    $plan{GPFORUM_PUBLIC_BASE_URL} = $address->{value};
    _typed( $state, $address, 'GPFORUM_PUBLIC_BASE_URL' );

    my $suggested_database = $self->_given( $state, 'GPFORUM_DATABASE_DSN' );
    my $database           = $self->_answer(
        $options,
        'database',
        $self->_said('setup.ask_database'),
        $suggested_database // $self->_said(
            'setup.suggest_create', { database => $DATABASE_NAME }
        ),
        sub ($answer) { return $self->_database_problem($answer); },
        defined $suggested_database ? undef : 'create',
    );
    return $database if !ref $database;
    $plan{GPFORUM_DATABASE_DSN} = _dsn( $database->{value} );
    _typed( $state, $database, 'GPFORUM_DATABASE_DSN' );
    $plan{GPFORUM_DATABASE_USER} = $options->{database_user}
      // $self->_given( $state, 'GPFORUM_DATABASE_USER' ) // $DATABASE_NAME;

    my $mail = $self->_answer(
        $options,
        'mail',
        $self->_said('setup.ask_mail'),
        $self->_suggested_mail($state),
        sub ($answer) { return $self->_mail_problem( $state, $answer ); }
    );
    return $mail if !ref $mail;
    my $smtp = $self->_mail_plan( $options, $state, \%plan, $mail->{value} );
    return $smtp if defined $smtp;
    _typed( $state, $mail, 'GPFORUM_MAIL_TRANSPORT', @SMTP[ 0 .. 2 ] );

    for my $secret (@SECRETS) {
        $plan{$secret} = $self->_given( $state, $secret )
          // $self->generate->();
    }
    $plan{GPFORUM_DATABASE_PASSWORD} =
      $self->_given( $state, 'GPFORUM_DATABASE_PASSWORD' );

    # How uploads are scanned is not asked: a new file takes this
    # environment's default -- clamd once deployed, none in development --
    # where the template's line holds production's.
    $plan{GPFORUM_ANTIVIRUS} = $self->_given( $state, 'GPFORUM_ANTIVIRUS' )
      // _default_in( $environment, 'GPFORUM_ANTIVIRUS' );

    return \%plan;
}

# The settings an answer typed at the prompt sets: typing it is the say-so,
# so replacing what the file has is not asked again (Enter, --yes and
# --force keep the question, or its refusal).
sub _typed ( $state, $answer, @names ) {
    return if !$answer->{typed};
    @{ $state->{typed} }{@names} = (1) x @names;

    return;
}

# The sender, once the address is settled: the file's own, kept, unless
# setup derived it from the address the file had (forum@ its host) and the
# address changed -- then it follows the address, and setup says so. One the
# operator wrote stays, whatever the address.
sub _plan_sender ( $self, $state, $plan ) {
    my $address = $plan->{GPFORUM_PUBLIC_BASE_URL};
    my $kept    = $self->_given( $state, 'GPFORUM_MAIL_FROM' );
    my $before  = $self->_given( $state, 'GPFORUM_PUBLIC_BASE_URL' );
    if ( !defined $kept ) {
        $plan->{GPFORUM_MAIL_FROM} = _sender($address);
        return;
    }

    my $derived = defined $before && $kept eq _sender($before);
    my $now     = _sender($address);
    if ( $derived && $kept ne $now ) {
        $plan->{GPFORUM_MAIL_FROM} = $now;
        $state->{sender_followed}  = { from => $kept, sender => $now };
        return;
    }
    $plan->{GPFORUM_MAIL_FROM} = $kept;

    return;
}

# A setting's default in an environment, as the settings table gives it.
sub _default_in ( $environment, $variable ) {
    my $setting =
      first { $_->{env} eq $variable } @{ GPForum::Config->settings };
    for my $when ( @{ $setting->{default_when} // [] } ) {
        my ( $on, $values, $default ) = @{$when};
        return $default
          if $on eq 'environment' && any { $_ eq $environment } @{$values};
    }

    return $setting->{default};
}

# One answer: the option's, the suggestion's under --yes, or the
# operator's, asked again until it is one setup can use. Returns { value },
# or the exit status.
sub _answer ( $self, $options, $name, $question, $suggestion, $problem,
    $meaning = undef )
{
    my $given = $options->{$name};
    if ( defined $given || $options->{yes} ) {
        my $value = $given // $meaning // $suggestion;
        my $wrong = $problem->($value);
        return { value => $value } if !defined $wrong;

        return $self->_refused($wrong);
    }

    while (1) {
        my $typed = $self->terminal->line(
            defined $suggestion
            ? "$question [$suggestion]:"
            : "$question:"
        );
        return $self->_stopped if !defined $typed;

        $typed = trim($typed);
        my $value = length $typed ? $typed : $meaning // $suggestion;
        next if !defined $value;

        my $wrong = $problem->($value);
        return { value => $value, typed => length $typed ? 1 : 0 }
          if !defined $wrong;
        $self->_ask_line($wrong);
    }

    return;
}

# An answer setup cannot use, given as an option: what is wrong with it, and
# where the options are explained -- not the whole usage, which buried the
# one sentence that mattered.
sub _refused ( $self, $sentence ) {
    $self->_complain( join "\n", $sentence, $self->_said('setup.see_help') );

    return $GPForum::Command::Usage::EXIT_USAGE;
}

sub _stopped ($self) {
    $self->_ask_line(q{});
    $self->_ask_line( $self->_said('setup.stopped') );

    return $GPForum::Command::Usage::EXIT_FAILURE;
}

# The sender at the forum's own name; at localhost for an address that is
# a number or this host.
sub _sender ($address) {
    my ($host) = $address =~ m{\A \w+ :// (?: [^@/]* @ )? ([^/:]+)}msx;
    $host //= 'localhost';
    if ( $host =~ /\A (?: [\d.]+ | localhost | \[ .* ) \z/msx ) {
        $host = 'localhost';
    }

    return "$SENDER\@$host";
}

sub _suggested_address ( $self, $state ) {
    return $self->_given( $state, 'GPFORUM_PUBLIC_BASE_URL' ) // (
        $state->{deployed}
        ? 'https://' . lc $self->host_name
        : $DEVELOPMENT_ADDRESS
    );
}

# The address as the service checks it: an http or https URL, https in
# production, not an example's.
sub _address_problem ( $self, $state, $address ) {
    my @problems = grep { $_->{variable} eq 'GPFORUM_PUBLIC_BASE_URL' } @{
        $self->_problems_of(
            {
                %{ $state->{template} },
                GPFORUM_ENV             => $state->{environment},
                GPFORUM_PUBLIC_BASE_URL => $address,
            }
        )
    };

    return @problems
      ? GPForum::Config::Report->sentence( $problems[0],
        $self->catalog->translator )
      : undef;
}

sub _database_problem ( $self, $answer ) {
    return undef if lc $answer eq 'create';

    my $source =
      GPForum::Service::Operations::DatabaseProvisioning->data_source($answer);
    return undef if defined $source && defined $source->{database};

    return $self->_said( 'setup.invalid_database', { value => $answer } );
}

# Text as setup keeps it: characters, from the UTF-8 the file, the command
# line and standard input carry, written back as UTF-8, which the service
# reads it as. Bytes typed at the terminal and written unchanged left a
# latin-1 byte in the file the service then could not read.
sub _text ($bytes) {
    return decode( 'UTF-8', $bytes ) // $bytes;
}

sub _dsn ($answer) {
    return
      lc $answer eq 'create'
      ? "dbi:Pg:dbname=$DATABASE_NAME;$LOCAL_SERVER"
      : $answer;
}

sub _suggested_mail ( $self, $state ) {
    my $transport = $self->_given( $state, 'GPFORUM_MAIL_TRANSPORT' );
    return $state->{deployed} ? 'sendmail' : 'log' if !defined $transport;
    return $transport                              if $transport ne 'smtp';

    my $host = $state->{values}{GPFORUM_SMTP_HOST} // q{};
    my $port = $state->{values}{GPFORUM_SMTP_PORT} || $SMTP_PORT;
    my $user = $state->{values}{GPFORUM_SMTP_USERNAME} // q{};

    return join q{ }, 'smtp', "$host:$port", length $user ? $user : ();
}

sub _mail_problem ( $self, $state, $answer ) {
    my $mail = _mail($answer);
    return $self->_said( 'setup.invalid_mail', { value => $answer } )
      if !defined $mail;
    return $self->_said( 'setup.log_refused',
        { environment => $state->{environment} } )
      if $mail->{transport} eq 'log' && $state->{deployed};

    return undef;
}

# sendmail, log (or "log only"), or smtp HOST[:PORT] [USER].
sub _mail ($answer) {
    my $text = trim($answer);
    return { transport => 'sendmail' } if lc $text eq 'sendmail';
    return { transport => 'log' } if $text =~ /\A log (?: \s+ only )? \z/msxi;

    my ( $host, $port, $user ) =
      $text =~ /\A smtp \s+ ([^\s:]+) (?: : (\d+) )? (?: \s+ (\S+) )? \z/msxi;
    return undef if !defined $host;

    return {
        transport => 'smtp',
        host      => $host,
        port      => $port // $SMTP_PORT,
        user      => $user // q{},
    };
}

# What the mail answer sets. An SMTP login needs its password: the file's
# when it is the same login at the same server, else asked without echo or
# read from standard input. Returns undef, or the exit status.
sub _mail_plan ( $self, $options, $state, $plan, $answer ) {
    my $mail = _mail($answer);
    $plan->{GPFORUM_MAIL_TRANSPORT} = $mail->{transport};
    return undef if $mail->{transport} ne 'smtp';

    $plan->{GPFORUM_SMTP_HOST}     = $mail->{host};
    $plan->{GPFORUM_SMTP_PORT}     = $mail->{port};
    $plan->{GPFORUM_SMTP_USERNAME} = $mail->{user};
    return undef if !length $mail->{user};

    my $values = $state->{values};
    my $kept   = $self->_given( $state, 'GPFORUM_SMTP_PASSWORD' );
    if (   defined $kept
        && ( $values->{GPFORUM_SMTP_HOST}     // q{} ) eq $mail->{host}
        && ( $values->{GPFORUM_SMTP_USERNAME} // q{} ) eq $mail->{user} )
    {
        $plan->{GPFORUM_SMTP_PASSWORD} = $kept;
        return undef;
    }

    # At a terminal the password is asked without echo, --smtp-password-stdin
    # or not: read as a line there, it showed on the screen as typed.
    my $password;
    if ( !$self->terminal->is_interactive && $options->{smtp_password_stdin} ) {
        my $input = $self->input;
        $password = <$input>;
        if ( defined $password ) {
            chomp $password;
        }
    }
    elsif ( $self->terminal->is_interactive ) {
        $password = $self->terminal->hidden_line(
            $self->_said(
                'setup.ask_smtp_password',
                { user => $mail->{user}, host => $mail->{host} }
            )
        );
    }
    else {
        return $self->_refused( $self->_said('setup.no_smtp_password') );
    }
    return $self->_stopped if !defined $password;

    $plan->{GPFORUM_SMTP_PASSWORD} = _text($password);

    return undef;
}

# The settings the file has that the answers would change: confirmed one
# by one on a terminal, replaced with --force, and otherwise said, with
# nothing written. Returns undef to go on, or the exit status.
sub _conflicts ( $self, $options, $state, $plan ) {
    my @conflicts = $self->_conflicting( $state, $plan );
    return undef if !@conflicts || $options->{force};

    if ( $options->{yes} ) {
        $self->_complain(
            join "\n",
            (
                map {
                    $self->_said( 'setup.conflict',
                        $self->_conflict( $state, $plan, $_ ) )
                } @conflicts
            ),
            $self->_said( 'setup.conflict_footer', { file => $state->{file} } )
        );
        return $GPForum::Command::Usage::EXIT_FAILURE;
    }

    for my $name ( grep { !$state->{typed}{$_} } @conflicts ) {
        my $reply = $self->terminal->line(
            $self->_said(
                'setup.ask_replace', $self->_conflict( $state, $plan, $name )
            )
        );
        return $self->_stopped if !defined $reply;
        next                   if trim($reply) =~ $YES;

        $plan->{$name} = $self->_given( $state, $name );
    }

    return undef;
}

# The names the file sets to something else than the answers would; the
# secrets setup makes only where the file has none.
sub _conflicting ( $self, $state, $plan ) {
    return grep {
        my $given = $self->_given( $state, $_ );
        ( !exists $SECRET{$_} || $_ eq 'GPFORUM_SMTP_PASSWORD' )
          && defined $given
          && defined $plan->{$_}
          && $given ne $plan->{$_}
    } sort keys %{$plan};
}

sub _conflict ( $self, $state, $plan, $name ) {
    return {
        file     => $state->{file},
        variable => $name,
        current  => _shown( $name, $self->_given( $state, $name ) ),
        wanted   => _shown( $name, $plan->{$name} ),
    };
}

sub _shown ( $name, $value ) {
    return exists $SECRET{$name} ? '********' : $value;
}

# What the server holds, asked before anything is written: the role's
# password is made here when setup is to make the role, or to print the
# statements that make it, so the file holds it before the role exists. A
# server that does not answer at all is no reason to make one: an existing
# file without a password kept none.
sub _inspect_database ( $self, $state, $plan ) {
    my %target = (
        dsn  => $plan->{GPFORUM_DATABASE_DSN},
        user => $plan->{GPFORUM_DATABASE_USER},
    );
    my $held = $self->database->inspect(%target);
    if ( !$held->{superuser} ) {
        $held->{tried} //= [];
        $held->{error} = $self->database->connection_error( %target,
            password => $plan->{GPFORUM_DATABASE_PASSWORD} );
        $held->{unmade} = $self->_unmade( $state, $held->{error} );
    }

    # A role that logged in to say its database is missing has the password
    # it has, or needs none: a new one in the file would lock it out.
    my $needs_password =
      $held->{superuser}
      ? !$held->{role}
      : ( $held->{unmade} // q{} ) eq 'role';
    if ( $needs_password && !defined $plan->{GPFORUM_DATABASE_PASSWORD} ) {
        $plan->{GPFORUM_DATABASE_PASSWORD} = $self->generate->();
    }

    return $held;
}

# The file's lines with the plan written in: the template's when there is
# no file yet, each other line as it was.
sub _planned_lines ( $self, $state, $plan ) {
    my @lines = @{ $state->{lines} };
    for my $name (
        qw(GPFORUM_ENV GPFORUM_PUBLIC_BASE_URL),
        $SECRETS[0],
        qw(GPFORUM_DATABASE_DSN GPFORUM_DATABASE_USER GPFORUM_DATABASE_PASSWORD),
        $SECRETS[1],
        qw(GPFORUM_MAIL_TRANSPORT GPFORUM_MAIL_FROM),
        @SMTP,
        'GPFORUM_ANTIVIRUS',
      )
    {
        next if !defined $plan->{$name};
        my $current = $EDIT->values_of( \@lines )->{$name};
        next if defined $current && $current eq $plan->{$name};

        $EDIT->assign( \@lines, $name, $plan->{$name} );
    }

    return \@lines;
}

# The problems the service would find in the file as planned, every one.
sub _settings_problems ( $self, $lines ) {
    return $self->_problems_of( $EDIT->values_of($lines) );
}

sub _problems_of ( $self, $values ) {
    my $problems = [];
    try {
        GPForum::Config->from_environment( { %{$values} } );
    }
    catch ($error) {
        die $error if !GPForum::X::Config->caught($error);    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
        $problems = $error->problems;
    };

    return $problems;
}

# What setup would do, said and not done.
sub _dry_run ( $self, $options, $state, $plan, $database, $lines, $findings ) {
    if ( $state->{deployed} && $self->_is_root && !$self->account->ids ) {
        my @commands = @{ $self->account->commands( $self->root ) };
        $findings->add(
            name    => 'account',
            status  => @commands ? 'ok' : 'degraded',
            message => @commands
            ? [
                'setup.would_account',
                {
                    user    => $self->account->name,
                    command => join( q{ }, @{ $commands[0] } ),
                }
              ]
            : [ 'setup.account_missing', { user => $self->account->name } ],
        );
    }
    my $link = $self->_link_wanted;
    if ( $link && !$link->{other} ) {
        $findings->add(
            name    => 'command',
            status  => 'ok',
            message => [ 'setup.would_link', $link ],
        );
    }
    my $file = $self->_file_message( $state, $lines, 'would_' );
    $findings->add(
        name    => 'file',
        status  => 'ok',
        message => [
            $file->[0],
            {
                %{ $file->[1] },
                $state->{exists} ? _shape( $state->{file} ) : ()
            }
        ],
    );
    $self->_say_sender( $state, $findings );
    $findings->add(
        name => 'database',
        %{ $self->_would_database( $state, $plan, $database ) },
    );
    $findings->add(
        name    => 'schema',
        status  => 'ok',
        message => ['setup.would_migrate'],
    );

    return $self->_print_report( $options, $state, $findings, {},
        $self->_said('setup.dry_run') );
}

# The account the services run as, and the directory its uploads go in: made
# by root on a deployed host. Returns whether setup goes on.
sub _ensure_account ( $self, $state, $lines, $findings, $changed ) {
    return 1 if !$state->{deployed};

    my $account = $self->account;
    my $user    = $account->name;
    if ( !$self->_is_root ) {
        $findings->add(
            name    => 'account',
            status  => 'degraded',
            message =>
              [ 'setup.not_root', { file => $state->{file}, user => $user } ],
            fixes => ['sudo gpforum setup'],
        );
        return 1;
    }

    my $made = 0;
    if ( !$account->ids ) {
        my @commands = @{ $account->commands( $self->root ) };
        if ( !@commands ) {
            $findings->add(
                name    => 'account',
                status  => 'degraded',
                message => [ 'setup.account_missing', { user => $user } ],
                fixes   => [
                    $self->_said('setup.account_by_hand'),
                    $self->_said(
                        'setup.run_again', { command => 'sudo gpforum setup' }
                    ),
                ],
            );
            return 1;
        }
        my $failed = $account->make( $self->root );
        if ($failed) {
            $findings->add(
                name    => 'account',
                status  => 'fail',
                message => [
                    'setup.account_failed',
                    { user => $user, reason => $failed->{reason} }
                ],
                fixes => ["sudo $failed->{command}"],
            );
            return 0;
        }
        $made = 1;
        $changed->{account} = 1;
    }

    my $uploads = $self->_uploads($lines);
    my $directories;
    try {
        $directories = $account->make_directory($uploads);
    }
    catch ($error) {
        $findings->add(
            name    => 'account',
            status  => 'fail',
            message => [
                'setup.uploads_failed',
                {
                    directory => $uploads,
                    reason    => GPForum::Command::Usage->trimmed($error)
                }
            ],
        );
        return 0;
    };
    if ( @{$directories} ) {
        $changed->{uploads} = 1;
    }
    $findings->add(
        name    => 'account',
        status  => 'ok',
        message => [
            $made ? 'setup.account_made' : 'setup.account_present',
            { user => $user, directory => $uploads }
        ],
    );

    return 1;
}

# gpforum on root's PATH, as a link to this checkout's bin/gpforum, which
# finds its own code and dependencies from anywhere: the step the guides had
# the operator type before setup. A gpforum already there is left alone --
# one that is this checkout's says nothing, another is said, with the
# command that replaces it. Returns 1: setup goes on either way.
sub _ensure_link ( $self, $findings, $changed ) {
    my $link = $self->_link_wanted;
    return 1 if !$link;

    if ( $link->{other} ) {
        $findings->add(
            name    => 'command',
            status  => 'degraded',
            message => [ 'setup.link_other', $link ],
            fixes   => ["sudo ln -sf $link->{target} $link->{link}"],
        );
        return 1;
    }

    try {
        path( $link->{directory} )->make_path( { mode => $DIRECTORY_MODE } );
        symlink $link->{target}, $link->{link}
          or croak "symlink: $OS_ERROR";
        $changed->{link} = 1;
        $findings->add(
            name    => 'command',
            status  => 'ok',
            message => [ 'setup.link_made', $link ],
        );
    }
    catch ($error) {
        $findings->add(
            name    => 'command',
            status  => 'degraded',
            message => [
                'setup.link_failed',
                {
                    %{$link}, reason => GPForum::Command::Usage->trimmed($error)
                }
            ],
            fixes => ["sudo ln -s $link->{target} $link->{link}"],
        );
    };

    return 1;
}

# The link setup would make -- { directory, link, target, other } -- or
# undef when there is nothing to make: no place to make it, no bin/gpforum
# in this checkout, or a link to it already there.
sub _link_wanted ($self) {
    my $directory = $self->links_into;
    return undef if !defined $directory;

    my $target = $self->root->child( 'bin', 'gpforum' );
    return undef if !-x $target;
    $target = $target->realpath->to_string;

    my $link = path( $directory, 'gpforum' );
    my %wanted =
      ( directory => $directory, link => "$link", target => $target );
    return \%wanted if !-e $link && !-l $link;

    my $there = -e $link ? $link->realpath->to_string : q{};
    return undef if $there eq $target;

    return { %wanted, other => 1 };
}

# Where the uploads go: the attachment root the file will hold, the code
# directory's var/attachments by default.
sub _uploads ( $self, $lines ) {
    my $root = $EDIT->values_of($lines)->{GPFORUM_ATTACHMENT_ROOT};
    if ( !defined $root || !length $root ) {
        $root = 'var/attachments';
    }

    return path($root)->is_abs ? $root : $self->root->child($root)->to_string;
}

# The environment file: written when it changed, given to the services'
# group when root runs this. Returns whether setup goes on.
sub _write_file ( $self, $state, $lines, $findings, $changed ) {
    my $file    = $state->{file};
    my $text    = join q{}, @{$lines};
    my $same    = $state->{exists} && $text eq join q{}, @{ $state->{lines} };
    my %owner   = $self->_ownership($state);
    my $message = $self->_file_message( $state, $lines, q{} );

    try {
        if ( !$same ) {
            _make_parent($file);
            $EDIT->replace(
                $file,
                encode( 'UTF-8', $text ),
                $state->{exists} ? () : %owner
            );
            $changed->{file} = 1;
        }
        my @stat = stat $file;
        if (   $state->{exists}
            && $state->{deployed}
            && defined $owner{gid}
            && $owner{gid} != $stat[$STAT_GID] )
        {
            chown $stat[$STAT_UID], $owner{gid}, $file
              or croak "chown: $OS_ERROR";
            $changed->{file} = 1;
            $message = [ 'setup.file_given', $message->[1] ];
        }
    }
    catch ($error) {
        $findings->add(
            name    => 'file',
            status  => 'fail',
            message => [
                'setup.cannot_write',
                {
                    file   => $file,
                    reason => GPForum::Command::Usage->trimmed($error)
                }
            ],
            fixes => [ 'sudo gpforum setup', ['setup.another_file'] ],
        );
        return 0;
    };

    $findings->add(
        name    => 'file',
        status  => 'ok',
        message => [ $message->[0], { %{ $message->[1] }, _shape($file) } ],
    );
    $self->_say_sender( $state, $findings );
    $self->_say_if_open( $file, $findings );

    return 1;
}

# A sender that followed the address, said: one setup derived, at the old
# host, kept mail going out from the old domain.
sub _say_sender ( $self, $state, $findings ) {
    my $followed = $state->{sender_followed};
    return if !$followed;

    $findings->add(
        name    => 'file',
        status  => 'ok',
        message => [ 'setup.sender_follows', $followed ],
    );

    return;
}

# Who the file belongs to when setup makes it: on a deployed host run as
# root, root and the services' group; in development run through sudo, the
# developer who ran it; otherwise whoever runs setup.
sub _ownership ( $self, $state ) {
    my %owner = ( mode => $FILE_MODE );
    return %owner if !$self->_is_root;

    # Root's: this process's own, which root runs it as.
    if ( $state->{deployed} ) {
        my $group = $self->account->group_id;
        return (
            %owner,
            uid => $EFFECTIVE_USER_ID,
            defined $group ? ( gid => $group ) : ()
        );
    }
    return %owner if !defined $ENV{SUDO_UID};

    return ( %owner, uid => $ENV{SUDO_UID}, gid => $ENV{SUDO_GID} // 0 );
}

sub _make_parent ($file) {
    my $directory = path($file)->dirname;
    return if -d $directory;

    $directory->make_path( { mode => $DIRECTORY_MODE } );

    return;
}

# The file's line: written whole, with what it holds new; or the settings
# it set; or as it was.
sub _file_message ( $self, $state, $lines, $would ) {
    my %parameters = ( file => $state->{file} );
    if ( !$state->{exists} ) {
        return [ "setup.${would}file_new", \%parameters ];
    }

    my $before = $state->{values};
    my $after  = $EDIT->values_of($lines);
    my @names  = grep { ( $before->{$_} // q{} ) ne ( $after->{$_} // q{} ) }
      sort keys %{$after};
    return [ 'setup.file_same', \%parameters ] if !@names;

    return [
        "setup.${would}file_changed",
        { %parameters, names => join q{, }, @names }
    ];
}

# Its mode, owner and group, as ls shows them.
sub _shape ($file) {
    my @stat  = stat $file;
    my $owner = getpwuid $stat[$STAT_UID];
    my $group = getgrgid $stat[$STAT_GID];

    return (
        mode  => sprintf( '%04o', $stat[$STAT_MODE] & $MODE_BITS ),
        owner => $owner // $stat[$STAT_UID],
        group => $group // $stat[$STAT_GID],
    );
}

# A file every account on the host may read, said with the chmod that
# closes it; setup leaves the operator's mode as it is.
sub _say_if_open ( $self, $file, $findings ) {
    my $mode = ( stat $file )[$STAT_MODE];
    return if !defined $mode || !( $mode & $OTHERS_BITS );

    $findings->add(
        name    => 'file',
        status  => 'degraded',
        message => [
            'cli.secret.world_readable',
            {
                file    => $file,
                command => ( -O $file ? q{} : 'sudo ' ) . "chmod 0640 $file",
            }
        ],
    );

    return;
}

# The settings the file now holds, for the steps that read them: the file
# wins over the shell here, since it is what the service will read.
sub _load ( $self, $state ) {
    my $environment =
      GPForum::Command::Support::ServiceEnvironment->new(
        file => $state->{file} );
    delete @ENV{ map { $_->[0] }
          @{ $environment->read_file( $state->{file} ) } };
    $environment->load;

    return;
}

# The role and the database: made as the superuser when one answered,
# checked as the forum's role, and said how to make by hand when neither
# worked. Returns whether setup goes on.
sub _ensure_database ( $self, $state, $plan, $held, $findings, $changed ) {
    my %target = (
        dsn      => $plan->{GPFORUM_DATABASE_DSN},
        user     => $plan->{GPFORUM_DATABASE_USER},
        password => $plan->{GPFORUM_DATABASE_PASSWORD} // q{},
    );
    my %parameters = (
        database => _database_of($plan),
        server   => _server_of($plan),
        user     => $plan->{GPFORUM_DATABASE_USER},
    );
    my $made = { role_made => 0, database_made => 0 };
    if ( $held->{superuser} ) {
        $made = $self->database->provision(%target);
        if ( $made->{role_made} || $made->{database_made} ) {
            $changed->{database} = 1;
        }
    }

    my $error = $self->database->connection_error(%target);
    if ( !defined $error ) {
        my $what =
            $made->{role_made} && $made->{database_made} ? 'made_both'
          : $made->{role_made}                           ? 'made_role'
          : $made->{database_made}                       ? 'made_database'
          :                                                'present';
        $findings->add(
            name    => 'database',
            status  => 'ok',
            message => $self->_with_superuser(
                [ "setup.database_$what", \%parameters ], $made
            ),
        );
        return 1;
    }

    $self->_database_failed( $state, $held, \%target, \%parameters, $error,
        $findings );

    return 0;
}

# Why the forum's role cannot connect: the role or the database missing,
# with no superuser here to make them, is said with the two psql commands
# that do; anything else as gpforum doctor says it.
sub _database_failed ( $self, $state, $held, $target, $parameters, $error,
    $findings )
{
    my $reader = $self->_failure_reader($state);
    my $unmade = $held->{superuser} ? undef : $self->_unmade( $state, $error );
    if ( defined $unmade ) {
        my $command = $self->_sudo . 'gpforum setup';
        my $role    = ( $self->os->postgresql_superuser // {} )->{role}
          // $SUPERUSER_ROLE;
        $findings->add(
            name    => 'database',
            status  => 'fail',
            message => [
                "setup.database_unmade_$unmade",
                { %{$parameters}, tried => $self->_tried($held) }
            ],
            fixes => [
                $self->_said(
                    'setup.fix_pguser',
                    { command => $self->_sudo . "PGUSER=$role gpforum setup" }
                ),
                $self->_said(
                    "setup.fix_by_hand_$unmade", { command => $command }
                ),
                @{
                    $self->database->commands( %{$target},
                        role_exists => $unmade eq 'database' )
                },
            ],
        );
        return;
    }

    my $parts = $reader->parts($error);
    $findings->add(
        name    => 'database',
        status  => 'fail',
        message => $parts
        ? $self->_labelled( $parts->{problem} )
        : GPForum::Command::Usage->trimmed($error),
        fixes => $parts ? [ $parts->{fix} ] : [],
    );

    return;
}

# A database failure's sentence under the label gpforum doctor's line has
# ("database: cannot reach PostgreSQL at ..."), its first word lowercased
# as doctor lowers it, unless that word is a name with capitals of its own.
sub _labelled ( $self, $problem ) {
    return $self->_said(
        'doctor.database_problem',
        {
            problem => $problem =~
              s/\A (\p{Lu}) (?= [^\s\p{Lu}]* (?: \s | \z ) )/\l$1/rmsx
        }
    );
}

# The doctor's reader of a database failure, for this file.
sub _failure_reader ( $self, $state ) {
    return GPForum::Service::Operations::DatabaseFailure->new(
        os               => $self->os,
        environment      => $state->{environment},
        environment_file => $state->{file},
    );
}

# What the forum's role, failing to connect, says is missing -- role (with
# its database) or database -- when the superuser's statements put it
# right; undef for any other failure.
sub _unmade ( $self, $state, $error ) {
    return undef if !defined $error;
    my $class = $self->_failure_reader($state)->classify($error);

    return $class && exists $MAKES{ $class->{key} }
      ? $MAKES{ $class->{key} }
      : undef;
}

# What each superuser login setup tried was told, as one phrase: "you: role
# "you" does not exist; postgres (GPFORUM_DATABASE_USER): password
# authentication failed for user "postgres"".
sub _tried ( $self, $held ) {
    my @tried = @{ $held->{tried} // [] };
    return $self->_said('setup.tried_none') if !@tried;

    return join q{; }, map {
        $self->_said(
            defined $_->{from} ? 'setup.tried_from' : 'setup.tried',
            {
                as     => $_->{as},
                from   => $_->{from} // q{},
                reason => $_->{reason}
            }
        )
    } @tried;
}

# A line of what the superuser made, with which way in setup used: libpq's
# own login, the one the shell or the data source gave, or the server's
# account. A result that does not name the role says nothing more.
sub _with_superuser ( $self, $message, $held ) {
    my ( $key, $parameters ) = @{$message};
    return $message if !defined $held->{as} || !defined $held->{superuser};

    my $way =
        $held->{superuser} eq 'you' ? [ 'setup.by_you', {} ]
      : $held->{superuser} eq 'given'
      ? [ 'setup.by_given', { from => $held->{from} } ]
      : [ 'setup.by_account', { account => $held->{superuser} } ];

    return $self->_said( $key, $parameters ) . ', '
      . $self->_said( $way->[0], { %{ $way->[1] }, as => $held->{as} } );
}

# What setup would find or make, for --dry-run: { status, message, fixes }.
# A server that does not answer is said as the run itself would say it, not
# as two statements to print.
sub _would_database ( $self, $state, $plan, $held ) {
    my %parameters = (
        database => _database_of($plan),
        server   => _server_of($plan),
        user     => $plan->{GPFORUM_DATABASE_USER},
    );
    if ( !$held->{superuser} ) {
        return {
            status  => 'ok',
            message => [ 'setup.database_present', \%parameters ]
          }
          if !defined $held->{error};
        return {
            status  => 'degraded',
            message => [
                'setup.would_database_unmade',
                { %parameters, tried => $self->_tried($held) }
            ]
          }
          if $held->{unmade};

        my $parts = $self->_failure_reader($state)->parts( $held->{error} );
        return {
            status  => 'degraded',
            message => $parts
            ? $self->_labelled( $parts->{problem} )
            : GPForum::Command::Usage->trimmed( $held->{error} ),
            fixes => $parts ? [ $parts->{fix} ] : [],
        };
    }
    my $what =
        !$held->{role} && !$held->{database} ? 'would_database_made_both'
      : !$held->{role}                       ? 'would_database_made_role'
      : !$held->{database}                   ? 'would_database_made_database'
      :                                        'database_present';

    return {
        status  => 'ok',
        message => $what eq 'database_present'
        ? [ "setup.$what", \%parameters ]
        : $self->_with_superuser( [ "setup.$what", \%parameters ], $held ),
    };
}

sub _database_of ($plan) {
    return GPForum::Service::Operations::DatabaseProvisioning->data_source(
        $plan->{GPFORUM_DATABASE_DSN} )->{database};
}

sub _server_of ($plan) {
    my $class = 'GPForum::Service::Operations::DatabaseProvisioning';

    return $class->server_name(
        $class->data_source( $plan->{GPFORUM_DATABASE_DSN} ) );
}

# The schema, as gpforum migrate brings it up to date. Returns whether setup
# goes on.
sub _ensure_schema ( $self, $findings, $changed ) {
    my $migrated = $self->migrate->($self);
    if ( $migrated->{status} ) {
        $findings->add(
            name    => 'schema',
            status  => 'fail',
            message => ['setup.migrate_failed'],
            fixes   => [ $self->_sudo . 'gpforum migrate' ],
        );
        return 0;
    }
    if ( $migrated->{changed} ) {
        $changed->{schema} = 1;
    }
    $findings->add(
        name    => 'schema',
        status  => 'ok',
        message => $migrated->{summary},
    );

    return 1;
}

# gpforum migrate, run here with the file's settings. Its document is read
# from --json, and its one line said as setup's own; a failure's sentence
# reaches the operator on standard error, as gpforum migrate writes it.
sub _migrate ($self) {
    my $output  = q{};
    my $migrate = GPForum::Command::Migrate->new( default_mode => 'apply' );
    my $status;
    {
        open my $capture, '>', \$output or croak "capture: $OS_ERROR";
        local *STDOUT = $capture;
        $status = $migrate->run('--json');
        close $capture or croak "capture: $OS_ERROR";
    }
    my $document = {};
    try {
        $document = JSON::MaybeXS->new( utf8 => 1 )->decode($output);
    }
    catch ($error) {
        $status ||= $GPForum::Command::Usage::EXIT_FAILURE;
    };
    return { status => $status } if $status;

    my $applied = $document->{applied}                         // [];
    my $budgets = $document->{budgets}                         // {};
    my $created = ( $document->{partitions} // {} )->{created} // [];
    my $changes =
      @{$applied} +
      @{$created} +
      ( $budgets->{written}  // 0 ) +
      @{ $budgets->{removed} // [] };

    return {
        status  => 0,
        summary => $migrate->summary( $applied, $document ),
        changed => $changes ? 1 : 0,
    };
}

sub _has_owner ($self) {
    my $owned;
    try {
        my $schema = GPForum::Schema->connect_from_config(
            GPForum::Config->from_environment );
        $owned =
          GPForum::Service::Admin::Bootstrapper->new( schema => $schema )
          ->has_owner;
        $schema->storage->disconnect;
    }
    catch ($error) {
        $owned = undef;
    };

    return $owned;
}

# The findings, then what to do next, or what was left to fix.
sub _report ( $self, $options, $state, $findings, $changed ) {
    my $closing;
    if ( !$findings->exit_status && !%{$changed} ) {
        $closing = $self->_said('setup.unchanged');
    }

    return $self->_print_report( $options, $state, $findings, $changed,
        $closing );
}

sub _print_report ( $self, $options, $state, $findings, $changed, $closing ) {
    my $failed = $findings->exit_status;
    if ( $options->{json} ) {
        GPForum::Command::Usage->json(
            $self->output,
            {
                command  => $COMMAND,
                status   => $failed             ? 'fail' : $findings->status,
                changed  => %{$changed}         ? 1      : 0,
                dry_run  => $options->{dry_run} ? 1      : 0,
                file     => $state->{file},
                findings => GPForum::Command::Support::ServiceEnvironment
                  ->findings_as_read(
                    $findings->document
                  ),
            }
        );
        return $failed;
    }

    my @lines = ( split /\n/msx, $findings->human_text( summary => 0 ) );
    if ($failed) {
        push @lines, q{}, $findings->summary;
    }
    elsif ( !$options->{dry_run} ) {
        push @lines, ( defined $closing ? ( q{}, $closing ) : () ), q{},
          $self->_next_steps($state);
    }
    else {
        push @lines, q{}, $closing;
    }
    $self->_say( join "\n", @lines );

    return $failed;
}

# The steps after setup, as the audit's first minutes have them: the
# forum's owner, the services, then a check of everything.
sub _next_steps ( $self, $state ) {
    my $as_service = $self->_runner($state);
    my @steps;
    if ( !$state->{owned} ) {
        push @steps,
          $self->_said(
            'setup.next_owner',
            {
                command => $as_service
                  . 'gpforum admin create --email EMAIL --username NAME'
            }
          );
    }
    push @steps, $self->_services_step($state);
    push @steps,
      $self->_said( 'setup.next_doctor',
        { command => $as_service . 'gpforum doctor' } );

    my $first = shift @steps;
    return (
        $self->_said( 'cli.next', { step => $first } ),
        map { $self->_said( 'cli.then', { step => $_ } ) } @steps
    );
}

# How the services are installed: gpforum service print, where that verb is
# there to run, which prints this host's files and the steps that install
# them (ADR 0123); the development server otherwise.
sub _services_step ( $self, $state ) {
    return $self->_said( 'setup.next_start',
        { command => 'gpforum start --foreground' } )
      if !$state->{deployed};

    my $verb = GPForum::Command::Support::Verbs->find('service');
    my $print =
        $verb && !load_class("GPForum::CLI::$verb->{command}")
      ? $self->_service_print($state)
      : undef;
    return $self->_said( 'setup.next_services', { command => $print } )
      if defined $print;

    return $self->_said('setup.next_services_by_hand');
}

# gpforum service print's own first step for this host's service manager --
# the files written to a directory with --to, for the file setup wrote --
# not a bare print, which wrote every unit to the terminal before saying to
# use --to. Undef where GPForum ships no service files.
sub _service_print ( $self, $state ) {
    my $host = GPForum::Service::Operations::Host->new(
        os               => $self->os,
        catalog          => $self->catalog,
        environment      => $state->{environment},
        environment_file => $state->{file},
    );
    my $files = GPForum::Service::Operations::ServiceFiles->new(
        host             => $host,
        environment_file => $state->{file},
    );
    my $target = $files->default_target;
    return undef if !defined $target;

    return
      first { /\b gpforum [ ] service [ ] print \b/msx }
      @{ $files->steps( $target, start => 1 ) };
}

# Who the next steps run as, each reading the file setup wrote: on a
# deployed host the services' account, once it exists and the file is its
# group's to read; otherwise whoever ran setup, whose file it is -- through
# sudo when that was root. sudo -u gpforum, said to an operator with no
# such account or with a file only they may read, was a command that failed
# as printed.
sub _runner ( $self, $state ) {
    return q{} if !$state->{deployed};

    my ( $uid, $gid ) = $self->account->ids;
    my @stat = stat $state->{file};
    if (   defined $uid
        && @stat
        && ( $stat[$STAT_UID] == $uid || $stat[$STAT_GID] == $gid ) )
    {
        return 'sudo -u ' . $self->account->name . q{ };
    }

    return $self->_sudo;
}

sub _is_root ($self) {
    return $self->effective_uid == 0 ? 1 : 0;
}

sub _sudo ($self) {
    return $self->_is_root ? 'sudo ' : q{};
}

# A gpforum command offered reads the file this run wrote, when it is not
# the host's own.
sub _as_read ( $self, $text ) {
    return GPForum::Command::Support::ServiceEnvironment->as_read($text);
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->catalog->text( $key, $parameters );
}

sub _ask_line ( $self, $line ) {
    print { $self->prompt } encode( 'UTF-8', "$line\n" )
      or croak 'failed to write the question';

    return;
}

sub _say ( $self, $text ) {
    print { $self->output } encode( 'UTF-8', $self->_as_read($text) . "\n" )
      or croak 'failed to write the setup report';

    return;
}

sub _complain ( $self, $text ) {
    print {*STDERR} encode( 'UTF-8', "$text\n" )
      or croak 'failed to write the setup report';

    return;
}

1;

__END__

=head1 NAME

GPForum::Command::Setup - Sets a host up to run the forum, in three
questions.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # sudo gpforum setup
    # gpforum setup --yes --public-url https://forum.example.org \
    #   --database create --mail sendmail
    exit GPForum::Command::Setup->new->run(@ARGV);

=head1 DESCRIPTION

C<gpforum setup> asks for the public address, the database and how mail
leaves, Enter taking each suggestion, and then does what a fresh install
needs, saying each step as a line of C<gpforum doctor>'s kind: it makes the
account the services run as (as root) and links C<gpforum> into
F</usr/local/bin>, writes the
environment file the service reads with new secrets, makes the database role
and database as PostgreSQL's superuser when it can reach one, applies the
migrations, and names the next steps. Re-run on a host it set up, it changes
nothing and says so. It never replaces a setting the file has unless the
operator says so -- an answer typed at the prompt, yes when it asks, or
C<--force> -- and never prints a secret; a sender it derived from the
address follows a new one. ADR 0122 says why it does
each of these and leaves the service files to C<gpforum service print>.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the command line. Returns 0 when the host is set up, 1 when a step
failed or the file has settings it would replace, 2 on misuse, 78 when the
settings would stop the service.

=head2 usage_text

The text C<--help> prints.

=head2 links_into

Where root links C<gpforum>: F</usr/local/bin>, or undef for anyone else.

=head1 DIAGNOSTICS

Every sentence is in the operator's language, from the command-line
catalogs (C<setup.*>).

=head1 CONFIGURATION AND ENVIRONMENT

Writes the host's environment file, or the one given with C<--env-file>. In
development run through sudo, the file is the developer's, from
C<SUDO_UID> and C<SUDO_GID>.

=head1 DEPENDENCIES

L<GPForum::Service::Operations::ServiceAccount>,
L<GPForum::Service::Operations::DatabaseProvisioning>,
L<GPForum::Command::Support::EnvironmentFileEdit>, L<GPForum::Command::Migrate>,
L<GPForum::Command::Secret> for its secrets.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The account is made where the system has a command for it: C<useradd>,
C<pw>, or C<dscl> on macOS under the highest id below 500 no user and no
group has; with none free, setup says to make it by hand. The service files
are written by C<gpforum service print>, which the operator runs.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
