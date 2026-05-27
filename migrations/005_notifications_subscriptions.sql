BEGIN;

CREATE TABLE IF NOT EXISTS subscriptions(
    subscription_id uuid NOT NULL,
    user_id uuid NOT NULL,
    target_type text NOT NULL,
    target_id uuid NOT NULL,
    preference text NOT NULL DEFAULT 'all',
    created_at timestamptz NOT NULL DEFAULT now(),
    muted_at timestamptz,
    revoked_at timestamptz,
    CONSTRAINT subscriptions_pkey PRIMARY KEY(subscription_id),
    CONSTRAINT subscriptions_user_id_fkey FOREIGN KEY(user_id)
      REFERENCES users(id),
    CONSTRAINT subscriptions_preference_check
      CHECK( preference IN( 'all', 'mentions', 'none' ) ),
    CONSTRAINT subscriptions_unique_target UNIQUE( user_id, target_type,
        target_id ),
    CONSTRAINT subscriptions_muted_after_created_check
      CHECK( muted_at IS NULL OR muted_at >= created_at ),
    CONSTRAINT subscriptions_revoked_after_created_check
      CHECK( revoked_at IS NULL OR revoked_at >= created_at )
);

CREATE INDEX IF NOT EXISTS idx_subscriptions_target_active ON subscriptions(
    target_type, target_id, preference ) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS notification_preferences(
    user_id uuid NOT NULL,
    channel text NOT NULL,
    enabled boolean NOT NULL DEFAULT true,
    digest_frequency text NOT NULL DEFAULT 'daily',
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT notification_preferences_pkey PRIMARY KEY( user_id, channel ),
    CONSTRAINT notification_preferences_user_id_fkey FOREIGN KEY(user_id)
      REFERENCES users(id),
    CONSTRAINT notification_preferences_channel_check
      CHECK( channel IN( 'in_app', 'email', 'digest' ) ),
    CONSTRAINT notification_preferences_digest_check
      CHECK( digest_frequency IN( 'immediate', 'daily', 'weekly', 'never' ) )
);

CREATE INDEX IF NOT EXISTS idx_notification_preferences_enabled ON
  notification_preferences( channel, enabled );

COMMIT;
