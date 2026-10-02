-- ============================================================================
-- Inflora MVP Schema
-- ============================================================================
-- Engine: PostgreSQL 15+
-- Currency: IDR only. amount_idr is BIGINT (no decimals).
-- Money: append-only ledger. Never UPDATE/DELETE ledger_entries.
-- Schema ownership: saruman owns streamer/ledger tables; palantir owns
--   gateway_* tables; tolkien extends users table; ithildin reads only.
-- ============================================================================

CREATE EXTENSION IF NOT EXISTS "pgcrypto";  -- gen_random_uuid()

-- ============================================================================
-- ENUMS
-- ============================================================================

CREATE TYPE ledger_direction AS ENUM ('DEBIT', 'CREDIT');

CREATE TYPE ledger_entry_type AS ENUM (
  'DONATION_DEPOSIT',         -- donor pays in (increases donor_cash)
  'STREAMER_PENDING_CREDIT',  -- streamer gets pending balance
  'PLATFORM_FEE',             -- platform fee from donation
  'STREAMER_PAID_DEBIT',      -- money leaves streamer_paid on payout
  'REFUND_DEBIT',             -- refund reverses donation
  'REFUND_CREDIT'             -- refund returns donor money
);

CREATE TYPE ledger_account_type AS ENUM (
  'DONOR_CASH',                -- tracks donor-side money (for refund reconcile)
  'STREAMER_PENDING',          -- streamer balance awaiting payout
  'STREAMER_PAID',             -- money already paid out
  'PLATFORM_REVENUE'           -- platform's collected fees
);

CREATE TYPE donation_status AS ENUM (
  'INTENT_CREATED',
  'CHARGED',
  'FAILED',
  'REFUNDED'
);

CREATE TYPE payout_status AS ENUM (
  'REQUESTED',
  'PROCESSING',
  'SETTLED',
  'FAILED'
);

CREATE TYPE token_purpose AS ENUM (
  'SESSION',        -- dashboard login
  'OVERLAY'         -- OBS browser source
);

CREATE TYPE fraud_rule AS ENUM (
  'VEL_CARD_DONATIONS_PER_MIN',
  'VEL_CARD_DONATIONS_PER_DAY',
  'BLOCKED_CARD',
  'BLOCKED_IP'
);

CREATE TYPE fraud_action AS ENUM (
  'BLOCKED',
  'ALLOWED_BUT_FLAGGED'
);

-- ============================================================================
-- streamers  (saruman owns)
-- ============================================================================

CREATE TABLE streamers (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  email           VARCHAR(320) NOT NULL UNIQUE,
  display_name    VARCHAR(80) NOT NULL,
  password_hash   VARCHAR(255) NOT NULL,            -- argon2id
  is_active       BOOLEAN NOT NULL DEFAULT TRUE,
  is_verified     BOOLEAN NOT NULL DEFAULT FALSE,   -- manual KYC at MVP
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  last_login_at   TIMESTAMPTZ
);

CREATE INDEX idx_streamers_active ON streamers (is_active) WHERE is_active = TRUE;
CREATE INDEX idx_streamers_email ON streamers (lower(email));

-- ============================================================================
-- sessions  (saruman owns; tolkien writes)
-- ============================================================================
-- token_hash = bcrypt(token, cost=12)
-- last4 shown in UI for sanity without bcrypt roundtrip

CREATE TABLE sessions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  streamer_id     UUID NOT NULL REFERENCES streamers(id) ON DELETE CASCADE,
  token_hash      VARCHAR(255) NOT NULL,
  last4           CHAR(4) NOT NULL,
  purpose         token_purpose NOT NULL,
  expires_at      TIMESTAMPTZ NOT NULL,
  last_used_at    TIMESTAMPTZ,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  revoked_at      TIMESTAMPTZ,
  CONSTRAINT uq_sessions_token UNIQUE (token_hash)
);

CREATE INDEX idx_sessions_streamer_active
  ON sessions (streamer_id) WHERE revoked_at IS NULL;

CREATE INDEX idx_sessions_purpose_active
  ON sessions (purpose) WHERE revoked_at IS NULL;

CREATE INDEX idx_sessions_expiry
  ON sessions (expires_at) WHERE revoked_at IS NULL;

-- ============================================================================
-- idempotency  (saruman owns)
-- ============================================================================
-- One row per processed webhook. UNIQUE on key = first writer wins.
-- key format: "midtrans:<event_id>", "xendit:<invoice_id>", etc.

CREATE TABLE idempotency (
  key             VARCHAR(128) PRIMARY KEY,
  endpoint        VARCHAR(80) NOT NULL,
  request_hash    CHAR(64) NOT NULL,                  -- sha256 hex of body
  response_status INT,
  response_body   JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at    TIMESTAMPTZ
);

