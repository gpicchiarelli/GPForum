# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::AdminBootstrap;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::Util qw(encode);

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Command::Support::Terminal;
use GPForum::Command::Support::Words;
use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Admin::Bootstrapper;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND => 'gpforum-admin';

# The options of each way in, by the field each one fills.
const my %CREATE_OPTIONS => (
    '--display-name' => 'display_name',
    '--email'        => 'email',
    '--role-name'    => 'role_name',
    '--username'     => 'username',
);
const my %GRANT_OPTIONS => (
    '--actor-user-id' => 'actor_user_id',
    '--role-name'     => 'role_name',
    '--user-id'       => 'user_id',
);
const my %SWITCHES => (
    '--dry-run'        => 'dry_run',
    '--json'           => 'json',
    '--password-stdin' => 'password_stdin',
);

# What a sign-up says a field is wrong with, and how the operator reads it.
const my %FIELD_ERROR => (
    'display name is required'       => 'cli.admin.display_name',
    'email format is invalid'        => 'cli.admin.email_format',
    'email is already registered'    => 'cli.admin.email_taken',
    'email is required'              => 'cli.admin.email_format',
    'username format is invalid'     => 'cli.admin.username_format',
    'username is already registered' => 'cli.admin.username_taken',
    'username is required'           => 'cli.admin.username_length',
    'username length is invalid'     => 'cli.admin.username_length',
);
const my @FIELD_ORDER => qw(username email display_name password);

const my $CHECK_MARK => "\N{CHECK MARK} ";
const my $NOTE_MARK  => q{! };

has schema => undef;    # optional: connected from the environment otherwise

# Where the password is read from and its prompts written to; a test gives
# its own.
has input  => sub { return \*STDIN; };
has prompt => sub { return \*STDERR; };

has words => sub { return GPForum::Command::Support::Words->new; };

# The forum's address, for the sign-in page a new owner is sent to.
has public_base_url => sub {
    my $url;
    try {
        $url = GPForum::Config->from_environment->public_base_url;
    }
    catch ($error) {
        $url = undef;
    };
    return $url;
};

# --help is answered before anything is parsed, and a parse failure becomes a
# usage error rather than an uncaught croak: this used to exit 255 with
# " at FILE line N." glued to the help text.
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

    my $status;
    try {
        my %work = (
            create => \&_create,
            grant  => \&_grant,
            id     => \&_grant_id,
        );
        $status = $work{ $request->{action} }->( $self, $request );
    }
    catch ($error) {

        # A database the command cannot use is a failure, said in one
        # sentence with exit 1 (78 for settings), not misuse followed by the
        # usage text, as it was.
        return GPForum::Command::Usage->failure( $error,
            $request->{json}
            ? ( \*STDOUT, { command => $COMMAND, mode => $request->{action} } )
            : () );
    };

    return $status;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: gpforum admin create --email EMAIL --username NAME
                            [--display-name NAME] [--password-stdin]
                            [--dry-run] [--json]
       gpforum admin grant EMAIL|USERNAME [--dry-run] [--json]
       gpforum admin grant --user-id USER_ID [--actor-user-id USER_ID]
                           [--role-name ROLE] [--json]

create makes the forum's owner: a new account, active and verified, that can
sign in at once and holds the owner role (gpforum_owner) with every
administrative permission. It asks for the password twice on the terminal,
or reads one line from standard input with --password-stdin.

grant gives the owner role to an account that exists, found by its email
address or username, or by its id with --user-id.

  --dry-run         check what it would do, writing nothing
  --json            one JSON object on stdout instead of sentences
  --help            show this help

Both are audited, and running either again changes nothing. The
gpforum-admin-bootstrap entrypoint, from before the front door, takes grant's
--user-id options without the word grant.

Exit status: 0 done; 1 refused (an account already has that address, a
password too short, the database unreachable); 78 settings it cannot use;
2 usage error.
USAGE
}

# The action and its options. Without create or grant, the command line is
# the old bin/gpforum-admin-bootstrap's: --user-id and its company.
sub _request ( $self, @arguments ) {
    my %request = ( action => $self->_action( \@arguments ) );
    my $options =
      $request{action} eq 'create' ? \%CREATE_OPTIONS : \%GRANT_OPTIONS;
    while (@arguments) {
        $self->_take( \%request, $options, \@arguments );
    }

    return $self->_checked( \%request );
}

