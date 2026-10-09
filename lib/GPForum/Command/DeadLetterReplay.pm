# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::DeadLetterReplay;

use Carp qw(croak);
use Const::Fast;
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Admin::ConsoleReader;
use GPForum::Service::Outbox::DeadLetterReplay;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $COMMAND    => 'gpforum-dead-letter-replay';
const my %SWITCH_FOR => ( '--json' => 'json', '--list' => 'list' );

# What --list --json gives of each dead letter: what a line prints, under the
# console reader's names, and when it first failed.
const my @LETTER_KEYS => qw(dead_letter_id error_class error_message
  failure_type first_failed_at last_failed_at replay_status retry_count
  source_id source_table);

has schema => undef;    # optional: connected from the environment otherwise

# A GPForum::Service::Outbox::DeadLetterReplay, for a test; otherwise one is
# built over the schema when the first id is replayed.
has replayer => undef;    # optional: built on first use otherwise

# The CLI side of ADR 0056's review and replay, for the operator on the host:
# the same service the console's Replay button uses, audited with no actor
# and via=cli.
sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $options;
    try {
        $options = _options(@arguments);
    }
    catch ($error) {
        return GPForum::Command::Usage->error( undef,
            GPForum::Command::Usage->trimmed($error) )
          if GPForum::Command::Usage->is_usage($error);

        return GPForum::Command::Usage->error(
            GPForum::Command::Usage->trimmed($error), _usage() );
    };

    my @outcomes;
    my $status;
    try {
        $status = $self->_run( $options, \@outcomes );
    }
    catch ($error) {

        # The database failed: 1 with the reason, not the 255 of an uncaught
        # exception, and under --json a document still -- holding the ids
        # replayed before the failure, each in its own transaction, so a
        # script does not take them for undone and replay them again.
        return GPForum::Command::Usage->failure( $error,
            $options->{json}
            ? ( \*STDOUT, _json_head( $options, \@outcomes ) )
            : () );
    };

    return $status;
}

sub _run ( $self, $options, $outcomes ) {
    return $self->_list($options) if $options->{list};

    my $replay = $self->_replayer;
    for my $dead_letter_id ( @{ $options->{ids} } ) {
        my $outcome = $replay->replay(
            { dead_letter_id => $dead_letter_id, via => 'cli' } );
        push @{$outcomes}, _json_outcome( $dead_letter_id, $outcome );
        if ( !$options->{json} ) {
            _say( _outcome_line( $dead_letter_id, $outcome ) );
        }
    }
    my $refused = grep { $_->{status} ne 'replayed' } @{$outcomes};
    if ( $options->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                %{ _json_head( $options, $outcomes ) },
                status => $refused ? 'fail' : 'ok',
            }
        );
    }

    return $refused
      ? $GPForum::Command::Usage::EXIT_FAILURE
      : $GPForum::Command::Usage::EXIT_OK;
}

sub _json_head ( $options, $outcomes = [] ) {
    return {
        command => $COMMAND,
        $options->{list}
        ? ( dead_letters => [], mode => 'list' )
        : ( mode => 'replay', outcomes => $outcomes ),
    };
}

# A refusal keeps its own status -- not_found, conflict -- and its reason, as
# the line does.
sub _json_outcome ( $dead_letter_id, $outcome ) {
    my %result = (
        dead_letter_id => $dead_letter_id,
        status         => $outcome->{status},
    );
    if ( $outcome->{status} eq 'replayed' ) {
        $result{outbox_id} = $outcome->{replayed}{outbox_id};
    }
    else {
        $result{error} = $outcome->{error};
    }

    return \%result;
}

