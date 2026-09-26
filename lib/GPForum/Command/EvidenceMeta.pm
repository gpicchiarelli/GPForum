# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::EvidenceMeta;

use strict;
use warnings;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base, -signatures;
use Mojo::File qw(path);

use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

has finalize => undef;

sub run ( $self, @arguments ) {
    my $options = eval { return _options(@arguments) };
    if ( !$options ) {
        print {*STDERR} _trim($EVAL_ERROR)
          or croak 'failed to write evidence-meta usage error';
        return $EXIT_USAGE;
    }
    return _print_usage() if $options->{help};

    my $code = 0;
    for my $file_path ( @{ $options->{paths} } ) {
        my $result = eval { return $self->_stamp_path( $file_path, $options ) };
        if ( !$result ) {
            print {*STDERR} _trim($EVAL_ERROR)
              or croak 'failed to write evidence-meta error';
            $code = 1;
            next;
        }
        if ( !$options->{write} ) {
            print encode_json($result) . "\n"
              or croak 'failed to write stamped evidence';
        }
    }

    return $code;
}

sub _stamp_path ( $self, $file_path, $options ) {
    croak "missing evidence file: $file_path" if !-f $file_path;
    my $raw     = path($file_path)->slurp;
    my $decoded = decode_json($raw);
    croak 'evidence JSON must be an object'
      if ref $decoded ne 'HASH';

    my $finalize = $self->finalize // \&evidence_finalize;
    my $stamped  = $finalize->($decoded);

    if ( $options->{write} ) {
        my $tmp = path("$file_path.gpforum-meta.tmp");
        $tmp->spew( encode_json($stamped) . "\n" );
        rename "$tmp", $file_path
          or croak "failed to replace $file_path: $OS_ERROR";
    }

    return $stamped;
}

sub _options (@arguments) {
    my %options = (
        help  => 0,
        write => 0,
        paths => [],
    );

    while (@arguments) {
        my $argument = shift @arguments;
        if ( $argument eq '--help' || $argument eq '-h' ) {
            $options{help} = 1;
            next;
        }
        if ( $argument eq '--write' ) {
            $options{write} = 1;
            next;
        }
        if ( $argument =~ /\A-/msx ) {
            croak "Unknown option: $argument\n" . _usage();
        }
        push @{ $options{paths} }, $argument;
    }

    croak "FILE required\n" . _usage()
      if !$options{help} && !@{ $options{paths} };

    return \%options;
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
Usage: bin/gpforum-evidence-meta [options] FILE [FILE...]

Apply the shared EvidenceMeta contract to archived ops JSON
(secrets_redacted, private_beta_claimed=0, deduped residual_gaps).
Default prints stamped JSON to stdout. Does not claim private-beta readiness.

  --write    replace each FILE in place (atomic temp+rename)
  --help     show this help
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

GPForum::Command::EvidenceMeta - Stamp archived ops evidence with shared meta.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    exit GPForum::Command::EvidenceMeta->new->run(@ARGV);

=head1 DESCRIPTION

Non-destructive (stdout) or in-place (C<--write>) application of
L<GPForum::Service::Operations::EvidenceMeta>. Never claims private-beta
readiness.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
