-- SPDX-FileCopyrightText: 2026 Giacomo Picchiarelli
-- SPDX-License-Identifier: BSD-3-Clause

-- Logins were idempotent commands whose stored answer held the session's
-- bearer token in plain: anyone reading command_log (or a backup) held a
-- live session, and a replay with the same command id and identifier
-- signed in without the password. Logins no longer pass through the command
-- log. This revokes every session whose token was stored there and removes
-- the tokens: those members sign in again.

BEGIN;

UPDATE sessions
   SET revoked_at = now()
 WHERE revoked_at IS NULL
   AND session_id IN (
       SELECT (payload -> 'response' -> 'stored' ->> 'session_id')::uuid
         FROM command_log
        WHERE command_type = 'identity.login'
          AND payload -> 'response' -> 'stored' ? 'session_token'
          AND payload -> 'response' -> 'stored' ->> 'session_id' IS NOT NULL
   );

UPDATE command_log
   SET payload = payload #- '{response,stored,session_token}'
 WHERE command_type = 'identity.login'
   AND payload -> 'response' -> 'stored' ? 'session_token';

COMMIT;
