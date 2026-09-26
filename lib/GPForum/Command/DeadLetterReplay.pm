# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::DeadLetterReplay;

use strict;
use warnings;

use Carp    qw(croak);
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Config;
use GPForum::Schema;
use GPForum::Service::Admin::ConsoleReader;
use GPForum::Service::Outbox::DeadLetterReplay;

our $VERSION = '0.001';

has schema => undef;

# The CLI side of ADR 0056's review and replay, for the operator on the host:
# the same service the console's Replay button uses, audited with no actor
# and via=cli.
sub run ( $self, @arguments ) {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() )
      if GPForum::Command::Usage->wants_help(@arguments);

    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( GPForum::Command::Usage->is_usage($error) ) {
        return GPForum::Command::Usage->error( undef, $error );
    }
    if ( $error =~ /\A Unknown [ ] option: /msx ) {
        return GPForum::Command::Usage->error( $error, _usage() );
    }

    die "$error\n";
}

sub _run ( $self, @arguments ) {
    my $options = _options(@arguments);
    return $self->_list($options) if $options->{list};

    my $replay =
      GPForum::Service::Outbox::DeadLetterReplay->new(
        schema => $self->_schema );
    my $refused = 0;
    for my $dead_letter_id ( @{ $options->{ids} } ) {
        my $outcome = $replay->replay(
            { dead_letter_id => $dead_letter_id, via => 'cli' } );
        if ( $outcome->{status} ne 'replayed' ) {
            $refused++;
        }
        _say( _outcome_line( $dead_letter_id, $outcome ) );
    }

    return $refused
      ? $GPForum::Command::Usage::EXIT_FAILURE
      : $GPForum::Command::Usage::EXIT_OK;
}

# Newest first, with what an operator reads before deciding: the failure type
# and the error. A dead letter already replayed says how its replay is doing.
sub _list ( $self, $options ) {
    my $letters =
      GPForum::Service::Admin::ConsoleReader->new( schema => $self->_schema )
      ->list_dead_letters( { limit => $options->{limit} } );
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

sub _schema ($self) {
    return $self->schema if $self->schema;

    return GPForum::Schema->connect_from_config(
        GPForum::Config->from_environment );
}

sub _options (@arguments) {
    my %options = ( ids => [], limit => 50, list => 0 );
    while (@arguments) {
        my $flag = shift @arguments;
        if ( $flag eq '--list' ) {
            $options{list} = 1;
        }
        elsif ( $flag eq '--id' ) {
            push @{ $options{ids} }, _value( \@arguments );
        }
        elsif ( $flag eq '--limit' ) {
            $options{limit} = _value( \@arguments );
            croak _usage() if $options{limit} !~ /\A [1-9] \d{0,3} \z/msx;
        }
        else {
            croak "Unknown option: $flag";
        }
    }
    croak _usage() if !$options{list} && !@{ $options{ids} };
    croak _usage() if $options{list}  && @{ $options{ids} };

    return \%options;
}

sub _value ($arguments) {
    my $value = shift @{$arguments};
    croak _usage()
      if !defined $value || !length $value || substr( $value, 0, 1 ) eq q{-};

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
Usage: bin/gpforum-dead-letter-replay --list [--limit N]
       bin/gpforum-dead-letter-replay --id DEAD_LETTER_ID [--id ...]

Review dead letters, and put their work back in the outbox once the cause is
fixed. A replay is a new outbox message for the same event; the cancelled
message and the dead letter stay as evidence, and each dead letter can be
replayed once. Exits 1 when any id was not replayed.
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

Exit 0 when every id was replayed, 1 when any was not, 2 on misuse.

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
