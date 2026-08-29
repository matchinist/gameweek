SET local check_function_bodies = off;

-- hypopg / index_advisor are Supabase dashboard tooling (the index advisor),
-- not application schema. They exist on live, but a replay target (plain
-- Postgres in CI / the replay test) may not ship them — skip gracefully there.
DO $$ BEGIN
  CREATE EXTENSION IF NOT EXISTS "hypopg" SCHEMA "extensions";
  CREATE EXTENSION IF NOT EXISTS "index_advisor" SCHEMA "extensions";
EXCEPTION WHEN OTHERS THEN
  RAISE NOTICE 'index-advisor extensions unavailable on this host - skipped (dashboard tooling, not app schema)';
END $$;

CREATE TABLE "public"."gw_admins" (
  "id"         uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "auth_id"    uuid,
  "email"      text,
  "name"       text,
  "created_at" timestamp with time zone DEFAULT now(),
  CONSTRAINT "gw_admins_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_admins"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_campaigns" (
  "id"          text                     NOT NULL,
  "client_key"  text                     NOT NULL,
  "type"        text                     NOT NULL DEFAULT 'widget_sponsorship'::text,
  "brand_name"  text                     NOT NULL,
  "logo_url"    text,
  "widget_keys" text[]                   NOT NULL DEFAULT '{}'::text[],
  "status"      text                     NOT NULL DEFAULT 'active'::text,
  "created_at"  timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "gw_campaigns_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_campaigns"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_client_coverage" (
  "client_key"     text                     NOT NULL,
  "tournament_ids" jsonb                    DEFAULT '[]'::jsonb,
  "team_ids"       jsonb                    DEFAULT '[]'::jsonb,
  "updated_at"     timestamp with time zone DEFAULT now(),
  CONSTRAINT "gw_client_coverage_pkey" PRIMARY KEY (client_key)
);

ALTER TABLE "public"."gw_client_coverage"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_competitions" (
  "id"              text                     NOT NULL,
  "client_key"      text                     NOT NULL,
  "name"            text                     NOT NULL,
  "mode"            text                     NOT NULL,
  "color"           text                     DEFAULT '#4F46E5'::text,
  "status"          text                     DEFAULT 'draft'::text,
  "long_term"       boolean                  DEFAULT false,
  "scoring"         jsonb,
  "markets"         jsonb,
  "users"           integer                  DEFAULT 0,
  "predictions"     integer                  DEFAULT 0,
  "created_at"      timestamp with time zone DEFAULT now(),
  "ranking_config"  jsonb,
  "overall_prizes"  jsonb,
  "lineup_config"   jsonb,
  "roulette_config" jsonb,
  "comp_aliases"    text[]                   DEFAULT '{}'::text[],
  "scope_text"      text,
  "sport"           text,
  CONSTRAINT "gw_competitions_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_competitions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_dm_events" (
  "id"         text             NOT NULL,
  "client_key" text,
  "home_id"    text             NOT NULL,
  "away_id"    text             NOT NULL,
  "kickoff"    text             DEFAULT ''::text,
  "result"     jsonb,
  "status"     text             DEFAULT 'upcoming'::text,
  "line"       double precision DEFAULT 2.5,
  "lineup"     jsonb,
  "scorers"    jsonb,
  CONSTRAINT "gw_dm_events_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_dm_events"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_dm_players" (
  "id"            text                     NOT NULL DEFAULT ('pl_'::text || substr(md5((random())::text), 1, 8)),
  "team_id"       text,
  "full_name"     text                     NOT NULL,
  "birthday"      date,
  "nationality"   text,
  "photo_url"     text,
  "created_at"    timestamp with time zone DEFAULT now(),
  "jersey_number" integer,
  "position"      text,
  "total_games"   integer,
  "height_cm"     smallint,
  CONSTRAINT "gw_dm_players_pkey" PRIMARY KEY (id),
  CONSTRAINT "height_cm_range" CHECK (((height_cm IS NULL) OR ((height_cm >= 100) AND (height_cm <= 230))))
);

