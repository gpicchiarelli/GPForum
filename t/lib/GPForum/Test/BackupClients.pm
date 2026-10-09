# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Test::BackupClients;

use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Service::Operations::StagingDrill::PgTools;

our $VERSION = '0.001';

# A pg_dump that writes a dump-shaped file where --file says and keeps what
# it was given, and a pg_restore whose --list reads three entries from a
# file that starts as a custom-format dump does (PGDMP) and refuses any
# other, as the real one does.

sub written_into ( $class, $directory ) {
    my $log    = $directory->child('log')->make_path;
    my %script = (
        pg_dump => <<"SH",
#!/bin/sh
case "\$1" in --version) echo 'pg_dump (PostgreSQL) 18.6'; exit 0;; esac
for argument in "\$@"; do
  case "\$argument" in --file=*) file="\${argument#--file=}";; esac
done
printf '%s\\n' "\$@" > '$log/pg_dump.args'
printf '%s' "\${PGPASSWORD-(unset)}" > '$log/pg_dump.password'
printf 'PGDMP a custom-format dump\\n' > "\$file"
SH
        pg_restore => <<'SH',
#!/bin/sh
case "$1" in --version) echo 'pg_restore (PostgreSQL) 18.6'; exit 0;; esac
head -c 5 "$2" | grep -q PGDMP || {
  echo 'pg_restore: error: input file does not appear to be a valid archive' >&2
  exit 1
}
printf ';\n; Archive created at 2026-10-09 05:55:30 UTC\n;\n'
printf '1; 2615 2200 SCHEMA - public pg_database_owner\n'
printf '2; 1259 16390 TABLE public posts gpforum\n'
printf '3; 0 16390 TABLE DATA public posts gpforum\n'
SH
    );
    my %found = ( log => $log );
    for my $name ( sort keys %script ) {
        my $file = $directory->child($name);
        $file->spew( $script{$name} );
        $file->chmod( oct '755' );
        $found{$name} = "$file";
    }

    return \%found;
}

# Fresh tools that run the clients written into a directory.
sub tools ( $class, $clients ) {
    return GPForum::Service::Operations::StagingDrill::PgTools->new(
        pg_dump    => $clients->{pg_dump},
        pg_restore => $clients->{pg_restore},
    );
}

1;