# create or grant, taken off the command line; grant when it opens with an
# option, as the alias's --user-id does.
sub _action ( $self, $arguments ) {
    if ( !@{$arguments} ) {
        $self->_misuse('cli.admin.needs_action');
    }
    return 'grant' if $arguments->[0] =~ /\A -/msx;

    my $action = shift @{$arguments};
    if ( $action ne 'create' && $action ne 'grant' ) {
        $self->_misuse( 'cli.admin.unknown_action', { action => $action } );
    }

    return $action;
}

# One option, with its value when it takes one, or grant's member.
sub _take ( $self, $request, $options, $arguments ) {
    my $argument = shift @{$arguments};
    if ( exists $SWITCHES{$argument} ) {
        $request->{ $SWITCHES{$argument} } = 1;
        return;
    }
    if ( exists $options->{$argument} ) {
        my $value = shift @{$arguments};
        if ( !defined $value || !length $value || $value =~ /\A -/msx ) {
            $self->_misuse( 'cli.misuse.missing_value',
                { option => $argument } );
        }
        $request->{ $options->{$argument} } = $value;
        return;
    }
    if (   $request->{action} eq 'grant'
        && $argument !~ /\A -/msx
        && !defined $request->{member} )
    {
        $request->{member} = $argument;
        return;
    }
    $self->_misuse( 'cli.misuse.unknown_option', { option => $argument } );

    return;
}

sub _checked ( $self, $request ) {
    if ( $request->{action} eq 'create' ) {
        for my $needed (qw(email username)) {
            next if defined $request->{$needed};
            $self->_misuse( 'cli.admin.needs_option',
                { option => "--$needed" } );
        }
        return $request;
    }

    if ( defined $request->{user_id} ) {
        if ( defined $request->{member} ) {
            $self->_misuse('cli.admin.member_or_id');
        }
        return { %{$request}, action => 'id' };
    }
    if ( !defined $request->{member} ) {
        $self->_misuse('cli.admin.needs_member');
    }

    return $request;
}

sub _create ( $self, $request ) {
    my $bootstrapper = $self->_bootstrapper;
    my $checked      = $bootstrapper->check_owner($request);
    if ( !$checked->{ok} ) {
        my $owner = $self->_existing_owner( $bootstrapper, $request );
        return $self->_already_created( $request, $owner ) if $owner;
        return $self->_refused( $request, $checked );
    }
    return $self->_planned( $request, 'cli.admin.would_create',
        $checked->{user} )
      if $request->{dry_run};

    my $password = $self->_password($request);
    return $password if !ref $password;

    my $created =
      $bootstrapper->create_owner( { %{$request}, password => ${$password} } );
    return $self->_refused( $request, $created ) if !$created->{ok};

    my $user = $created->{user};
    return $self->_document( $request, $created, $user ) if $request->{json};

    $self->_say(
        $CHECK_MARK . $self->_said( 'cli.admin.created', _named($user) ) );
    $self->_sign_in_next;

    return 0;
}

# The account create was asked for, when it exists already -- that address
# and that username, one member -- and holds the owner role: create run
# again, as a setup script runs it. Undef otherwise.
sub _existing_owner ( $self, $bootstrapper, $request ) {
    my $by_email    = $bootstrapper->find_member( $request->{email} );
    my $by_username = $bootstrapper->find_member( $request->{username} );
    return undef
      if !$by_email
      || !$by_username
      || $by_email->{id} ne $by_username->{id}
      || !$bootstrapper->is_owner($by_email);

    return $by_email;
}

# Refused all the same -- create never takes over an account, and the
# password given was not set -- but not pointed at admin grant, which that
# account needs no more.
sub _already_created ( $self, $request, $owner ) {
    return $self->_failed( $request, 'cli.admin.owner_exists', _named($owner) );
}

sub _grant ( $self, $request ) {
    my $bootstrapper = $self->_bootstrapper;
    my $member       = $bootstrapper->find_member( $request->{member} );
    if ( !$member ) {
        return $self->_failed( $request, 'cli.admin.no_member',
            { member => $request->{member} } );
    }
    return $self->_planned( $request, 'cli.admin.would_grant', $member )
      if $request->{dry_run};

    my $granted = $bootstrapper->bootstrap(
        {
            actor_user_id => $request->{actor_user_id},
            role_name     => $request->{role_name},
            user_id       => $member->{id},
        }
    );
    return $self->_document( $request, $granted, $member ) if $request->{json};

    my $key =
      $granted->{counts}{bindings_created}
      ? 'cli.admin.granted'
      : 'cli.admin.already_owner';
    $self->_say( $CHECK_MARK . $self->_said( $key, _named($member) ) );
    if ( !$bootstrapper->can_sign_in($member) ) {
        $self->_say( $NOTE_MARK
              . $self->_said( 'cli.admin.unverified', _named($member) ) );
    }

    return 0;
}