ALTER TABLE "public"."gw_dm_players"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_dm_teams" (
  "id"         text     NOT NULL,
  "client_key" text,
  "name"       text     NOT NULL,
  "short"      text     NOT NULL,
  "color"      text     DEFAULT '#4F46E5'::text,
  "logo"       text     DEFAULT ''::text,
  "sport"      text     DEFAULT 'football'::text,
  "fd_home"    smallint,
  "fd_away"    smallint,
  CONSTRAINT "fd_away_range" CHECK (((fd_away IS NULL) OR ((fd_away >= 1) AND (fd_away <= 5)))),
  CONSTRAINT "fd_home_range" CHECK (((fd_home IS NULL) OR ((fd_home >= 1) AND (fd_home <= 5)))),
  CONSTRAINT "gw_dm_teams_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_dm_teams"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_dm_tournaments" (
  "id"               text  NOT NULL,
  "client_key"       text,
  "name"             text  NOT NULL,
  "country"          text  DEFAULT ''::text,
  "type"             text  DEFAULT 'league'::text,
  "color"            text  DEFAULT '#4F46E5'::text,
  "seasons"          jsonb DEFAULT '{}'::jsonb,
  "restricted_email" text,
  "sport"            text  DEFAULT 'football'::text,
  CONSTRAINT "gw_dm_tournaments_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_dm_tournaments"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_league_members" (
  "league_id" text                     NOT NULL,
  "username"  text                     NOT NULL,
  "joined_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "gw_league_members_pkey" PRIMARY KEY (league_id, username)
);

ALTER TABLE "public"."gw_league_members"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_leagues" (
  "id"         text                     NOT NULL,
  "client_key" text                     NOT NULL,
  "name"       text                     NOT NULL,
  "code"       text                     NOT NULL,
  "created_by" text,
  "created_at" timestamp with time zone NOT NULL DEFAULT now(),
  CONSTRAINT "gw_leagues_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_leagues"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_operators" (
  "id"                     uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "email"                  text                     NOT NULL,
  "company_name"           text                     NOT NULL,
  "client_key"             text                     NOT NULL,
  "plan"                   text,
  "created_at"             timestamp with time zone DEFAULT now(),
  "auth_id"                uuid,
  "username"               text,
  "is_admin"               boolean                  DEFAULT false,
  "stripe_customer_id"     text,
  "stripe_subscription_id" text,
  "logo_url"               text,
  "domains"                jsonb                    DEFAULT '[]'::jsonb,
  "subscription_required"  boolean                  DEFAULT true,
  "language"               text                     DEFAULT 'en'::text,
  "accent_color"           text,
  "bg_color"               text,
  "surface_color"          text,
  "text_color"             text,
  "sso_enabled"            boolean                  NOT NULL DEFAULT false,
  "sso_secret"             text,
  CONSTRAINT "gw_operators_client_key_key" UNIQUE (client_key),
  CONSTRAINT "gw_operators_email_key" UNIQUE (email),
  CONSTRAINT "gw_operators_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_operators"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_players" (
  "id"         uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "client_key" text                     NOT NULL,
  "username"   text                     NOT NULL,
  "email"      text                     NOT NULL,
  "joined_at"  timestamp with time zone DEFAULT now(),
  "auth_id"    uuid,
  CONSTRAINT "gw_players_pkey" PRIMARY KEY (id),
  CONSTRAINT "gw_players_unique_username" UNIQUE (client_key, username),
  CONSTRAINT "gw_players_username_format" CHECK ((username ~ '^[A-Za-z0-9_]{1,24}$'::text))
);

ALTER TABLE "public"."gw_players"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_predictions" (
  "id"             uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "client_key"     text                     NOT NULL,
  "player_id"      uuid                     NOT NULL,
  "username"       text                     NOT NULL,
  "competition_id" text                     NOT NULL,
  "round_id"       text                     NOT NULL,
  "event_id"       text                     NOT NULL,
  "prediction"     jsonb                    NOT NULL,
  "submitted_at"   timestamp with time zone DEFAULT now(),
  CONSTRAINT "gw_predictions_pkey" PRIMARY KEY (id),
  CONSTRAINT "gw_predictions_player_comp_event_unique" UNIQUE (player_id, competition_id, event_id)
);

ALTER TABLE "public"."gw_predictions"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_rounds" (
  "id"               text                     NOT NULL,
  "competition_id"   text                     NOT NULL,
  "client_key"       text                     NOT NULL,
  "label"            text                     NOT NULL,
  "status"           text                     DEFAULT 'open'::text,
  "deadline"         text                     DEFAULT ''::text,
  "event_ids"        text[]                   DEFAULT '{}'::text[],
  "tournament_ids"   text[]                   DEFAULT '{}'::text[],
  "tournament_names" text[]                   DEFAULT '{}'::text[],
  "sort_order"       integer                  DEFAULT 0,
  "created_at"       timestamp with time zone DEFAULT now(),
  "ranking_teams"    jsonb,
  "prizes"           jsonb,
  CONSTRAINT "gw_rounds_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_rounds"
  ENABLE ROW LEVEL SECURITY;

