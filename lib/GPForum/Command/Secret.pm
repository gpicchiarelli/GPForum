# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Secret;

use Carp qw(croak);
use Const::Fast;
use Crypt::URandom ();
use English        qw(-no_match_vars);
use List::Util     qw(any first uniq);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);
use Mojo::Util qw(encode);

use GPForum::Command::Support::EnvironmentFileEdit;
use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Service::Operations::Host;
use GPForum::Service::Operations::ServiceFiles;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-secret';

# How the file is changed: a line at a time, and replaced in one rename.
const my $EDIT => 'GPForum::Command::Support::EnvironmentFileEdit';

# Each secret by what the operator calls it: the variable that holds the one
# in use, the one that lists those still accepted while the new one rolls
# out, and how long the old ones are worth keeping.
const my %SECRET => (
    metrics => {
        current  => 'GPFORUM_METRICS_TOKEN',
        previous => 'GPFORUM_METRICS_TOKENS',
    },
    session => {
        current  => 'GPFORUM_SESSION_SECRET',
        previous => 'GPFORUM_SESSION_SECRETS',
    },
);

# 32 random bytes, written as 64 hexadecimal characters: what the
# environment file template tells an operator to make with openssl rand -hex
# 32, and twice what production asks of a session secret.
const my $SECRET_BYTES => 32;

# Sessions last 30 days (GPForum::Service::Identity::Store): a secret kept
# that long has signed its last cookie.
const my $SESSION_DAYS => 30;

const my $CHECK_MARK => "\N{CHECK MARK} ";

# What every other account on the host may do with the file, and how a line
# that warns begins, as the checks' findings begin one.
const my $OTHERS_BITS  => oct '007';
const my $WARNING_MARK => q{! };

# Where stat puts the mode.
const my $STAT_MODE => 2;

# The file the secret is written to: the one the front door read, else this
# host's; a test names its own.
has file => sub {
    return GPForum::Command::Support::ServiceEnvironment->loaded
      // GPForum::Command::Support::ServiceEnvironment->new->chosen_file;
};

has service_environment =>
  sub { return GPForum::Command::Support::ServiceEnvironment->new; };

has words => sub { return GPForum::Command::Support::Words->new; };

# The host the service runs on, in the environment the settings name.
has host => sub ($self) {
    return GPForum::Service::Operations::Host->new(
        os          => $self->service_environment->os,
        environment => $ENV{GPFORUM_ENV} // 'development',
    );
};

# Whether this host has the web service's file in place, the one its
# service manager starts it from; a test says.
has services_installed => sub ($self) {
    return defined $self->_web_service_file ? 1 : 0;
};

# Whether the running web service reads the metrics tokens from this file
# again by itself (ADR 0124), so a rotation needs no restart: it follows the
# file its supervisor read, which every unit GPForum ships names as the
# host's own. One read with --env-file is followed once the service is told
# it with GPFORUM_ENV_FILE; until then it keeps its restart. A test says.
has metrics_reread => sub ($self) {
    return 0 if !$self->services_installed;

    my $file = $self->file;
    return
      defined $file && $file eq $self->service_environment->default_file
      ? 1
      : 0;
};

# The live outcomes of a metrics rotation the service reads by itself: what
# it says done, and the step after it, if any.
const my %LIVE => (
    first => {
        done => 'cli.secret.metrics.first_live',
        next => 'cli.secret.metrics.next_scrapers',
    },
    rotated => {
        done => 'cli.secret.metrics.rotated_live',
        next => 'cli.secret.metrics.then',
    },
    finished => { done => 'cli.secret.metrics.finished_live' },
);

# Makes a new secret; a test gives its own.
has generate => sub {
    return sub { return unpack 'H*', Crypt::URandom::urandom($SECRET_BYTES); };
};

sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $request;
    try {
        $request = $self->_request(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() )
          if GPForum::Command::Usage->is_usage($error);
        die $error;    ## no critic (ErrorHandling::RequireCarping) -- rethrows the caught error as it was raised
    };

    my $file = $self->file;
    if ( !defined $file ) {
        return $self->_failed(
            $request,
            'cli.secret.no_file',
            {
                file => $self->service_environment->default_file,
                kind => $request->{kind},
            }
        );
    }

    my $status;
    try {
        $status = $self->_rotate( $request, $file );
    }
    catch ($error) {
        return GPForum::Command::Usage->failure( $error,
            $request->{json}
            ? ( \*STDOUT, _document( $request, $file, [] ) )
            : () );
    };

    return $status;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: gpforum secret rotate session|metrics [--finish] [--dry-run] [--json]