# Newest first, with what an operator reads before deciding: the failure type
# and the error. A dead letter already replayed says how its replay is doing.
sub _list ( $self, $options ) {
    my $letters =
      GPForum::Service::Admin::ConsoleReader->new( schema => $self->_schema )
      ->list_dead_letters( { limit => $options->{limit} } );
    if ( $options->{json} ) {
        GPForum::Command::Usage->json(
            \*STDOUT,
            {
                %{ _json_head($options) },
                dead_letters => [ map { _json_letter($_) } @{$letters} ],
                status       => 'ok',
            }
        );
        return $GPForum::Command::Usage::EXIT_OK;
    }
    for my $letter ( @{$letters} ) {
        _say(
            join q{ },
            $letter->{dead_letter_id},
            'failed=' .  ( $letter->{last_failed_at} // q{-} ),
            'type=' .    ( $letter->{failure_type}   // q{-} ),
            'retries=' . ( $letter->{retry_count}    // 0 ),
            'replay=' .  ( $letter->{replay_status} || 'none' ),
            ( $letter->{error_class} // q{} ) . q{:},
            _one_line( $letter->{error_message} ),
        );
    }

    return $GPForum::Command::Usage::EXIT_OK;
}

sub _json_letter ($letter) {
    return { map { $_ => $letter->{$_} } @LETTER_KEYS };
}

sub _replayer ($self) {
    return $self->replayer if $self->replayer;

    return GPForum::Service::Outbox::DeadLetterReplay->new(
        schema => $self->_schema );
}

sub _schema ($self) {
    return $self->schema if $self->schema;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

sub _options (@arguments) {
    my %options = ( ids => [], json => 0, limit => 50, list => 0 );
    while (@arguments) {
        my $flag = shift @arguments;
        if ( exists $SWITCH_FOR{$flag} ) {
            $options{ $SWITCH_FOR{$flag} } = 1;
        }
        elsif ( $flag eq '--id' ) {
            push @{ $options{ids} }, _value( \@arguments );
        }
        elsif ( $flag eq '--limit' ) {
            $options{limit} = _value( \@arguments );
            if ( $options{limit} !~ /\A [1-9] \d{0,3} \z/msx ) {
                GPForum::X::Usage->throw( message => _usage() );
            }
        }
        else {
            GPForum::X::Usage->throw(
                message => "Unknown option: $flag\n\n" . _usage() );
        }
    }
    if ( !$options{list} && !@{ $options{ids} } ) {
        GPForum::X::Usage->throw( message => _usage() );
    }
    if ( $options{list} && @{ $options{ids} } ) {
        GPForum::X::Usage->throw( message => _usage() );
    }

    return \%options;
}

sub _value ($arguments) {
    my $value = shift @{$arguments};
    if ( !defined $value || !length $value || substr( $value, 0, 1 ) eq q{-} ) {
        GPForum::X::Usage->throw( message => _usage() );
    }

    return $value;
}

sub _outcome_line ( $dead_letter_id, $outcome ) {
    if ( $outcome->{status} eq 'replayed' ) {
        return "replayed $dead_letter_id as outbox "
          . $outcome->{replayed}{outbox_id};
    }

    return "not replayed $dead_letter_id ($outcome->{status}): "
      . $outcome->{error};
}

sub _one_line ($text) {
    my $line = $text // q{};
    $line =~ s/\s+/ /gmsx;

    return $line;
}

sub _say ($line) {
    print "$line\n" or croak 'failed to write dead-letter-replay output';

    return;
}

sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-dead-letter-replay --list [--limit N] [--json]
       bin/gpforum-dead-letter-replay --id DEAD_LETTER_ID [--id ...] [--json]

Review dead letters, and put their work back in the outbox once the cause is
fixed. A replay is a new outbox message for the same event; the cancelled
message and the dead letter stay as evidence, and each dead letter can be
replayed once. Exits 1 when any id was not replayed. --json prints one JSON
object on stdout instead of lines.
USAGE
}

1;

__END__

=head1 NAME

GPForum::Command::DeadLetterReplay - Review and replay dead letters from the shell.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    bin/gpforum-dead-letter-replay --list
    bin/gpforum-dead-letter-replay --id 018f...

=head1 DESCRIPTION

Lists dead letters, newest first, with their replay state, and replays the
ones named, through L<GPForum::Service::Outbox::DeadLetterReplay> -- the
service behind the console's Replay button.

=head1 SUBROUTINES/METHODS

=head2 run

Runs the command; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Exit 0 when every id was replayed, 1 when any was not or the database
failed, 2 on misuse.

=head1 CONFIGURATION AND ENVIRONMENT

The database comes from the usual C<GPFORUM_DATABASE_*> environment.

=head1 DEPENDENCIES

L<GPForum::Service::Outbox::DeadLetterReplay>,
L<GPForum::Service::Admin::ConsoleReader>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

None known.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