CREATE TABLE "public"."gw_subscriptions" (
  "id"                     uuid                     NOT NULL DEFAULT gen_random_uuid(),
  "client_key"             text                     NOT NULL,
  "plan"                   text                     NOT NULL DEFAULT 'free'::text,
  "flat_fee"               numeric                  NOT NULL DEFAULT 50.00,
  "included_mau"           integer                  NOT NULL DEFAULT 100,
  "price_per_mau"          numeric                  NOT NULL DEFAULT 0.10,
  "billing_email"          text,
  "stripe_customer_id"     text,
  "stripe_subscription_id" text,
  "current_period_start"   date                     DEFAULT CURRENT_DATE,
  "current_period_end"     date                     DEFAULT (CURRENT_DATE + '1 mon'::interval),
  "created_at"             timestamp with time zone DEFAULT now(),
  "updated_at"             timestamp with time zone DEFAULT now(),
  CONSTRAINT "gw_subscriptions_client_key_key" UNIQUE (client_key),
  CONSTRAINT "gw_subscriptions_pkey" PRIMARY KEY (id)
);

ALTER TABLE "public"."gw_subscriptions"
  ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.resolve_question (
  q_id           uuid,
  correct_opt_id uuid
)
  RETURNS void
  LANGUAGE plpgsql
  SECURITY DEFINER
  AS $function$
DECLARE
  opt_odds NUMERIC;
BEGIN
  SELECT odds INTO opt_odds FROM question_options WHERE id = correct_opt_id;
  UPDATE questions
  SET correct_option = correct_opt_id::TEXT, is_resolved = TRUE
  WHERE id = q_id;
  UPDATE predictions
  SET points_result = CASE
    WHEN selected_option::UUID = correct_opt_id THEN ROUND(stake * opt_odds) - stake
    ELSE -stake
  END
  WHERE question_id = q_id;
  UPDATE profiles p
  SET total_points = total_points + pr.points_result
  FROM predictions pr
  WHERE pr.question_id = q_id AND pr.user_id = p.id;
END;
$function$;

CREATE OR REPLACE FUNCTION public.rls_auto_enable()
  RETURNS event_trigger
  LANGUAGE plpgsql
  SECURITY DEFINER
  SET search_path TO 'pg_catalog'
  AS $function$
DECLARE
  cmd record;
BEGIN
  FOR cmd IN
    SELECT *
    FROM pg_event_trigger_ddl_commands()
    WHERE command_tag IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
      AND object_type IN ('table','partitioned table')
  LOOP
     IF cmd.schema_name IS NOT NULL AND cmd.schema_name IN ('public') AND cmd.schema_name NOT IN ('pg_catalog','information_schema') AND cmd.schema_name NOT LIKE 'pg_toast%' AND cmd.schema_name NOT LIKE 'pg_temp%' THEN
      BEGIN
        EXECUTE format('alter table if exists %s enable row level security', cmd.object_identity);
        RAISE LOG 'rls_auto_enable: enabled RLS on %', cmd.object_identity;
      EXCEPTION
        WHEN OTHERS THEN
          RAISE LOG 'rls_auto_enable: failed to enable RLS on %', cmd.object_identity;
      END;
     ELSE
        RAISE LOG 'rls_auto_enable: skip % (either system schema or not in enforced list: %.)', cmd.object_identity, cmd.schema_name;
     END IF;
  END LOOP;
END;
$function$;