# The old bin/gpforum-admin-bootstrap: an account given by its id, which is
# not looked up, as it never was.
sub _grant_id ( $self, $request ) {
    my $granted = $self->_bootstrapper->bootstrap(
        {
            actor_user_id => $request->{actor_user_id},
            role_name     => $request->{role_name},
            user_id       => $request->{user_id},
        }
    );
    my $user = { id => $request->{user_id} };
    return $self->_document( $request, $granted, $user ) if $request->{json};

    my $key =
      $granted->{counts}{bindings_created}
      ? 'cli.admin.granted_id'
      : 'cli.admin.already_owner_id';
    $self->_say(
        $CHECK_MARK
          . $self->_said(
            $key, { role => $granted->{role}{name}, user => $user->{id} }
          )
    );

    return 0;
}

# The password, as a reference to it, or the exit status when there is none
# to be had. A terminal is asked twice, without echo; a pipe gives one line.
sub _password ( $self, $request ) {
    if ( $request->{password_stdin} ) {
        my $handle = $self->input;
        my $line   = <$handle>;
        if ( !defined $line ) {
            return $self->_failed( $request, 'cli.admin.no_password' );
        }
        chomp $line;
        return \$line;
    }
    if ( !GPForum::Command::Support::Terminal->new( input => $self->input )
        ->is_interactive )
    {
        return GPForum::Command::Usage->error(
            $self->_said('cli.admin.no_terminal'), _usage() );
    }

    my $first = $self->_ask( $self->_said('cli.admin.password_prompt') );
    my $again = $self->_ask( $self->_said('cli.admin.password_again') );
    if ( !defined $first || !defined $again || $first ne $again ) {
        return $self->_failed( $request, 'cli.admin.password_mismatch' );
    }

    return \$first;
}

# One line from the terminal with its echo off.
sub _ask ( $self, $question ) {
    return GPForum::Command::Support::Terminal->new(
        input  => $self->input,
        prompt => $self->prompt,
    )->hidden_line($question);
}

# A field a sign-up would refuse, said the way the operator can fix it.
sub _refused ( $self, $request, $result ) {
    my $errors = $result->{errors} // {};
    my ($field) = grep { exists $errors->{$_} } @FIELD_ORDER;
    $field //= ( sort keys %{$errors} )[0];
    my $error = $errors->{ $field // q{} } // q{};

    my $key =
      exists $FIELD_ERROR{$error}
      ? $FIELD_ERROR{$error}
      : 'cli.admin.password_short';
    return $self->_failed(
        $request, $key,
        {
            email    => lc( $request->{email}    // q{} ),
            username => lc( $request->{username} // q{} ),
            value    => $request->{ $field       // q{} } // q{},
        }
    );
}

sub _failed ( $self, $request, $key, $parameters = {} ) {
    my $sentence = GPForum::Command::Support::ServiceEnvironment->as_read(
        $self->_said( $key, $parameters ) );
    if ( $request->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                command => $COMMAND,
                error   => $sentence,
                mode    => $request->{action},
                status  => 'fail',
            }
        );
    }
    print {*STDERR} encode( 'UTF-8', "$sentence\n" )
      or croak 'failed to write admin failure';

    return $GPForum::Command::Usage::EXIT_FAILURE;
}

sub _planned ( $self, $request, $key, $member ) {
    if ( $request->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                command => $COMMAND,
                dry_run => 1,
                mode    => $request->{action},
                status  => 'ok',
                user    => _public_member($member),
            }
        );
        return 0;
    }
    $self->_say( $self->_said( $key, _named($member) ) );

    return 0;
}

sub _document ( $self, $request, $result, $user ) {
    GPForum::Command::Usage->json(
        \*STDOUT,
        {
            command => $COMMAND,
            counts  => $result->{counts},
            mode => $request->{action} eq 'id' ? 'grant' : $request->{action},
            permissions =>
              [ map { $_->{permission}{name} } @{ $result->{permissions} } ],
            role   => $result->{role}{name},
            status => 'ok',
            user   => _public_member($user),
        }
    );

    return 0;
}

