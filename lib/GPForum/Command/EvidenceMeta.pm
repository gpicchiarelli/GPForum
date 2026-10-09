# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::EvidenceMeta;

use Carp qw(croak);
use Const::Fast;
use English       qw(-no_match_vars);
use JSON::MaybeXS qw(decode_json encode_json);
use Mojo::Base -base, -signatures;
use v5.40;
use Mojo::File qw(path);

use GPForum::Command::Usage;
use GPForum::Service::Operations::EvidenceMeta qw(evidence_finalize);
use GPForum::X::Config;
use GPForum::X::Usage;

our $VERSION = '0.001';

const my $EXIT_USAGE => 2;

has finalize => undef;    # optional: evidence_finalize otherwise

sub run ( $self, @arguments ) {
    my $options;
    try {
        $options = _options(@arguments);
    }
    catch ($error) {
        print {*STDERR} _trim($error)
          or croak 'failed to write evidence-meta usage error';
        return $EXIT_USAGE;
    };

    return _print_usage() if $options->{help};

    my $code = 0;
    for my $file_path ( @{ $options->{paths} } ) {
        my $result;
        try {
            $result = $self->_stamp_path( $file_path, $options );
        }
        catch ($error) {
            print {*STDERR} _trim($error)
              or croak 'failed to write evidence-meta error';
            $code = 1;
            next;
        };
        if ( !$options->{write} ) {
            print encode_json($result) . "\n"
              or croak 'failed to write stamped evidence';
        }
    }

    return $code;
}

sub _stamp_path ( $self, $file_path, $options ) {
    if ( !-f $file_path ) {
        GPForum::X::Config->throw(
            message => "missing evidence file: $file_path" );
    }
    my $raw     = path($file_path)->slurp;
    my $decoded = decode_json($raw);
    if ( ref $decoded ne 'HASH' ) {
        GPForum::X::Config->throw(
            message => 'evidence JSON must be an object' );
    }

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
            GPForum::X::Usage->throw(
                message => "Unknown option: $argument\n" . _usage() );
        }
        push @{ $options{paths} }, $argument;
    }

    if ( !$options{help} && !@{ $options{paths} } ) {
        GPForum::X::Usage->throw( message => "FILE required\n" . _usage() );
    }

    return \%options;
}

sub _print_usage {
    return GPForum::Command::Usage->help( \*STDOUT, _usage() );
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

=head1 SUBROUTINES/METHODS

=head2 finalize

The function that stamps a decoded document; a test passes its own.
Without one, C<evidence_finalize> from
L<GPForum::Service::Operations::EvidenceMeta>.

=head2 run

Runs the command with its arguments; returns the exit status.

=head2 usage_text

The usage text, for the front door.

=head1 DIAGNOSTICS

Misuse exits 2 with the reason and the usage on standard error. A file that
is missing or does not hold a JSON object (L<GPForum::X::Config>), or that
cannot be read, decoded or written, is reported on standard error with its
reason and makes the exit status 1; the other files are still stamped.
Otherwise the exit status is 0.

=head1 CONFIGURATION AND ENVIRONMENT

None: everything comes from the arguments.

=head1 DEPENDENCIES

L<GPForum::Command::Usage>, L<GPForum::Service::Operations::EvidenceMeta>,
L<JSON::MaybeXS>, L<Mojo::File>.

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