ALTER TABLE "public"."gw_admins"
  ADD CONSTRAINT "gw_admins_auth_id_fkey" FOREIGN KEY (auth_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."gw_dm_players"
  ADD CONSTRAINT "gw_dm_players_team_id_fkey" FOREIGN KEY (team_id) REFERENCES public.gw_dm_teams(id) ON DELETE CASCADE;

ALTER TABLE "public"."gw_league_members"
  ADD CONSTRAINT "gw_league_members_league_id_fkey" FOREIGN KEY (league_id) REFERENCES public.gw_leagues(id) ON DELETE CASCADE;

ALTER TABLE "public"."gw_operators"
  ADD CONSTRAINT "gw_operators_auth_id_fkey" FOREIGN KEY (auth_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."gw_players"
  ADD CONSTRAINT "gw_players_auth_id_fkey" FOREIGN KEY (auth_id) REFERENCES auth.users(id) ON DELETE CASCADE;

ALTER TABLE "public"."gw_predictions"
  ADD CONSTRAINT "gw_predictions_player_id_fkey" FOREIGN KEY (player_id) REFERENCES public.gw_players(id) ON DELETE CASCADE;

ALTER TABLE "public"."gw_rounds"
  ADD CONSTRAINT "gw_rounds_competition_id_fkey" FOREIGN KEY (competition_id) REFERENCES public.gw_competitions(id) ON DELETE CASCADE;

ALTER TABLE "public"."gw_subscriptions"
  ADD CONSTRAINT "gw_subscriptions_client_key_fkey" FOREIGN KEY (client_key) REFERENCES public.gw_operators(client_key) ON DELETE CASCADE;

CREATE VIEW "public"."gw_mau_current" AS  SELECT client_key,
    count(DISTINCT player_id) AS mau_count,
    date_trunc('month'::text, now()) AS period_start
   FROM public.gw_predictions p
  WHERE (date_trunc('month'::text, submitted_at) = date_trunc('month'::text, now()))
  GROUP BY client_key;

CREATE VIEW "public"."gw_billing_current" AS  SELECT s.client_key,
    s.plan,
    s.flat_fee,
    s.included_mau,
    s.price_per_mau,
    COALESCE(m.mau_count, (0)::bigint) AS mau_count,
    GREATEST((0)::bigint, (COALESCE(m.mau_count, (0)::bigint) - s.included_mau)) AS billable_mau,
    (s.flat_fee + ((COALESCE(m.mau_count, (0)::bigint))::numeric * s.price_per_mau)) AS total_due
   FROM (public.gw_subscriptions s
     LEFT JOIN public.gw_mau_current m ON ((m.client_key = s.client_key)));

CREATE VIEW "public"."gw_operators_public" WITH (security_invoker=false) AS  SELECT client_key,
    company_name,
    logo_url,
    language,
    accent_color,
    bg_color,
    surface_color,
    text_color,
    domains
   FROM public.gw_operators;

CREATE INDEX gw_competitions_client_idx ON public.gw_competitions USING btree (client_key);

CREATE INDEX gw_dm_events_client_idx ON public.gw_dm_events USING btree (client_key);

CREATE INDEX gw_dm_teams_client_idx ON public.gw_dm_teams USING btree (client_key);

CREATE INDEX gw_dm_tournaments_client_idx ON public.gw_dm_tournaments USING btree (client_key);

CREATE UNIQUE INDEX gw_league_members_league_username_key ON public.gw_league_members USING btree (league_id, username);

CREATE INDEX gw_operators_auth_id_idx ON public.gw_operators USING btree (auth_id);

CREATE INDEX gw_players_auth_id_idx ON public.gw_players USING btree (auth_id);

CREATE INDEX gw_players_client_key_idx ON public.gw_players USING btree (client_key);

CREATE UNIQUE INDEX gw_players_client_username_uidx ON public.gw_players USING btree (client_key, username);

CREATE INDEX gw_predictions_client_round_idx ON public.gw_predictions USING btree (client_key, round_id);

CREATE INDEX gw_predictions_comp_idx ON public.gw_predictions USING btree (client_key, competition_id);

CREATE INDEX gw_predictions_player_idx ON public.gw_predictions USING btree (player_id);

CREATE INDEX gw_rounds_client_idx ON public.gw_rounds USING btree (client_key);

CREATE INDEX gw_rounds_comp_idx ON public.gw_rounds USING btree (competition_id);

CREATE INDEX idx_gw_campaigns_client ON public.gw_campaigns USING btree (client_key);

CREATE INDEX idx_gw_league_members_username ON public.gw_league_members USING btree (username);

CREATE INDEX idx_gw_leagues_client ON public.gw_leagues USING btree (client_key);

CREATE UNIQUE INDEX idx_gw_leagues_code ON public.gw_leagues USING btree (client_key, code);

CREATE POLICY "admins_read_own" ON "public"."gw_admins"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "campaigns_read" ON "public"."gw_campaigns"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "campaigns_write_own" ON "public"."gw_campaigns"
  FOR ALL
  TO PUBLIC
  USING ((auth.uid() = ( SELECT gw_operators.auth_id
   FROM public.gw_operators
  WHERE (gw_operators.client_key = gw_campaigns.client_key)
 LIMIT 1)));

CREATE POLICY "coverage_admin_all" ON "public"."gw_client_coverage"
  FOR ALL
  TO PUBLIC
  USING ((EXISTS ( SELECT 1
   FROM public.gw_admins
  WHERE (gw_admins.auth_id = auth.uid()))));

CREATE POLICY "coverage_own_read" ON "public"."gw_client_coverage"
  FOR SELECT
  TO PUBLIC
  USING ((client_key = ( SELECT gw_operators.client_key
   FROM public.gw_operators
  WHERE (gw_operators.auth_id = auth.uid()))));

CREATE POLICY "comps_read" ON "public"."gw_competitions"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "comps_write_own" ON "public"."gw_competitions"
  FOR ALL
  TO PUBLIC
  USING ((auth.uid() = ( SELECT gw_operators.auth_id
   FROM public.gw_operators
  WHERE (gw_operators.client_key = gw_competitions.client_key)
 LIMIT 1)));

CREATE POLICY "dm_events_read" ON "public"."gw_dm_events"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "dm_events_write" ON "public"."gw_dm_events"
  FOR ALL
  TO PUBLIC
  USING ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))));