sub _sign_in_next ($self) {
    my $base = $self->public_base_url;
    return if !defined $base || !length $base;

    $base =~ s{/+\z}{}msx;
    $self->_say(
        $self->_said(
            'cli.next',
            {
                step => $self->_said(
                    'cli.admin.next_sign_in', { url => "$base/login" }
                )
            }
        )
    );

    return;
}

sub _bootstrapper ($self) {
    return GPForum::Service::Admin::Bootstrapper->new(
        schema => $self->_schema );
}

sub _schema ($self) {
    return $self->schema if $self->schema;

    my $config = GPForum::Config->from_environment;
    return GPForum::Schema->connect_from_config($config);
}

sub _misuse ( $self, $key, $parameters = {} ) {
    GPForum::X::Usage->throw(
        message => $self->_said( $key, $parameters ) . "\n\n" . _usage() );
}

sub _said ( $self, $key, $parameters = {} ) {
    return $self->words->text( $key, $parameters );
}

# A command a line offers, such as gpforum admin grant for an account that
# exists, reads the file this one read when that is not the host's own.
sub _say ( $self, $line ) {
    my $read = GPForum::Command::Support::ServiceEnvironment->as_read($line);
    print encode( 'UTF-8', "$read\n" )
      or croak 'failed to write admin result';

    return;
}

sub _named ($member) {
    return {
        email    => $member->{email_normalized} // q{},
        username => $member->{username}         // q{},
    };
}

sub _public_member ($member) {
    return {
        map  { $_ => $member->{$_} }
        grep { defined $member->{$_} } qw(id username email_normalized status)
    };
}

1;

__END__

=head1 NAME

GPForum::Command::AdminBootstrap - Makes the forum's owner, or grants the
owner role.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    # gpforum admin create --email you@example.com --username you
    # gpforum admin grant you@example.com
    # bin/gpforum-admin-bootstrap --user-id UUID
    exit GPForum::Command::AdminBootstrap->new->run(@ARGV);

=head1 DESCRIPTION

C<gpforum admin> and its alias C<bin/gpforum-admin-bootstrap>, through
L<GPForum::Service::Admin::Bootstrapper>.

C<create> makes a new account that can sign in at once -- active, its
address verified -- and holds the owner role, audited as
C<admin.bootstrap_created>. It asks for the password twice on the terminal
without echo, or reads one line from standard input with
C<--password-stdin>, and ends with C<Next: sign in at
https://.../login>.

C<grant> gives the owner role to an account found by its email address or
username, and says when that account cannot sign in yet (its address not
verified). C<grant --user-id> -- and the alias, which takes the same options
without C<grant> -- binds the role to an id, which is not looked up.

C<--dry-run> checks and says what it would do, writing nothing. C<--json>
prints one object with C<status>, C<mode>, C<role>, C<user>, C<counts> and
C<permissions>; a refusal prints C<status> C<fail> and C<error>.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the command line and returns 0 when done; 1 when the account was
refused (an address or username taken, a password too short or mistyped,
no account to grant) or the database failed; 78 when the settings cannot be
used; 2 on misuse, which says what was wrong.

=head2 usage_text

The text C<--help> prints.

=head1 DIAGNOSTICS

Every sentence is in the operator's language
(L<GPForum::Command::Support::Words>). A database failure is said as
L<GPForum::Command::Usage/failure> says it.

=head1 CONFIGURATION AND ENVIRONMENT

Reads the C<GPFORUM_*> database settings and C<GPFORUM_PUBLIC_BASE_URL>
through L<GPForum::Config>.

=head1 DEPENDENCIES

L<GPForum::Service::Admin::Bootstrapper>, L<GPForum::Schema>,
L<GPForum::Command::Usage>, L<GPForum::Command::Support::Words>,
L<GPForum::Command::Support::Terminal> for the password prompt.

=head1 INCOMPATIBILITIES

The alias printed C<admin bootstrap role=... user=... created_bindings=1>;
it now says what it did in a sentence, and C<--json> carries the counts.

=head1 BUGS AND LIMITATIONS

The password prompt needs a terminal POSIX termios can turn the echo off on.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
