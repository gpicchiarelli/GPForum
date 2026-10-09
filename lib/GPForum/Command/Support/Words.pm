# SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
# SPDX-License-Identifier: BSD-3-Clause

package GPForum::Command::Support::Words;

use Const::Fast;
use List::Util qw(any uniq);
use Mojo::Base -base, -signatures;
use v5.40;

use GPForum::Command::Support::ServiceEnvironment;
use GPForum::Config::Report;
use GPForum::Service::I18N::CliCatalog;

our $VERSION = '0.001';

# What the front door and its commands say to an operator, in English, keyed
# as the command-line catalogs (locale/cli/*.po) key their messages; it.po
# has the Italian, and t/483 holds en.po to these words. The English is here,
# beside the code that says it, as gettext keeps a msgid in the source.
const my %ENGLISH => (
    'cli.next'            => 'Next: {step}',
    'cli.then'            => 'Then: {step}',
    'cli.restart_service' =>
      q{restart GPForum's web service and its outbox worker},
    'cli.start_service' => q{start GPForum's web service and its outbox worker},
    'cli.config.footer_file'  => 'Set these in {file}, then try again.',
    'cli.config.footer_shell' => q{The shell's environment sets {variables},}
      . ' which comes before {file}: correct it there, or unset it, then try'
      . ' again.',

    'cli.env_file.missing' => 'There is no {file}: correct the path given'
      . ' to --env-file, or make the file from deploy/gpforum.env.example.',
    'cli.env_file.unreadable' => 'Cannot read {file} ({reason}): run gpforum'
      . q{ as the service's user, with sudo -u gpforum, or as root.},
    'cli.env_file.malformed' => 'Line {line} of {file} is not NAME=value:'
      . ' correct it, or start it with # to leave it out.',

    'cli.front_door.unknown'       => q{'{command}' is not a gpforum command.},
    'cli.front_door.see_help'      => 'gpforum help lists them all.',
    'cli.front_door.global_option' => q{gpforum has no option {option}:}
      . q{ a command's own options go after its name.},

    'cli.misuse.unknown_option' => '{option} is not an option of this command.',
    'cli.misuse.missing_value'  => '{option} needs a value.',
    'cli.misuse.positive_integer' =>
      q{{option} takes a whole number above zero, not '{value}'.},
    'cli.misuse.non_negative_integer' =>
      q{{option} takes a whole number, not '{value}'.},
    'cli.misuse.non_negative_number' =>
      q{{option} takes a number, not '{value}'.},
    'cli.misuse.choice' => q{{option} takes one of {choices}, not '{value}'.},
    'cli.misuse.value'  => q{{option} does not take '{value}'.},
    'cli.misuse.the_value' => 'The value',

    'cli.help.usage' => 'Usage: gpforum [--env-file FILE] COMMAND [OPTIONS]',
    'cli.help.group.setup'     => 'Set up',
    'cli.help.group.run'       => 'Run',
    'cli.help.group.check'     => 'Check',
    'cli.help.group.maintain'  => 'Maintain',
    'cli.help.group.more'      => 'Benchmarks, seeds, drills and evidence',
    'cli.help.group.framework' => q{Mojolicious's and Minion's own},
    'cli.help.settings_file'   =>
      q{Settings are read from {file}; the shell's environment comes first.},
    'cli.help.settings_shell' => q{Settings come from the shell's environment:}
      . ' this host has no {file}.',
    'cli.help.footer' => 'gpforum help COMMAND explains one;'
      . ' gpforum help --all lists every command.',
    'cli.help.footer_all' => 'gpforum help COMMAND explains one.',

    'cli.verb.setup' =>
      'Set this host up: the settings, the database, the schema',
    'cli.verb.migrate' => 'Bring the database up to date',
    'cli.verb.admin'   => q{Create the forum's owner, or make a member one},
    'cli.verb.secret'  => 'Rotate the session secret or the metrics token',
    'cli.verb.service' => 'Print the service files, written for this host',
    'cli.verb.start'   => 'Run the forum in this terminal, for development',
    'cli.verb.outbox'  => 'Send the queued mail and events',
    'cli.verb.scheduled_jobs' => 'Run the retention and clean-up jobs once',
    'cli.verb.doctor'         =>
      'Check the forum, from its settings to its address, with what to fix',
    'cli.verb.status'          => q{Show the running forum's readiness report},
    'cli.verb.mail_check'      => 'Check that mail can leave this host',
    'cli.verb.antivirus_check' => 'Check that uploads are scanned',
    'cli.verb.platform_check'  => 'Check that this host can run GPForum',
    'cli.verb.os_preflight'    =>
      q{Check the host's limits against the processes it runs},
    'cli.verb.search_rebuild' => 'Rebuild the search index, or report its lag',
    'cli.verb.dead_letters'   => 'Review and replay messages that kept failing',
    'cli.verb.partitions'     => 'Create the next monthly log partitions',
    'cli.verb.budgets'        => 'Check or sync the query budgets',
    'cli.verb.backup'         => 'Back up the database and the uploads',
    'cli.verb.restore'        => 'Check that a backup can be restored',
    'cli.verb.upgrade'        => 'Print the commands that upgrade this forum',
    'cli.verb.benchmark'      => 'Benchmark the pages a member reads most',
    'cli.verb.hypnotoad_benchmark' =>
      'Benchmark Hypnotoad, optionally behind a proxy',
    'cli.verb.hypnotoad_scaling' => 'Benchmark Hypnotoad across worker counts',
    'cli.verb.performance_seed'  => 'Seed data for performance work',
    'cli.verb.stress_load'       => 'Put a running forum under load',
    'cli.verb.query_plan_evidence' =>
      'Collect EXPLAIN evidence for the budgeted pages',
    'cli.verb.staging_drill'             => 'Rehearse a backup and restore',
    'cli.verb.staging_drill_attachments' =>
      'Rehearse the attachment store, end to end',
    'cli.verb.staging_host_verify' => 'Verify a host against the deploy files',
    'cli.verb.evidence_meta'       => 'Stamp an evidence file',
    'cli.verb.evidence_validate'   => 'Validate an evidence bundle',
    'cli.verb.dead_letter_check' => 'Rehearse the dead-letter path, in memory',
    'cli.verb.mail_lifecycle_check' => q{Rehearse mail's lifecycle, end to end},

    'cli.migrate.applied_one'  => 'Applied migration {version}, {description}',
    'cli.migrate.applied_many' =>
      'Applied {count} migrations, {first} to {last}',
    'cli.migrate.current'         => 'Schema is current ({version})',
    'cli.migrate.partitions_one'  => 'created {count} monthly partition',
    'cli.migrate.partitions_many' => 'created {count} monthly partitions',
    'cli.migrate.budgets'     => 'synced the query budgets ({count} changed)',
    'cli.migrate.pending_one' =>
      '1 migration to apply, {version} {description}',
    'cli.migrate.pending_many' =>
      '{count} migrations to apply, {first} to {last}',
    'cli.migrate.next_apply' => 'gpforum migrate',
    'cli.migrate.next_owner' => q{make the forum's owner, with}
      . ' gpforum admin create --email you@example.com --username you',
    'cli.migrate.next_restart' => 'restart the service on the new schema,'
      . ' with {restart}',
    'cli.migrate.next_start' => 'gpforum start --foreground',
    'cli.migrate.one_mode'   => 'Choose one of --plan, --apply and --check.',
    'cli.migrate.partitions_with_apply' =>
      '--no-partitions goes with applying, not with --plan or --check.',

    'cli.outbox.watching' => 'Sending queued mail and events as they come,'
      . ' looking every {seconds} s; Ctrl-C stops.',
    'cli.outbox.nothing'   => 'Nothing was waiting to be sent.',
    'cli.outbox.sent_one'  => '1 message sent',
    'cli.outbox.sent_many' => '{count} messages sent',
    'cli.outbox.retry'     => '{count} to be tried again later',
    'cli.outbox.dead_one'  => '1 given up on',
    'cli.outbox.dead_many' => '{count} given up on',
    'cli.outbox.lost_one'  => '1 left to the worker that took it over',
    'cli.outbox.lost_many' => '{count} left to the worker that took them over',
    'cli.outbox.next_dead' => 'see why with gpforum dead-letters --list',

    'cli.partitions.planned_one' =>
      '1 monthly partition to create, up to {month}.',
    'cli.partitions.planned_many' =>
      '{count} monthly partitions to create, up to {month}.',
    'cli.partitions.created_one' =>
      'Created 1 monthly partition; they reach {month}.',
    'cli.partitions.created_many' =>
      'Created {count} monthly partitions; they reach {month}.',
    'cli.partitions.in_place' => 'The monthly partitions reach {month}.',
    'cli.partitions.skipped'  =>
      'Another run is creating the partitions now; this one did nothing.',
    'cli.partitions.conflict' => 'partitions: {partition} cannot be created:'
      . ' {rows} rows already in {default} fall in its range',
    'cli.partitions.conflict_note' => 'Run these in psql, in a maintenance'
      . ' window: they lock {table} while they move the rows.',
    'cli.partitions.error' =>
      'partitions: {partition} could not be created: {error}',

    'cli.budgets.missing'    => 'Not in the database: {endpoints}',
    'cli.budgets.extra'      => 'No longer in the code: {endpoints}',
    'cli.budgets.mismatched' => q{Other numbers than the code's: {endpoints}},

    'cli.jobs.name.sessions'        => 'expired sessions',
    'cli.jobs.name.identity_tokens' =>
      'expired sign-in and verification tokens',
    'cli.jobs.name.rate_limit_buckets'  => 'old rate-limit counters',
    'cli.jobs.name.outbox_messages'     => 'old outbox messages',
    'cli.jobs.name.dead_letters'        => 'old dead letters',
    'cli.jobs.name.attachments'         => 'orphaned attachments',
    'cli.jobs.name.attachment_scans'    => 'uploads waiting for a scan',
    'cli.jobs.name.attachment_backfill' => 'uploads never scanned',
    'cli.jobs.name.partitions'          => 'the partition window',
    'cli.jobs.removed_one'              => '{job}: 1 removed',
    'cli.jobs.removed_many'             => '{job}: {count} removed',
    'cli.jobs.scanned_one'              => '{job}: 1 scanned',
    'cli.jobs.scanned_many'             => '{job}: {count} scanned',
    'cli.jobs.done'                     => '{job}: checked',
    'cli.jobs.skipped'                  => '{job}: not run ({reason})',
    'cli.jobs.failed'                   => '{job}: {error}',

    'cli.jobs.reason.antivirus_unavailable' => 'antivirus unavailable',
    'cli.jobs.reason.failed'                => 'failed',
    'cli.jobs.reason.scanning_off'          => 'scanning is off',
    'cli.jobs.reason.unavailable'           => 'not available here',

    'cli.admin.needs_action' =>
      'Say what to do: gpforum admin create, or gpforum admin grant.',
    'cli.admin.unknown_action' =>
      q{'{action}' is not something gpforum admin does: create or grant.},
    'cli.admin.needs_option' => 'gpforum admin create needs {option}.',
    'cli.admin.needs_member' =>
      'Say whom to make the owner: their email address or username.',
    'cli.admin.member_or_id' =>
      'Name the member by address, username or --user-id: one of them.',
    'cli.admin.username_length' =>
      q{A username is 3 to 32 characters, not '{value}'.},
    'cli.admin.username_format' => 'A username is lowercase letters, digits'
      . q{ and _, starting with a letter, not '{value}'.},
    'cli.admin.email_format'   => q{'{value}' is not an email address.},
    'cli.admin.display_name'   => 'The display name cannot be empty.',
    'cli.admin.password_short' =>
      'The password needs at least 12 characters; nothing was created.',
    'cli.admin.owner_exists' => '{username} ({email}) is the forum'
      . q{'s owner already; nothing was created, and its password is as it}
      . ' was.',
    'cli.admin.username_taken' => 'There is already an account named'
      . ' {username}: make it the owner with gpforum admin grant {username}.',
    'cli.admin.email_taken' => 'There is already an account with {email}:'
      . ' make it the owner with gpforum admin grant {email}.',
    'cli.admin.no_terminal' => 'There is no terminal to ask for the password'
      . ' on: give it on standard input with --password-stdin.',
    'cli.admin.no_password' =>
      'Standard input held no password; nothing was created.',
    'cli.admin.password_prompt'   => 'Password (at least 12 characters):',
    'cli.admin.password_again'    => 'The same password again:',
    'cli.admin.password_mismatch' =>
      'The two passwords differ; nothing was created.',
    'cli.admin.created' =>
      q{{username} ({email}) is the forum's owner and can sign in now.},
    'cli.admin.granted'       => q{{username} ({email}) is the forum's owner.},
    'cli.admin.already_owner' =>
      q{{username} ({email}) was the forum's owner already; nothing changed.},
    'cli.admin.granted_id'       => 'User {user} holds the {role} role.',
    'cli.admin.already_owner_id' =>
      'User {user} held the {role} role already; nothing changed.',
    'cli.admin.unverified' => '{username} has not verified {email} yet,'
      . ' and can sign in once they have.',
    'cli.admin.no_member' => q{No account has the address or username}
      . q{ '{member}': make one with gpforum admin create.},
    'cli.admin.would_create' => q{Would create {username} ({email}) as the}
      . q{ forum's owner; nothing was written.},
    'cli.admin.would_grant' =>
q{Would make {username} ({email}) the forum's owner; nothing was written.},
    'cli.admin.next_sign_in' => 'sign in at {url}',

    'cli.secret.needs_rotate' =>
      'gpforum secret rotates: gpforum secret rotate session, or metrics.',
    'cli.secret.needs_kind' =>
      'Say which secret to rotate: session or metrics.',
    'cli.secret.unknown_kind' =>
      q{'{kind}' is not a secret gpforum rotates: session or metrics.},
    'cli.secret.no_file' => 'There is no environment file to write to:'
      . ' make {file} from deploy/gpforum.env.example, or name one with'
      . ' gpforum --env-file FILE secret rotate {kind}.',
    'cli.secret.unwritable' =>
      'Cannot write {file} ({reason}): run it as root: {command}',
    'cli.secret.world_readable' => 'Every account on this host can read'
      . ' {file}, secrets included: {command}',
    'cli.secret.nothing_to_finish' =>
      '{file} lists no previous one in {list}: there is nothing to finish.',
    'cli.secret.session.rotated' => 'A new session secret is in {file}.'
      . ' The one before stays in {list}, so nobody is signed out.',
    'cli.secret.session.first'    => 'A new session secret is in {file}.',
    'cli.secret.session.finished' => 'The previous session secrets are gone'
      . ' from {file}; a cookie they signed no longer signs anyone in.',
    'cli.secret.session.would_rotated' => 'Would write a new session secret'
      . ' to {file} and keep the one before in {list}; nothing was written.',
    'cli.secret.session.would_first' =>
      'Would write a new session secret to {file}; nothing was written.',
    'cli.secret.session.would_finished' => 'Would drop the previous session'
      . ' secrets from {file}; nothing was written.',
    'cli.secret.session.then' => 'in {days} days, when every session has'
      . ' been renewed, gpforum secret rotate session --finish',
    'cli.secret.metrics.rotated' => 'A new metrics token is in {file}.'
      . ' The one before stays in {list}, so no scraper is refused.',
    'cli.secret.metrics.first'    => 'A new metrics token is in {file}.',
    'cli.secret.metrics.finished' => 'The previous metrics tokens are gone'
      . ' from {file}; a scraper that sends one is refused.',
    'cli.secret.metrics.would_rotated' => 'Would write a new metrics token'
      . ' to {file} and keep the one before in {list}; nothing was written.',
    'cli.secret.metrics.would_first' =>
      'Would write a new metrics token to {file}; nothing was written.',
    'cli.secret.metrics.would_finished' => 'Would drop the previous metrics'
      . ' tokens from {file}; nothing was written.',
    'cli.secret.metrics.then' => 'give every scraper the new {variable} from'
      . ' {file}, then gpforum secret rotate metrics --finish',
    'cli.secret.metrics.first_live' => 'A new metrics token is in {file},'
      . ' and the running service asks for it now, with no restart.',
    'cli.secret.metrics.rotated_live' => 'A new metrics token is in {file}.'
      . ' The one before stays in {list}, and the running service accepts'
      . ' both now, with no restart.',
    'cli.secret.metrics.finished_live' => 'The previous metrics tokens are'
      . ' gone from {file}, and the running service refuses them now, with no'
      . ' restart.',
    'cli.secret.metrics.next_scrapers' =>
      'give every scraper the new {variable} from {file}',

    'cli.upgrade.title' =>
      'Upgrade this forum with these three commands, in order:',
    'cli.upgrade.restart'            => 'After gpforum migrate, {step}.',
    'cli.upgrade.restart_foreground' =>
      'restart the forum you run with gpforum start --foreground',
    'cli.upgrade.complete' => 'The last one ends with "Nothing to fix." when'
      . ' the upgrade is complete.',
    'cli.upgrade.backup' => 'Before them, a backup to come back to: {command}',
    'cli.upgrade.guide'  => 'docs/ops/upgrade.md says what each one does, and'
      . ' the CHANGELOG what a release asks besides, under "Operator action'
      . ' required".',

    'cli.service.needs_print' => 'Say what to print: gpforum service print,'
      . ' or gpforum service print nginx.',
    'cli.service.no_target' => 'This host has no service manager GPForum'
      . ' ships files for: name one, {targets}.',
    'cli.service.unknown_file' => q{'{name}' is not one of {target}'s files}
      . ' ({names}), nor something gpforum service prints ({targets}).',
    'cli.service.placeholder_host' => 'GPFORUM_PUBLIC_BASE_URL is {url}, not'
      . ' the address members reach the forum at, so the site is written for'
      . ' {host}: set {variable} {where}, then print it again.',
    'cli.service.nginx_include' => 'nginx reads it once the http block of'
      . ' /usr/local/etc/nginx/nginx.conf has the line include'
      . ' conf.d/*.conf;',
    'cli.service.certificate' => 'The site names its certificate under'
      . ' /etc/letsencrypt/live/{host}/: correct the two ssl_certificate lines'
      . ' if yours is elsewhere.',
    'cli.service.caddy_whole' => q{The Caddyfile is the whole of Caddy's}
      . ' configuration: if Caddy serves other sites too, add this block to'
      . ' yours instead.',
    'cli.service.cannot_write' =>
      'Cannot write the files into {directory} ({reason}).',
    'cli.service.not_directory' => '{directory} is a file, not a directory:'
      . ' name a directory to write the files into.',
    'cli.service.foreign_files' => q{{directory} holds files that are not}
      . q{ {target}'s ({files}), which copying its contents would install}
      . ' too: name an empty directory, or a new one.',
    'cli.service.not_files' => '{directory} holds {files} as links or'
      . ' directories, not files, and writing there would follow them: name'
      . ' an empty directory, or a new one.',
    'cli.service.open_directory' => '{directory} can be changed by another'
      . ' account, which could change the files before you copy them into'
      . ' place: name a directory of your own.',
    'cli.service.wrote_one'  => '{files} for {target} is in {directory}.',
    'cli.service.wrote_many' =>
      '{count} files for {target} are in {directory}: {files}.',
    'cli.service.next_one'           => 'put it in place:',
    'cli.service.next_many'          => 'put them in place and start them:',
    'cli.service.next_in_place_one'  => 'make it take effect:',
    'cli.service.next_in_place_many' => 'start them:',
    'cli.service.no_certificate' => 'There is no {certificate} yet, and nginx'
      . ' refuses a site without its certificate: take it first, with'
      . ' {command}, then print the site again.',
    'cli.service.next_read_one'  => 'read it, then put it in place:',
    'cli.service.next_read_many' =>
      'read them, then put them in place and start them:',

    'cli.backup.no_words' => q{gpforum backup takes no '{word}': name the}
      . ' directory with --to {word}.',
    'cli.backup.not_directory' => '{directory} is a file, not a directory: name'
      . ' a directory with --to.',
    'cli.backup.in_code' => '{directory} is inside the code directory'
      . ' {root}, which an upgrade replaces: name another with --to,'
      . ' such as --to /var/backups/gpforum.',
    'cli.backup.in_attachments' => '{directory} is inside the attachment root'
      . ' {root}, which the backup copies: name another with --to, such'
      . ' as --to /var/backups/gpforum.',
    'cli.backup.cannot_make' => 'Cannot make {directory} ({reason}): make it'
      . ' for {user} first, with sudo install -d -o {user} -m 700'
      . ' {typed}',
    'cli.backup.dump_older' => 'pg_dump {client} cannot back up PostgreSQL'
      . q{ {server}, which is newer: install PostgreSQL {major}'s client}
      . ' programs, or name their pg_dump with GPFORUM_PG_DUMP.',
    'cli.backup.dump_failed' =>
      'pg_dump could not back up the database {database}: {said}',
    'cli.backup.archive_as_owner' => 'Cannot copy the uploads in {root} as'
      . ' {user} ({said}): run the backup as {owner}, who owns them, with'
      . ' {command}',
    'cli.backup.archive_failed' => 'Cannot copy the uploads in {root}'
      . ' ({said}): make every file and directory in it readable by {user},'
      . ' then run the backup again.',
    'cli.backup.no_client' => q{Cannot find PostgreSQL's pg_dump and}
      . ' pg_restore: install its client programs, or name them with'
      . ' GPFORUM_PG_DUMP and GPFORUM_PG_RESTORE.',
    'cli.backup.database' => 'database {database}: {size}, schema'
      . ' {schema}, PostgreSQL {server}',
    'cli.backup.database_bare' => 'database {database}: {size}, PostgreSQL'
      . ' {server}',
    'cli.backup.attachments_one'  => 'attachments: 1 file, {size}, from {root}',
    'cli.backup.attachments_many' => 'attachments: {count} files, {size}, from'
      . ' {root}',
    'cli.backup.attachments_none' => 'attachments: none yet, in {root}',
    'cli.backup.no_attachments' => 'attachments: {root} does not exist, so the'
      . ' backup holds no uploads',
    'cli.backup.done'       => 'Backed up into {directory}',
    'cli.backup.next_check' => 'check that it can be restored, with {command}',

    'cli.restore.needs_check' => 'gpforum restore checks a backup and restores'
      . ' nothing: gpforum restore --check DIR. Restoring one is done'
      . ' by hand, with the steps in {guide}.',
    'cli.restore.no_directory' => 'manifest: there is no {directory}',
    'cli.restore.no_manifest'  => 'manifest: {directory} has no manifest.json,'
      . ' so it is not a GPForum backup',
    'cli.restore.holds_backups' =>
      'manifest: {directory} holds backups, and is not one itself',
    'cli.restore.bad_manifest' => 'manifest: {directory}/manifest.json is not a'
      . q{ GPForum backup's manifest},
    'cli.restore.newer_manifest' =>
      'manifest: {directory} was written by a newer GPForum than this one',
    'cli.restore.manifest' => 'manifest: {database}, taken {taken}, schema'
      . ' {schema}',
    'cli.restore.missing'    => '{file}: not in the backup',
    'cli.restore.not_listed' => '{file}: the manifest does not list it, so'
      . ' the backup is not whole',
    'cli.restore.cannot_read' => 'manifest: {user} cannot read {path}: check'
      . ' the backup as its owner, {owner}, with {command}',
    'cli.restore.file_cannot_read' => '{file}: {user} cannot read it: check'
      . ' the backup as its owner, {owner}, with {command}',
    'cli.restore.size_differs' => '{file}: {size}, where the backup wrote'
      . ' {expected}: it was cut short or changed',
    'cli.restore.checksum_differs' => '{file}: its SHA-256 is not the one the'
      . ' backup wrote: it changed after the backup',
    'cli.restore.no_pg_restore' =>
      q{{file}: cannot be read without PostgreSQL's}
      . ' pg_restore: install its client programs, or name it with'
      . ' GPFORUM_PG_RESTORE',
    'cli.restore.dump_unreadable' =>
      '{file}: pg_restore cannot read it ({reason})',
    'cli.restore.dump_ok' => '{file}: {size}, as the backup wrote it;'
      . ' pg_restore reads its {entries} entries',
    'cli.restore.archive_unreadable' => '{file}: tar cannot read it ({reason})',
    'cli.restore.archive_count' => '{file}: {files} files, where the backup'
      . ' wrote {expected}',
    'cli.restore.archive_ok_one' =>
      '{file}: {size}, as the backup wrote it; 1 file',
    'cli.restore.archive_ok' => '{file}: {size}, as the backup wrote it;'
      . ' {files} files',
    'cli.restore.file_ok'        => '{file}: {size}, as the backup wrote it',
    'cli.restore.no_attachments' => 'attachments: none; the attachment root did'
      . ' not exist when the backup was taken',
    'cli.restore.sound' => 'The backup can be restored; nothing was restored.',
    'cli.restore.unsound'      => 'This backup cannot be restored as it is.',
    'cli.restore.next_restore' => 'to restore it, follow the steps in {guide}',
    'cli.restore.next_latest'  => 'check its newest backup, with {command}',
    'cli.restore.next_backup'  => 'keep it as it is, and take another with'
      . ' gpforum backup',

    'cli.start.busy' => 'Something else listens on {listen} ({reason}):'
      . ' stop it, or listen on another port: {other}',
    'cli.start.cannot_listen' => 'Cannot listen on {listen} ({reason}):'
      . ' listen on an address this host has: {other}',
    'cli.start.foreground' => 'gpforum start runs the forum in this terminal,'
      . ' for development, with --foreground. A server runs it under its'
      . ' service manager: {start}',
    'cli.start.no_hypnotoad' => 'There is no {file}, so the dependencies are'
      . ' not installed: sudo bin/gpforum setup installs them.',
);

# The secrets gpforum secret rotate writes, by the setting that holds them.
const my %ROTATES => (
    GPFORUM_SESSION_SECRET => 'session',
    GPFORUM_METRICS_TOKEN  => 'metrics',
);

has catalog => sub { return GPForum::Service::I18N::CliCatalog->new; };

sub english ($class) {
    return {%ENGLISH};
}

# A key's template in the operator's language, else in English, else undef.
sub template ( $self, $key ) {
    return $self->catalog->template($key)
      // ( exists $ENGLISH{$key} ? $ENGLISH{$key} : undef );
}

# The text for a key with each {name} filled in; a key nobody knows comes
# back as it is.
sub text ( $self, $key, $parameters = {} ) {
    return GPForum::Config::Report->text( $key, $parameters,
        sub ($wanted) { return $self->template($wanted); } );
}

# A configuration's problems as the operator reads them. Its last line names
# the environment file this process read, when it read one; the template's
# name otherwise.
#
# A secret it lacks, or one too short, is one command away when it read a
# file: gpforum secret rotate writes it there, so the report offers that
# instead of openssl and an editor (ADR 0120). With sudo when this process
# cannot write the file, and with --env-file when it is not the host's.
sub config_report ( $self, $problems, $file = undef ) {
    my %shell = map { $_ => 1 } _from_shell( $problems, $file );
    return GPForum::Config::Report->render(
        [ map { _with_rotation( $_, $file, \%shell ) } @{$problems} ],
        sub ($key) {
            return $self->template($key)
              if !defined $file || $key ne 'config.footer';
            return $self->_footer( $problems, $file, \%shell );
        }
    );
}

# The report's last line: where to set what is wrong. A variable the
# process environment held when the file was read stays as the shell set
# it, whatever the file says, so the report sends the operator to the
# shell for it: told to set GPFORUM_ENV in the file, which already said
# production, they found nothing there to change.
sub _footer ( $self, $problems, $file, $shell ) {
    my @lines;
    if ( any { !$shell->{ $_->{variable} // q{} } } @{$problems} ) {
        push @lines, $self->text( 'cli.config.footer_file', { file => $file } );
    }
    if ( %{$shell} ) {
        push @lines,
          $self->text( 'cli.config.footer_shell',
            { file => $file, variables => join q{, }, sort keys %{$shell} } );
    }

    return join "\n", @lines;
}

# The variables of the problems that the process environment holds and the
# file did not assign: the shell set them.
sub _from_shell ( $problems, $file ) {
    return () if !defined $file;

    my %assigned = map { $_ => 1 }
      @{ GPForum::Command::Support::ServiceEnvironment->assigned };
    return uniq grep { exists $ENV{$_} && !$assigned{$_} }
      map { $_->{variable} // () } @{$problems};
}

sub _with_rotation ( $problem, $file, $shell ) {
    my $variable = $problem->{variable} // q{};
    return $problem
      if !defined $file
      || !defined $problem->{generate}
      || !exists $ROTATES{$variable}
      || $shell->{$variable};

    my $host    = GPForum::Command::Support::ServiceEnvironment->new;
    my @command = (
        ( -w $file ? () : 'sudo' ),
        'gpforum',
        ( $file eq $host->default_file ? () : ( '--env-file', $file ) ),
        'secret',
        'rotate',
        $ROTATES{$variable},
    );

    return { %{$problem}, generate => join q{ }, @command };
}

1;

__END__

=head1 NAME

GPForum::Command::Support::Words - What the command line says, in the
operator's language.

=head1 VERSION

Version 0.001.

=head1 SYNOPSIS

    my $words = GPForum::Command::Support::Words->new;
    say $words->text( 'cli.migrate.current', { version => '051' } );
    print {*STDERR} $words->config_report( $error->problems,
        '/etc/gpforum/gpforum.env' );

=head1 DESCRIPTION

The front door's words and its commands', keyed C<cli.*> in the
command-line catalogs (C<locale/cli/en.po>, C<it.po>) and read through
L<GPForum::Service::I18N::CliCatalog>, so they follow C<LC_ALL>,
C<LC_MESSAGES> or C<LANG> as the rest of what GPForum says to an operator
does. The English lives here too, as the msgid does in gettext's sources: a
key a catalog lacks is said in English.

=head1 SUBROUTINES/METHODS

=head2 english

Class method. Every C<cli.*> key with its English, as en.po must carry it.

=head2 template

A key's template in the catalog's language, else in English, else undef.

=head2 text

Takes a key and an optional hash reference of placeholder values and
returns the text with each C<{name}> filled in.

=head2 config_report

Takes the problems a L<GPForum::X::Config> carries and, optionally, the
environment file this process read, and returns the report whose last line
says to set them there -- or, for a variable the shell's environment set,
which the file cannot override, to correct or unset it in the shell. A
secret the file lacks is offered as the C<gpforum secret rotate> that
writes it.

=head1 DIAGNOSTICS

None: a key nobody knows comes back as it is.

=head1 CONFIGURATION AND ENVIRONMENT

The language follows C<LC_ALL>, C<LC_MESSAGES> or C<LANG>.

=head1 DEPENDENCIES

L<Const::Fast>, L<Mojo::Base>, L<GPForum::Command::Support::ServiceEnvironment>,
L<GPForum::Config::Report>, L<GPForum::Service::I18N::CliCatalog>.

=head1 INCOMPATIBILITIES

None known.

=head1 BUGS AND LIMITATIONS

The commands' C<--help> texts are English.

=head1 AUTHOR

Giacomo Picchiarelli.

=head1 LICENSE AND COPYRIGHT

Copyright (c) 2026 Giacomo Picchiarelli. Released under the BSD-3-Clause
license.

=cut
