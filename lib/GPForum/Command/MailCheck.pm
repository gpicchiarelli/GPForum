package GPForum::Command::MailCheck;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English qw(-no_match_vars);
use Mojo::Base -base;

use GPForum::Service::Operations::MailCheck;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;
const my %FLAG_OPTIONS => (
    '--help'    => 'help',
    '--json'    => 'format_json',
    '--human'   => 'format_human',
    '--dry-run' => 'mode_dry_run',
    '--send'    => 'mode_send',
);
const my %VALUE_OPTIONS => ( '--to' => 'to', );

has check => undef;

sub run {
    my ( $self, @arguments ) = @_;

    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write mail-check usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

    my $service  = $self->_service;
    my $evidence = $service->run($options);
    print $service->format_evidence( $evidence, $options->{format} )
      or croak 'failed to write mail-check evidence';

    return $service->exit_status($evidence);
}

sub _service {
    my ($self) = @_;

    return $self->check if $self->check;

    return GPForum::Service::Operations::MailCheck->new;
}

sub _options {
    my (@arguments) = @_;

    my %options = (
        format => 'json',
        mode   => 'dry_run',
        help   => 0,
        to     => undef,
    );

    while (@arguments) {
        _apply_option( \%options, shift @arguments, \@arguments );
    }

    return \%options;
}

sub _apply_option {
    my ( $options, $argument, $arguments ) = @_;

    if ( exists $FLAG_OPTIONS{$argument} ) {
        _set_flag( $options, $FLAG_OPTIONS{$argument} );
        return;
    }
    if ( exists $VALUE_OPTIONS{$argument} ) {
        _set_value( $options, $VALUE_OPTIONS{$argument}, $arguments );
        return;
    }

    croak "Unknown option: $argument\n" . _usage();
}

sub _set_flag {
    my ( $options, $name ) = @_;

    my %handlers = (
        help         => sub { $options->{help}   = 1 },
        format_json  => sub { $options->{format} = 'json' },
        format_human => sub { $options->{format} = 'human' },
        mode_dry_run => sub { $options->{mode}   = 'dry_run' },
        mode_send    => sub { $options->{mode}   = 'send' },
    );
    my $handler = $handlers{$name};
    croak _usage() if !$handler;
    $handler->();

    return;
}

sub _set_value {
    my ( $options, $name, $arguments ) = @_;

    my $value = shift @{$arguments};
    if ( !_has_text($value) ) {
        croak "--$name requires a value\n" . _usage();
    }
    $options->{$name} = $value;

    return;
}

sub _print_usage {
    print _usage() or croak 'failed to write usage';

    return 0;
}

sub _usage {
    return <<'USAGE';
Usage: bin/gpforum-mail-check [options]

Prove identity mail config and delivery readiness for private-beta prep.
Does not wait on CI. Does not claim private-beta readiness.

  --json                 evidence as JSON (default)
  --human                short plain-text evidence
  --dry-run              validate config and probe without live send
                         (default; test transport delivers to Test,
                         smtp checks TCP connect, sendmail checks binary)
  --send                 deliver a real identity verification probe
  --to EMAIL             recipient for --send (also used by test dry-run)
  --help                 show this help

Environment: GPFORUM_MAIL_TRANSPORT, GPFORUM_MAIL_FROM,
GPFORUM_PUBLIC_BASE_URL, GPFORUM_SMTP_* (password never printed).
USAGE
}

sub _has_text {
    my ($value) = @_;

    return defined $value && length $value;
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

GPForum::Command::MailCheck - Operator CLI for identity mail verification.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::MailCheck->new->run(@ARGV);

=head1 DESCRIPTION

Thin CLI around L<GPForum::Service::Operations::MailCheck>.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