Rotates a secret in the environment file the service reads, in two steps, so
nobody is signed out and no scraper is refused while it happens:

  gpforum secret rotate session    a new GPFORUM_SESSION_SECRET; the one in
                                   use moves to GPFORUM_SESSION_SECRETS, which
                                   still accepts the cookies it signed
  gpforum secret rotate metrics    a new GPFORUM_METRICS_TOKEN; the one in use
                                   moves to GPFORUM_METRICS_TOKENS, which
                                   still accepts the scrapers that send it

A running service reads a new metrics token from the file by itself, with
no restart; a new session secret needs one. Once nothing uses the old one --
a month for sessions, the scrapers' next deploy for the token -- finish:

  --finish         drop the previous ones from the file
  --dry-run        say what it would change, writing nothing
  --json           one JSON object on stdout instead of sentences
  --help           show this help

The file is the one gpforum reads (/etc/gpforum/gpforum.env, or the one
given with gpforum --env-file FILE secret ...). Its owner and mode are kept,
a file every account can read is said with the chmod that closes it, and no
secret is printed.

Exit status: 0 done, 1 the file could not be read or written, 2 usage error.
USAGE
}

sub _request ( $self, @arguments ) {
    my $action = shift @arguments;
    if ( !defined $action || $action ne 'rotate' ) {
        $self->_misuse( 'cli.secret.needs_rotate',
            { action => $action // q{} } );
    }
    my $kind = shift @arguments;
    if ( !defined $kind || $kind =~ /\A -/msx ) {
        $self->_misuse('cli.secret.needs_kind');
    }
    if ( !exists $SECRET{$kind} ) {
        $self->_misuse( 'cli.secret.unknown_kind', { kind => $kind } );
    }

    my %request = ( kind => $kind );
    for my $argument (@arguments) {
        my ($switch) = $argument =~ /\A -- (finish|dry-run|json) \z/msx;
        if ( !defined $switch ) {
            $self->_misuse( 'cli.misuse.unknown_option',
                { option => $argument } );
        }
        $request{ $switch =~ tr/-/_/r } = 1;
    }

    return \%request;
}

sub _rotate ( $self, $request, $file ) {
    my $names = $SECRET{ $request->{kind} };
    my @lines = split /^/msx, $self->_slurp( $request, $file );
    my %found = %{ $EDIT->values_of( \@lines ) };
    my @previous =
      grep { length } split /\s*,\s*/msx, $found{ $names->{previous} } // q{};

    my ( $changed, $outcome );
    if ( $request->{finish} ) {
        return $self->_nothing_to_finish( $request, $file ) if !@previous;
        $changed = $self->_finished( \@lines, $names );
        $outcome = 'finished';
    }
    else {
        my $environment  = $self->_environment( \%found );
        my $current      = $found{ $names->{current} } // q{};
        my $kept_current = length $current
          && $self->_accepted( $names->{current}, $current, $environment );
        my @kept = uniq(
            ( $kept_current ? $current : () ),
            grep { $self->_accepted( $names->{previous}, $_, $environment ) }
              @previous
        );
        $changed = $self->_rotated( \@lines, $names, \@kept );
        $outcome = $kept_current ? 'rotated' : 'first';
    }

    if ( !$request->{dry_run} ) {
        $self->_write( $request, $file, join q{}, @lines );
    }
    return $self->_report( $request, $file, $outcome, $changed );
}

# The environment the service reads the file in: the file's own
# GPFORUM_ENV, else the one this process was given.
sub _environment ( $self, $found ) {
    return first { defined && length } $found->{GPFORUM_ENV},
      $ENV{GPFORUM_ENV}, 'development';
}

# Whether the service could have started with a secret, as the one in use or
# among those still accepted: only then did it sign a cookie or let a scraper
# in, and only then is it worth keeping. The development default copied into
# a production file, or a session secret too short for production, stopped
# the start; kept among those still accepted, it had the next start refuse
# the list instead, after the operator ran the command offered as the fix.
sub _accepted ( $self, $variable, $value, $environment ) {
    my $setting =
      first { $_->{env} eq $variable } @{ GPForum::Config->settings };
    my $config = GPForum::Config->new(
        environment      => $environment,
        $setting->{name} => $setting->{type} eq 'list' ? [$value] : $value,
    );

    return ( any { $_->{variable} eq $variable } @{ $config->problems } )
      ? 0
      : 1;
}

sub _rotated ( $self, $lines, $names, $kept ) {
    $EDIT->assign( $lines, $names->{current}, $self->generate->() );
    my @changed = ( $names->{current} );
    if ( @{$kept} ) {
        $EDIT->assign( $lines, $names->{previous}, join( q{,}, @{$kept} ),
            $names->{current} );
        push @changed, $names->{previous};
    }

    return \@changed;
}

sub _finished ( $self, $lines, $names ) {
    $EDIT->remove( $lines, $names->{previous} );

    return [ $names->{previous} ];
}

sub _slurp ( $self, $request, $file ) {
    my $text;
    try {
        $text = path($file)->slurp;
    }
    catch ($error) {
        $self->_unwritable( $request, $file, $OS_ERROR || $error );
    };

    return $text;
}

# Written beside the file and renamed over it, so the service never reads
# half a file, with the owner, group and mode the file had: it holds
# secrets, readable by the service's group and nobody else.
sub _write ( $self, $request, $file, $text ) {
    try {
        $EDIT->replace( $file, $text );
    }
    catch ($error) {
        $self->_unwritable( $request, $file,
            GPForum::Command::Usage->trimmed($error) );
    };

    return;
}

# What stops a file being read or written, with the command that writes it
# as root: the one typed, with sudo and the --env-file it was given.
sub _unwritable ( $self, $request, $file, $reason ) {
    my $command = join q{ }, 'sudo gpforum secret rotate', $request->{kind},
      ( $request->{finish} ? '--finish' : () );
    croak $self->_said(
        'cli.secret.unwritable',
        {
            command =>
              GPForum::Command::Support::ServiceEnvironment->as_read($command),
            file   => $file,
            reason => "$reason",
        }
    );
}

sub _nothing_to_finish ( $self, $request, $file ) {
    my $names = $SECRET{ $request->{kind} };
    if ( $request->{json} ) {
        GPForum::Command::Usage->json( \*STDOUT,
            _document( $request, $file, [], 'ok' ) );
        return 0;
    }
    $self->_say(
        $self->_said(
            'cli.secret.nothing_to_finish',
            { file => $file, list => $names->{previous} }
        )
    );

    return 0;
}

sub _report ( $self, $request, $file, $outcome, $changed ) {
    if ( $request->{json} ) {
        GPForum::Command::Usage->json( \*STDOUT,
            _document( $request, $file, $changed, 'ok' ) );
        return 0;
    }

    my $kind       = $request->{kind};
    my $names      = $SECRET{$kind};
    my %parameters = (
        days     => $SESSION_DAYS,
        file     => $file,
        list     => $names->{previous},
        variable => $names->{current},
    );
    if ( $request->{dry_run} ) {
        $self->_say(
            $self->_said( "cli.secret.$kind.would_$outcome", \%parameters ) );
        return 0;
    }

    if ( $kind eq 'metrics' && $self->metrics_reread ) {
        return $self->_report_live( $file, $LIVE{$outcome}, \%parameters );
    }

    $self->_say( $CHECK_MARK
          . $self->_said( "cli.secret.$kind.$outcome", \%parameters ) );
    $self->_say_if_open($file);
    $self->_say( $self->_said( 'cli.next', { step => $self->_restart } ) );

    # The step after: finishing, once a rotation left a previous one to
    # drop. A first secret, written where the template left it empty, has
    # nothing before it, and --finish would only say so.
    if ( $outcome eq 'rotated' ) {
        $self->_say(
            $self->_said(
                'cli.then',
                {
                    step =>
                      $self->_said( "cli.secret.$kind.then", \%parameters )
                }
            )
        );
    }

    return 0;
}

# A metrics rotation the running service reads by itself: done, with no
# restart, and the step after it -- the scrapers, then --finish -- if any.
sub _report_live ( $self, $file, $live, $parameters ) {
    $self->_say( $CHECK_MARK . $self->_said( $live->{done}, $parameters ) );
    $self->_say_if_open($file);
    if ( exists $live->{next} ) {
        $self->_say(
            $self->_said(
                'cli.next',
                { step => $self->_said( $live->{next}, $parameters ) }
            )
        );
    }

    return 0;
}

# The file keeps its mode, so a secret written into a file every account on
# the host may read is readable by all of them: said, with the chmod that
# closes it, as the FreeBSD rc scripts refuse such a file.
sub _say_if_open ( $self, $file ) {
    my $mode = ( stat $file )[$STAT_MODE];
    return if !defined $mode || !( $mode & $OTHERS_BITS );

    my $command = ( -O $file ? q{} : 'sudo ' ) . "chmod 0640 $file";
    $self->_say(
        $WARNING_MARK
          . $self->_said(
            'cli.secret.world_readable', { file => $file, command => $command }
          )
    );

    return;
}

# What makes the service read the new secret: the web service and its
# outbox worker read the session secret only when they start, so running
# ones are restarted; so are they for a metrics token on a service that does
# not follow the file. On a first install nothing runs them yet, and the restart
# answered "Unit gpforum.service not found": the step is then the one that
# installs and starts them, or, in development, the server started by hand.
sub _restart ($self) {
    if ( !$self->services_installed ) {
        return $self->_said( 'setup.next_services',
            { command => 'gpforum service print' } )
          if $self->host->is_deployed;
        return $self->_said( 'setup.next_start',
            { command => 'gpforum start --foreground' } );
    }

    return $self->service_environment->restart_command
      // $self->_said('cli.restart_service');
}

# The web service's file where this host's service manager reads it, or
# undef when it is not in place.
sub _web_service_file ($self) {
    my $files =
      GPForum::Service::Operations::ServiceFiles->new( host => $self->host );
    my $target = $files->default_target;
    return undef if !defined $target;

    my $web = first { ( $_->{starts} // q{} ) eq 'gpforum' }
      @{ $files->files($target) };

    return defined $web && -e $web->{path} ? $web->{path} : undef;
}

sub _failed ( $self, $request, $key, $parameters ) {
    my $sentence = $self->_said( $key, $parameters );
    if ( $request->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                %{ _document( $request, undef, [] ) },
                error  => $sentence,
                status => 'fail',
            }
        );
    }
    print {*STDERR} encode( 'UTF-8', "$sentence\n" )
      or croak 'failed to write secret failure';

    return $GPForum::Command::Usage::EXIT_FAILURE;
}

sub _document ( $request, $file, $changed, $status = 'fail' ) {
    return {
        changed => $changed,
        command => $COMMAND,
        dry_run => $request->{dry_run} ? 1 : 0,
        file    => $file,
        kind    => $request->{kind},
        mode    => $request->{finish} ? 'finish' : 'rotate',
        status  => $status,
    };
}

sub _misuse ( $self, $key, $parameters = {} ) {
    GPForum::X::Usage->throw(
        message => $self->_said( $key, $parameters ) . "\n\n" . _usage() );
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

# A gpforum command a line offers reads the file this one wrote, as
# --finish must, when that is not the host's own.
sub _say ( $self, $line ) {
    my $read = GPForum::Command::Support::ServiceEnvironment->as_read($line);
    print encode( 'UTF-8', "$read\n" )
      or croak 'failed to write secret result';

    return;
}

1;

__END__

=head1 NAME

GPForum::Command::Secret - Rotates the session secret or the metrics token
in the environment file.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # gpforum secret rotate session
    # gpforum secret rotate metrics --finish
    exit GPForum::Command::Secret->new->run(@ARGV);

=head1 DESCRIPTION

C<gpforum secret rotate session|metrics> writes a new secret -- 32 random
bytes as 64 hexadecimal characters -- into the environment file the service
reads, and moves the one in use to the list still accepted
(C<GPFORUM_SESSION_SECRETS>, C<GPFORUM_METRICS_TOKENS>), so members stay
signed in and scrapers keep working while the new one rolls out. It then
names the step after it. A running service reads the metrics tokens from
the file again by itself (ADR 0124), so a metrics rotation is three
commands: rotate, give the scrapers the new token, C<--finish>. A session
secret is read only at start: the step is the restart this host's
supervisor needs -- or, on a host whose service files are not in place yet,
C<gpforum service print>, which installs them, and in development
C<gpforum start --foreground>. So is it for a metrics token in a file
that is not the host's own, which the service is not known to follow.
C<--finish> drops the previous ones once nothing uses them. A secret the
service could not have started with -- the development default, or in
production a session secret shorter than 32 characters -- signed nothing:
it is replaced, not kept, since the list of those still accepted refuses it
too.

The file keeps its owner, group and mode and every other line; it is
replaced in one rename. When every account on the host may read it, the
report says so with the C<chmod 0640> that closes it, leaving the mode to the
operator. No secret is printed, under C<--json> either.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the command line. Returns 0 when done (or, with C<--finish>, when there
was nothing to drop), 1 when there is no file or it could not be read or
written, and 2 on misuse, which says what was wrong.

=head2 host

The L<GPForum::Service::Operations::Host> the service runs on.

=head2 services_installed

True when the web service's file is where this host's service manager reads
it, so the step after a rotation is a restart.

=head2 metrics_reread

True when the running web service reads the metrics tokens from the file
again by itself, so a metrics rotation names no restart: its service files
are in place, and the file is the host's own.

=head2 usage_text

The text C<--help> prints.

=head1 DIAGNOSTICS

Every sentence is in the operator's language
(L<GPForum::Command::Support::Words>).

=head1 CONFIGURATION AND ENVIRONMENT

Writes the file L<GPForum::Command::Support::ServiceEnvironment> read, or
this host's environment file.

=head1 DEPENDENCIES

L<Crypt::URandom>, L<GPForum::Command::Support::EnvironmentFileEdit> (to
change the file a line at a time and replace it in one rename),
L<GPForum::Command::Support::ServiceEnvironment>,
L<GPForum::Service::Operations::ServiceFiles> (where the service's files
go on this host).

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

Writing a file owned by another user, such as F</etc/gpforum/gpforum.env>
(root's, group C<gpforum>), needs root. The restart is printed, not run.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
