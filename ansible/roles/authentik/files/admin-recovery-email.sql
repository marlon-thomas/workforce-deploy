-- ADR-0026 (Workforce): keep the emergency administrator's Workforce login when its authentik
-- email changes. Run by psql inside the app's database container, BEFORE authentik is changed,
-- with -v issuer=… -v old=<admin's email in authentik now> -v new=<ADMIN_RECOVERY_EMAIL> -v detail=….
--
-- The Workforce provider signs people in with their email as the subject (sub_mode user_email),
-- so a new email is a new subject: without this, the Administrator's next sign-in would make a
-- fresh login with no access and be refused. The login keeps its id, access and history; only the
-- subject and email cache move, audited in the same transaction. Idempotent: once moved, nothing
-- matches. On a fresh install the app's schema is not there yet, and nothing is done.
-- Prints one marker line: NO_APP_SCHEMA | RECOVERY_EMAIL_TAKEN | MOVED <n>.
\set ON_ERROR_STOP on
SELECT to_regclass('public.app_user') IS NOT NULL AS has_app \gset
\if :has_app
  -- Someone else already signs in with the address: it cannot also be the Administrator's. (The
  -- emergency account itself, already moved by an earlier run that stopped before authentik was
  -- changed, is not "someone else": the run carries on and completes the change.)
  SELECT EXISTS (SELECT 1 FROM app_user
                  WHERE rtrim(oidc_issuer, '/') = rtrim(:'issuer', '/')
                    AND lower(oidc_subject) = lower(:'new')
                    AND lower(oidc_subject) <> lower(:'old')
                    AND NOT is_system_account) AS taken \gset
  \if :taken
    \echo RECOVERY_EMAIL_TAKEN
  \else
    BEGIN;
    WITH moved AS (
        UPDATE app_user u
           SET oidc_subject = :'new', email = :'new', updated_at = now(),
               is_system_account = u.is_system_account
                   OR NOT EXISTS (SELECT 1 FROM employee e WHERE e.app_user_id = u.id)
         WHERE rtrim(u.oidc_issuer, '/') = rtrim(:'issuer', '/')
           AND lower(u.oidc_subject) IN (lower(:'old'), lower(:'new'))
           AND (u.oidc_subject <> :'new' OR coalesce(u.email, '') <> :'new'
                OR (NOT u.is_system_account
                    AND NOT EXISTS (SELECT 1 FROM employee e WHERE e.app_user_id = u.id)))
        RETURNING u.id
    )
    INSERT INTO audit_event (organisation_id, actor_subject, action, resource_type, resource_id, outcome, diff)
    SELECT (SELECT g.organisation_id FROM user_access_grant g WHERE g.app_user_id = moved.id
             ORDER BY g.effective_from LIMIT 1),
           'system:deploy-identity', 'EMERGENCY_ADMIN_RECOVERY_EMAIL_SET', 'app_user', moved.id::text, 'SUCCESS',
           jsonb_build_object('detail', :'detail')
      FROM moved;
    SELECT count(*) AS n FROM audit_event
     WHERE actor_subject = 'system:deploy-identity' AND action = 'EMERGENCY_ADMIN_RECOVERY_EMAIL_SET'
       AND occurred_at >= now() \gset
    COMMIT;
    \echo MOVED :n
  \endif
\else
  \echo NO_APP_SCHEMA
\endif