CREATE INDEX idx_idempotency_created ON idempotency (created_at);

-- ============================================================================
-- ledger_accounts  (saruman owns)
-- ============================================================================
-- One row per (streamer, account_type, currency).
-- Tracks running balance; updated atomically with ledger_entries.

CREATE TABLE ledger_accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  streamer_id     UUID NOT NULL REFERENCES streamers(id),
  account_type    ledger_account_type NOT NULL,
  currency        CHAR(3) NOT NULL DEFAULT 'IDR',
  balance_idr     BIGINT NOT NULL DEFAULT 0,         -- minor units
  version         BIGINT NOT NULL DEFAULT 0,         -- optimistic lock
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_ledger_account UNIQUE (streamer_id, account_type, currency)
);

-- Auto-create ledger accounts when streamer registers
-- (handled by application code, not trigger, for clarity)

-- ============================================================================
-- ledger_entries  (saruman owns) -- APPEND-ONLY
-- ============================================================================
-- Every external money movement = 2 entries (DEBIT + CREDIT).
-- Corrections only via reversal entries (entry_type = REFUND_* with reversal_of set).
-- INVARIANT: sum(DEBIT) = sum(CREDIT) per (account_id, currency) at all times.

CREATE TABLE ledger_entries (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  streamer_id     UUID NOT NULL REFERENCES streamers(id),
  account_id      UUID NOT NULL REFERENCES ledger_accounts(id),
  direction       ledger_direction NOT NULL,
  amount_idr      BIGINT NOT NULL CHECK (amount_idr > 0),
  entry_type      ledger_entry_type NOT NULL,
  external_ref    VARCHAR(128),                       -- provider charge_id or payout_id
  donation_id     UUID,                                -- nullable FK (see donations)
  payout_id       UUID,                                -- nullable FK (see payouts)
  reversal_of     UUID REFERENCES ledger_entries(id),  -- non-null for reversal entries
  correlation_id  UUID,                                -- groups entries from same txn
  metadata        JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_ledger_entries_streamer_time
  ON ledger_entries (streamer_id, created_at DESC);

CREATE INDEX idx_ledger_entries_account_time
  ON ledger_entries (account_id, created_at DESC);

CREATE INDEX idx_ledger_entries_external_ref
  ON ledger_entries (external_ref);

CREATE INDEX idx_ledger_entries_correlation
  ON ledger_entries (correlation_id);

CREATE INDEX idx_ledger_entries_donation
  ON ledger_entries (donation_id) WHERE donation_id IS NOT NULL;

CREATE INDEX idx_ledger_entries_payout
  ON ledger_entries (payout_id) WHERE payout_id IS NOT NULL;

-- APPEND-ONLY enforcement (PostgreSQL rule system; or rely on app discipline)
CREATE RULE no_update_ledger_entries AS ON UPDATE TO ledger_entries DO INSTEAD NOTHING;
CREATE RULE no_delete_ledger_entries AS ON DELETE TO ledger_entries DO INSTEAD NOTHING;

-- ============================================================================
-- donations  (saruman owns)
-- ============================================================================

CREATE TABLE donations (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  streamer_id         UUID NOT NULL REFERENCES streamers(id),
  intent_id           UUID NOT NULL UNIQUE,
  status              donation_status NOT NULL DEFAULT 'INTENT_CREATED',
  amount_idr          BIGINT NOT NULL CHECK (amount_idr > 0),
  platform_fee_idr    BIGINT NOT NULL DEFAULT 0 CHECK (platform_fee_idr >= 0),
  net_idr             BIGINT NOT NULL DEFAULT 0 CHECK (net_idr >= 0),
  currency            CHAR(3) NOT NULL DEFAULT 'IDR',
  donor_display_name  VARCHAR(80),
  message             VARCHAR(500),
  is_anonymous        BOOLEAN NOT NULL DEFAULT FALSE,
  provider_charge_id  VARCHAR(128),
  provider_name       VARCHAR(40),                       -- 'midtrans', 'xendit'
  client_ip           INET,
  user_agent          VARCHAR(500),
  failure_reason      VARCHAR(40),
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  charged_at          TIMESTAMPTZ,
  failed_at           TIMESTAMPTZ,
  refunded_at         TIMESTAMPTZ,
  expires_at          TIMESTAMPTZ NOT NULL,              -- intent expiry
  metadata            JSONB
);

CREATE INDEX idx_donations_streamer_status_time
  ON donations (streamer_id, status, created_at DESC);

CREATE INDEX idx_donations_status_expires
  ON donations (status, expires_at) WHERE status = 'INTENT_CREATED';

CREATE INDEX idx_donations_intent ON donations (intent_id);

CREATE INDEX idx_donations_provider_ref
  ON donations (provider_name, provider_charge_id)
  WHERE provider_charge_id IS NOT NULL;

-- ============================================================================
-- refunds  (saruman owns)
-- ============================================================================

CREATE TABLE refunds (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  donation_id         UUID NOT NULL REFERENCES donations(id),
  streamer_id         UUID NOT NULL REFERENCES streamers(id),
  amount_idr          BIGINT NOT NULL CHECK (amount_idr > 0),
  reason              VARCHAR(40) NOT NULL,              -- enum: ADMIN_REFUND, USER_REQUEST, CHARGEBACK
  provider_refund_id  VARCHAR(128),
  initiated_by        UUID,                              -- null = system
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  completed_at        TIMESTAMPTZ,
  metadata            JSONB
);

CREATE INDEX idx_refunds_donation ON refunds (donation_id);
CREATE INDEX idx_refunds_streamer_time ON refunds (streamer_id, created_at DESC);

-- ============================================================================
-- payouts  (saruman owns)
-- ============================================================================

CREATE TABLE payouts (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  streamer_id         UUID NOT NULL REFERENCES streamers(id),
  amount_idr          BIGINT NOT NULL CHECK (amount_idr > 0),
  status              payout_status NOT NULL DEFAULT 'REQUESTED',
  bank_account_id     UUID NOT NULL,                     -- FK to streamer_bank_accounts
  provider_payout_id  VARCHAR(128),
  failure_reason      VARCHAR(80),
  requested_at        TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at        TIMESTAMPTZ,
  settled_at          TIMESTAMPTZ,
  metadata            JSONB
);

CREATE INDEX idx_payouts_streamer_status_time
  ON payouts (streamer_id, status, requested_at DESC);

CREATE INDEX idx_payouts_status_requested
  ON payouts (status) WHERE status IN ('REQUESTED', 'PROCESSING');

-- ============================================================================
-- streamer_bank_accounts  (saruman owns)
-- ============================================================================
-- Only stores last4 + bank_code + palantir_ref. Full account number is
-- stored encrypted in palantir-gateway.

CREATE TABLE streamer_bank_accounts (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  streamer_id     UUID NOT NULL REFERENCES streamers(id),
  bank_code       VARCHAR(10) NOT NULL,                 -- 'BCA', 'MANDIRI', etc.
  account_number_last4 VARCHAR(4) NOT NULL,
  account_name    VARCHAR(120) NOT NULL,
  is_primary      BOOLEAN NOT NULL DEFAULT FALSE,
  is_verified     BOOLEAN NOT NULL DEFAULT FALSE,
  palantir_ref    VARCHAR(128) NOT NULL,                -- encrypted in palantir
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  CONSTRAINT uq_bank_primary
    UNIQUE (streamer_id, is_primary) DEFERRABLE INITIALLY DEFERRED
);

CREATE INDEX idx_bank_accounts_streamer ON streamer_bank_accounts (streamer_id);

-- ============================================================================
-- fraud_events  (saruman owns)
-- ============================================================================

CREATE TABLE fraud_events (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  streamer_id         UUID,                              -- nullable
  rule                fraud_rule NOT NULL,
  donor_fingerprint   VARCHAR(120) NOT NULL,
  count               INT NOT NULL,
  window_seconds      INT NOT NULL,
  action_taken        fraud_action NOT NULL,
  metadata            JSONB,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_fraud_events_time ON fraud_events (created_at DESC);
CREATE INDEX idx_fraud_events_streamer_time ON fraud_events (streamer_id, created_at DESC);

-- ============================================================================
-- audit_log  (saruman owns)
-- ============================================================================

CREATE TABLE audit_log (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  actor_id        UUID,                                  -- streamer_id or NULL for system
  actor_type      VARCHAR(20) NOT NULL,                   -- 'STREAMER', 'ADMIN', 'SYSTEM'
  action          VARCHAR(80) NOT NULL,                   -- 'TOKEN_ROTATE', 'REFUND', 'PAYOUT_REQUEST', etc.
  resource_type   VARCHAR(40) NOT NULL,                   -- 'STREAMER', 'DONATION', 'PAYOUT', etc.
  resource_id     UUID,
  ip_address      INET,
  user_agent      VARCHAR(500),
  metadata        JSONB,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_audit_actor_time ON audit_log (actor_id, created_at DESC);
CREATE INDEX idx_audit_resource_time
  ON audit_log (resource_type, resource_id, created_at DESC);
CREATE INDEX idx_audit_action_time ON audit_log (action, created_at DESC);

-- ============================================================================
-- reconciliation_drift  (saruman owns)
-- ============================================================================
-- Populated by nightly reconciliation job if sum(debits) != sum(credits).

CREATE TABLE reconciliation_drift (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  account_type        ledger_account_type NOT NULL,
  streamer_id         UUID,
  expected_idr        BIGINT NOT NULL,
  actual_idr          BIGINT NOT NULL,
  diff_idr            BIGINT NOT NULL,
  currency            CHAR(3) NOT NULL DEFAULT 'IDR',
  detected_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  resolved_at         TIMESTAMPTZ,
  resolution_note     TEXT
);

CREATE INDEX idx_recon_unresolved
  ON reconciliation_drift (detected_at DESC) WHERE resolved_at IS NULL;

-- ============================================================================
-- gateway_* tables  (palantir-gateway owns)
-- ============================================================================
-- Schema owner = palantir-gateway. Documented here for visibility.

CREATE TABLE gateway_topups (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  palantir_ref        VARCHAR(128) NOT NULL UNIQUE,
  saruman_donation_id UUID NOT NULL,
  streamer_id         UUID NOT NULL,
  amount_idr          BIGINT NOT NULL,
  provider_name       VARCHAR(40) NOT NULL,
  provider_charge_id  VARCHAR(128) NOT NULL,
  status              VARCHAR(20) NOT NULL,              -- 'PENDING', 'SETTLED', 'FAILED'
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  settled_at          TIMESTAMPTZ
);

CREATE TABLE gateway_withdrawals (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  palantir_ref        VARCHAR(128) NOT NULL UNIQUE,
  saruman_payout_id   UUID NOT NULL,
  streamer_id         UUID NOT NULL,
  amount_idr          BIGINT NOT NULL,
  status              VARCHAR(20) NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  settled_at          TIMESTAMPTZ
);

CREATE TABLE gateway_refunds (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  palantir_ref        VARCHAR(128) NOT NULL UNIQUE,
  saruman_refund_id   UUID NOT NULL,
  donation_id         UUID NOT NULL,
  amount_idr          BIGINT NOT NULL,
  status              VARCHAR(20) NOT NULL,
  created_at          TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE webhook_events (
  id                  UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  provider_name       VARCHAR(40) NOT NULL,
  provider_event_id   VARCHAR(128) NOT NULL,
  payload_hash        CHAR(64) NOT NULL,
  payload             JSONB NOT NULL,
  received_at         TIMESTAMPTZ NOT NULL DEFAULT NOW(),
  processed_at        TIMESTAMPTZ,
  CONSTRAINT uq_webhook_event UNIQUE (provider_name, provider_event_id)
);

-- ============================================================================
-- VIEWS
-- ============================================================================

-- Streamer balance (read-only convenience for dashboard)
CREATE VIEW v_streamer_balances AS
SELECT
  s.id AS streamer_id,
  s.display_name,
  s.is_active,
  COALESCE(SUM(CASE WHEN la.account_type = 'STREAMER_PENDING' THEN la.balance_idr ELSE 0 END), 0) AS pending_idr,
  COALESCE(SUM(CASE WHEN la.account_type = 'STREAMER_PAID' THEN la.balance_idr ELSE 0 END), 0) AS paid_idr,
  COALESCE(SUM(CASE WHEN la.account_type = 'PLATFORM_REVENUE' THEN la.balance_idr ELSE 0 END), 0) AS platform_idr
FROM streamers s
LEFT JOIN ledger_accounts la ON la.streamer_id = s.id
GROUP BY s.id, s.display_name, s.is_active;

-- Recent donations per streamer (last 30 days)
CREATE VIEW v_recent_donations AS
SELECT
  d.streamer_id,
  d.id AS donation_id,
  d.amount_idr,
  d.platform_fee_idr,
  d.net_idr,
  d.status,
  d.donor_display_name,
  d.is_anonymous,
  d.message,
  d.created_at,
  d.charged_at
FROM donations d
WHERE d.created_at > NOW() - INTERVAL '30 days'
ORDER BY d.created_at DESC;

-- Donation funnel (for analytics)
CREATE VIEW v_donation_funnel AS
SELECT
  date_trunc('day', created_at) AS day,
  COUNT(*) FILTER (WHERE status = 'INTENT_CREATED') AS intents,
  COUNT(*) FILTER (WHERE status = 'CHARGED') AS charged,
  COUNT(*) FILTER (WHERE status = 'FAILED') AS failed,
  COUNT(*) FILTER (WHERE status = 'REFUNDED') AS refunded,
  SUM(amount_idr) FILTER (WHERE status = 'CHARGED') AS gross_idr,
  SUM(platform_fee_idr) FILTER (WHERE status = 'CHARGED') AS platform_fee_idr
FROM donations
GROUP BY date_trunc('day', created_at)
ORDER BY day DESC;

-- ============================================================================
-- END OF SCHEMA
-- ============================================================================