CREATE POLICY "dm_players_read" ON "public"."gw_dm_players"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "dm_players_write" ON "public"."gw_dm_players"
  FOR ALL
  TO PUBLIC
  USING ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))));

CREATE POLICY "dm_teams_read" ON "public"."gw_dm_teams"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "dm_teams_write" ON "public"."gw_dm_teams"
  FOR ALL
  TO PUBLIC
  USING ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))));

CREATE POLICY "dm_tournaments_read" ON "public"."gw_dm_tournaments"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "dm_tournaments_write" ON "public"."gw_dm_tournaments"
  FOR ALL
  TO PUBLIC
  USING ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))));

CREATE POLICY "league_members_delete_self" ON "public"."gw_league_members"
  FOR DELETE
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM (public.gw_leagues l
     JOIN public.gw_players p ON ((p.client_key = l.client_key)))
  WHERE ((l.id = gw_league_members.league_id) AND (p.auth_id = auth.uid()) AND (p.username = gw_league_members.username)))));

CREATE POLICY "league_members_insert_self" ON "public"."gw_league_members"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((EXISTS ( SELECT 1
   FROM (public.gw_leagues l
     JOIN public.gw_players p ON ((p.client_key = l.client_key)))
  WHERE ((l.id = gw_league_members.league_id) AND (p.auth_id = auth.uid()) AND (p.username = gw_league_members.username)))));

CREATE POLICY "league_members_read" ON "public"."gw_league_members"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM (public.gw_leagues l
     JOIN public.gw_players p ON ((p.client_key = l.client_key)))
  WHERE ((l.id = gw_league_members.league_id) AND (p.auth_id = auth.uid())))));

CREATE POLICY "leagues_insert_self" ON "public"."gw_leagues"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((EXISTS ( SELECT 1
   FROM public.gw_players p
  WHERE ((p.auth_id = auth.uid()) AND (p.client_key = gw_leagues.client_key) AND (p.username = gw_leagues.created_by)))));

CREATE POLICY "leagues_read" ON "public"."gw_leagues"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM public.gw_players p
  WHERE ((p.auth_id = auth.uid()) AND (p.client_key = gw_leagues.client_key)))));

CREATE POLICY "operators_insert" ON "public"."gw_operators"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((auth.uid() = auth_id));

CREATE POLICY "operators_read_admin" ON "public"."gw_operators"
  FOR SELECT
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))));

CREATE POLICY "operators_read_own" ON "public"."gw_operators"
  FOR SELECT
  TO "authenticated"
  USING ((auth.uid() = auth_id));

CREATE POLICY "operators_update_admin" ON "public"."gw_operators"
  FOR UPDATE
  TO "authenticated"
  USING ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))))
  WITH CHECK ((EXISTS ( SELECT 1
   FROM public.gw_admins a
  WHERE (a.auth_id = auth.uid()))));

CREATE POLICY "operators_update_own" ON "public"."gw_operators"
  FOR UPDATE
  TO "authenticated"
  USING ((auth.uid() = auth_id))
  WITH CHECK ((auth.uid() = auth_id));

CREATE POLICY "players_insert" ON "public"."gw_players"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((auth.uid() = auth_id));

