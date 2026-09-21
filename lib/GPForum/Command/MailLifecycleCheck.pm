package GPForum::Command::MailLifecycleCheck;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Operations::MailLifecycleCheck;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my %FLAG_OPTIONS => (
    '--help'     => 'help',
    '--json'     => 'format_json',
    '--human'    => 'format_human',
    '--dry-run'  => 'mode_dry_run',
    '--simulate' => 'mode_simulate',
);
const my %VALUE_OPTIONS => ( '--to' => 'to', );

has check => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write mail-lifecycle-check usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write mail-lifecycle-check evidence';

    return $service->exit_status($evidence);
}

sub _service {
    my ($self) = @_;

    return $self->check if $self->check;

    return GPForum::Service::Operations::MailLifecycleCheck->new;
}

sub _options {
    my (@arguments) = @_;

    my %options = (
        format => 'json',
        mode   => 'simulate',
        help   => 0,
        to     => undef,
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( exists $FLAG_OPTIONS{$argument} ) {
            _set_flag( \%options, $FLAG_OPTIONS{$argument} );
            next;
        }
        if ( exists $VALUE_OPTIONS{$argument} ) {
            my $value = shift @arguments;
            croak "Missing value for $argument\n" . _usage()
              if !defined $value;
            $options{ $VALUE_OPTIONS{$argument} } = $value;
            next;
        }
        croak "Unknown option: $argument\n" . _usage();
    }

    return \%options;
}

sub _set_flag {
    my ( $options, $name ) = @_;

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

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-mail-lifecycle-check [options]

Exercise Identity::Mailer password_reset / email_change / email_verification
under Email::Sender::Transport::Test. Emits EvidenceMeta JSON. Does not claim
private-beta readiness. Staging SMTP --send remains a residual
(gpforum-mail-check).

  --simulate  deliver all three identity kinds (default)
  --dry-run   print the plan only
  --to ADDR   recipient (default mail-lifecycle@localhost)
  --json      evidence as JSON (default)
  --human     short plain-text evidence
  --help      show this help
USAGE
}

sub _trim {
    my ($error) = @_;

    $error = "$error";
    $error =~ s/\s+\z//msx;

    return "$error\n";
}

1;

__END__

=head1 NAME

GPForum::Command::MailLifecycleCheck - Identity mail lifecycle CLI.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::MailLifecycleCheck->new->run(@ARGV);

=head1 DESCRIPTION

Operator CLI for the identity mail lifecycle drill.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
