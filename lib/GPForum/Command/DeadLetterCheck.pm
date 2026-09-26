# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::DeadLetterCheck;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base, -signatures;

use GPForum::Command::Usage;
use GPForum::Service::Operations::DeadLetterCheck;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my %FLAG_OPTIONS => (
    '--help'     => 'help',
    '--json'     => 'format_json',
    '--human'    => 'format_human',
    '--dry-run'  => 'mode_dry_run',
    '--simulate' => 'mode_simulate',
);

has check => undef;

# A usage croak becomes the documented usage exit instead of an uncaught
# exception: same text, on stderr, status 2, without croak's " at FILE line N".
# Anything else is rethrown, so a real failure is not relabelled as misuse.
sub run ( $self, @arguments ) {
    my $status = eval { return $self->_run(@arguments); };
    return $status if defined $status;

    my $error = GPForum::Command::Usage->trimmed($EVAL_ERROR);
    if ( !GPForum::Command::Usage->is_usage($error) ) {
        die "$error\n";
    }

    return GPForum::Command::Usage->error( undef, $error );
}

sub _run ( $self, @arguments ) {
    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write dead-letter-check usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write dead-letter-check evidence';

    return $service->exit_status($evidence);
}

sub _service ($self) {
    return $self->check if $self->check;

    return GPForum::Service::Operations::DeadLetterCheck->new;
}

sub _options (@arguments) {
    my %options = (
        format => 'json',
        mode   => 'simulate',
        help   => 0,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $FLAG_OPTIONS{$argument} ) {
            _set_flag( \%options, $FLAG_OPTIONS{$argument} );
            next;
        }
        croak "Unknown option: $argument\n" . _usage();
    }

    return \%options;
}

sub _set_flag ( $options, $name ) {
    my %handlers = (
        help          => sub { $options->{help}   = 1 },
        format_json   => sub { $options->{format} = 'json' },
        format_human  => sub { $options->{format} = 'human' },
        mode_dry_run  => sub { $options->{mode}   = 'dry_run' },
        mode_simulate => sub { $options->{mode}   = 'simulate' },
    );
    my $handler = $handlers{$name};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _print_usage {
    print _usage() or croak 'failed to write usage';

    return 0;
}

# Public so the Mojolicious command adapter in GPForum::CLI can show the same
# text `--help` prints, instead of a second copy that drifts.
sub usage_text ($class) {
    return _usage();
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-dead-letter-check [options]

Automate the docs/ops/dead-letters.md staging check against an in-memory
outbox stack (simulate) or print the plan (dry-run). Emits EvidenceMeta JSON.
Does not claim private-beta readiness. Live staging PostgreSQL confirmation
remains a residual.

  --simulate  run permanent-failure -> dead-letter -> redispatch (default)
  --dry-run   print the staged plan only
  --json      evidence as JSON (default)
  --human     short plain-text evidence
  --help      show this help
USAGE
}

sub _trim ($error) {
    $error = "$error";
    $error =~ s/\s+\z//msx;

    return "$error\n";
}

1;

__END__

=head1 NAME

GPForum::Command::DeadLetterCheck - Dead-letter staging check CLI.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::DeadLetterCheck->new->run(@ARGV);

=head1 DESCRIPTION

Operator CLI for the dead-letter staging check harness.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