CREATE POLICY "players_read_operator" ON "public"."gw_players"
  FOR SELECT
  TO "authenticated"
  USING ((client_key IN ( SELECT gw_operators.client_key
   FROM public.gw_operators
  WHERE (gw_operators.auth_id = auth.uid()))));

CREATE POLICY "players_read_own" ON "public"."gw_players"
  FOR SELECT
  TO "authenticated"
  USING ((auth.uid() = auth_id));

CREATE POLICY "players_update_own" ON "public"."gw_players"
  FOR UPDATE
  TO "authenticated"
  USING ((auth.uid() = auth_id))
  WITH CHECK ((auth.uid() = auth_id));

CREATE POLICY "predictions_read" ON "public"."gw_predictions"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "predictions_update_own" ON "public"."gw_predictions"
  FOR UPDATE
  TO PUBLIC
  USING ((auth.uid() = ( SELECT gw_players.auth_id
   FROM public.gw_players
  WHERE (gw_players.id = gw_predictions.player_id)
 LIMIT 1)));

CREATE POLICY "predictions_write_own" ON "public"."gw_predictions"
  FOR INSERT
  TO PUBLIC
  WITH CHECK ((auth.uid() = ( SELECT gw_players.auth_id
   FROM public.gw_players
  WHERE (gw_players.id = gw_predictions.player_id)
 LIMIT 1)));

CREATE POLICY "rounds_read" ON "public"."gw_rounds"
  FOR SELECT
  TO PUBLIC
  USING (true);

CREATE POLICY "rounds_write_own" ON "public"."gw_rounds"
  FOR ALL
  TO PUBLIC
  USING ((auth.uid() = ( SELECT gw_operators.auth_id
   FROM public.gw_operators
  WHERE (gw_operators.client_key = gw_rounds.client_key)
 LIMIT 1)));

CREATE POLICY "subscriptions_read_own" ON "public"."gw_subscriptions"
  FOR SELECT
  TO PUBLIC
  USING ((auth.uid() = ( SELECT gw_operators.auth_id
   FROM public.gw_operators
  WHERE (gw_operators.client_key = gw_subscriptions.client_key)
 LIMIT 1)));

CREATE POLICY "Allow authenticated uploads to player-photos" ON "storage"."objects"
  FOR INSERT
  TO "authenticated"
  WITH CHECK ((bucket_id = 'player-photos'::text));

CREATE POLICY "Allow public read of player-photos" ON "storage"."objects"
  FOR SELECT
  TO PUBLIC
  USING ((bucket_id = 'player-photos'::text));

CREATE EVENT TRIGGER "ensure_rls"
  ON ddl_command_end
  WHEN TAG IN ('CREATE TABLE', 'CREATE TABLE AS', 'SELECT INTO')
  EXECUTE FUNCTION "public"."rls_auto_enable"();

COMMENT ON COLUMN "public"."gw_operators"."sso_enabled" IS 'Host-page SSO: when true, the sso-login Edge Function accepts signed identities for this client_key.';

COMMENT ON COLUMN "public"."gw_operators"."sso_secret" IS 'HMAC-SHA256 key the operator''s site signs SSO identities with (hex sig over "id:email"). Never exposed to anon — see gw_operators_public.';

-- Guarded like their CREATE at the top of this file: the extensions may have
-- been skipped on a replay target that does not ship them.
DO $$ BEGIN
  COMMENT ON EXTENSION "hypopg" IS 'Hypothetical indexes for PostgreSQL';
  COMMENT ON EXTENSION "index_advisor" IS 'Query index advisor';
EXCEPTION WHEN OTHERS THEN NULL;
END $$;

GRANT EXECUTE ON FUNCTION "public"."resolve_question"(uuid, uuid) TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT EXECUTE ON FUNCTION "public"."rls_auto_enable"() TO PUBLIC, "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_admins" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_campaigns" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_client_coverage" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_competitions" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_dm_events" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_dm_players" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_dm_teams" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_dm_tournaments" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_league_members" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_leagues" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_operators" TO "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_players" TO "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_predictions" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_rounds" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_subscriptions" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_billing_current" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_mau_current" TO "anon", "authenticated", "postgres", "service_role";

GRANT DELETE, INSERT, MAINTAIN, REFERENCES, SELECT, TRIGGER, TRUNCATE, UPDATE ON TABLE "public"."gw_operators_public" TO "anon", "authenticated", "postgres", "service_role";

