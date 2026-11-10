#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! docker info >/dev/null 2>&1; then
  echo "Supabase migration tests require a running Docker engine." >&2
  exit 1
fi

container="$(docker run --rm -d -e POSTGRES_PASSWORD=local-test-only postgres:17-alpine)"
trap 'docker rm -f "$container" >/dev/null' EXIT
ready_streak=0
for attempt in {1..60}; do
  if docker exec "$container" pg_isready -U postgres >/dev/null 2>&1; then
    ready_streak=$((ready_streak + 1))
    if [ "$ready_streak" -ge 3 ]; then
      break
    fi
  else
    ready_streak=0
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "The isolated PostgreSQL container did not become ready." >&2
    exit 1
  fi
  sleep 1
done

docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE ROLE anon NOLOGIN;
CREATE ROLE authenticated NOLOGIN INHERIT;
CREATE SCHEMA auth;
CREATE TABLE auth.users (id uuid PRIMARY KEY, email text UNIQUE);
CREATE FUNCTION auth.uid() RETURNS uuid
LANGUAGE sql STABLE
AS $$ SELECT nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
GRANT USAGE ON SCHEMA auth TO authenticated;
GRANT EXECUTE ON FUNCTION auth.uid() TO authenticated;
CREATE SCHEMA storage;
CREATE TABLE storage.buckets (
  id text PRIMARY KEY,
  name text NOT NULL,
  public boolean NOT NULL DEFAULT false,
  file_size_limit bigint,
  allowed_mime_types text[]
);
CREATE TABLE storage.objects (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  bucket_id text NOT NULL REFERENCES storage.buckets(id),
  name text NOT NULL
);
ALTER TABLE storage.objects ENABLE ROW LEVEL SECURITY;
GRANT USAGE ON SCHEMA storage TO authenticated;
SQL

for migration in supabase/migrations/*.sql; do
  docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 < "$migration"
done

docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 <<'SQL'
INSERT INTO auth.users (id, email) VALUES
  ('00000000-0000-4000-8000-000000000001', 'admin@example.com'),
  ('00000000-0000-4000-8000-000000000002', 'editor@example.com'),
  ('00000000-0000-4000-8000-000000000003', 'viewer@example.com'),
  ('00000000-0000-4000-8000-000000000004', 'candidate@example.com');
INSERT INTO public.memberships (user_id, role) VALUES
  ('00000000-0000-4000-8000-000000000001', 'administrator'),
  ('00000000-0000-4000-8000-000000000002', 'editor'),
  ('00000000-0000-4000-8000-000000000003', 'viewer');
INSERT INTO public.works (id, title) VALUES
  ('00000000-0000-4000-8000-000000100000', 'A synthetic work');
INSERT INTO public.editions
  (id, work_id, title, format, isbn13, publication_status, release_date)
VALUES
  ('00000000-0000-4000-8000-000000000010',
   '00000000-0000-4000-8000-000000100000',
   'A synthetic edition', 'paperback', '9780306406157', 'announced', '2030-02');
INSERT INTO public.contributors (id, name) VALUES
  ('00000000-0000-4000-8000-000000200000', 'A. Contributor');
INSERT INTO public.edition_credits (edition_id, contributor_id, credit_role) VALUES
  ('00000000-0000-4000-8000-000000000010',
   '00000000-0000-4000-8000-000000200000', 'author');
INSERT INTO public.categories (id, name) VALUES
  ('00000000-0000-4000-8000-000000300000', 'Fiction');
INSERT INTO public.edition_categories (edition_id, category_id) VALUES
  ('00000000-0000-4000-8000-000000000010',
   '00000000-0000-4000-8000-000000300000');

DO $$
BEGIN
  IF (SELECT public FROM storage.buckets WHERE id = 'book-covers') IS NOT false THEN
    RAISE EXCEPTION 'Cover bucket must remain private.';
  END IF;
  IF (SELECT file_size_limit FROM storage.buckets WHERE id = 'book-covers') <> 10485760
    OR (SELECT allowed_mime_types FROM storage.buckets WHERE id = 'book-covers')
      <> ARRAY['image/jpeg', 'image/png', 'image/webp']::text[] THEN
    RAISE EXCEPTION 'Cover bucket upload limits were not applied.';
  END IF;
  IF NOT public.is_valid_release_date('2030')
    OR NOT public.is_valid_release_date('2030-02')
    OR NOT public.is_valid_release_date('2030-02-28')
    OR public.is_valid_release_date('2030-02-30')
    OR public.is_valid_release_date('2030-13') THEN
    RAISE EXCEPTION 'Release-date precision or validation failed.';
  END IF;
  IF NOT public.is_valid_isbn13('9780306406157')
    OR public.is_valid_isbn13('9780306406158') THEN
    RAISE EXCEPTION 'ISBN-13 checksum validation failed.';
  END IF;
END
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', true);
DO $$
DECLARE
  visible_count integer;
BEGIN
  SELECT count(*) INTO visible_count FROM public.catalog_editions;
  IF visible_count <> 1 OR public.current_catalog_role() <> 'viewer' THEN
    RAISE EXCEPTION 'Approved viewer read or role lookup failed.';
  END IF;
  BEGIN
    PERFORM public.list_catalog_members();
    RAISE EXCEPTION 'Viewer unexpectedly listed memberships.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    UPDATE public.memberships SET role = 'administrator';
    RAISE EXCEPTION 'Viewer unexpectedly changed a membership.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.update_edition_title(
      '00000000-0000-4000-8000-000000000010', 1, 'Viewer write'
    );
    RAISE EXCEPTION 'Viewer unexpectedly updated a title.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.update_edition_metadata(
      '00000000-0000-4000-8000-000000000010', 1,
      'Viewer write', 'paperback', 'en', NULL, 'announced', NULL, '', NULL
    );
    RAISE EXCEPTION 'Viewer unexpectedly updated edition metadata.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.create_work_and_edition(
      'Viewer create', 'paperback', 'en', NULL, 'planned', NULL, ''
    );
    RAISE EXCEPTION 'Viewer unexpectedly created an edition.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    UPDATE public.editions SET title = 'Direct write';
    RAISE EXCEPTION 'Direct table write unexpectedly succeeded.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$$;
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
SELECT public.update_edition_title(
  '00000000-0000-4000-8000-000000000010', 1, 'An edited title'
);
DO $$
DECLARE
  current_record jsonb;
  created_record jsonb;
  audit_count integer;
BEGIN
  SELECT record INTO current_record
  FROM public.catalog_editions
  WHERE id = '00000000-0000-4000-8000-000000000010';
  SELECT count(*) INTO audit_count FROM public.audit_events;
  IF current_record->>'title' <> 'An edited title'
    OR (current_record->>'revision')::integer <> 2
    OR audit_count <> 1 THEN
    RAISE EXCEPTION 'Editor write, revision, or atomic audit failed.';
  END IF;
  BEGIN
    PERFORM public.update_edition_title(
      '00000000-0000-4000-8000-000000000010', 1, 'Stale write'
    );
    RAISE EXCEPTION 'Stale revision unexpectedly succeeded.';
  EXCEPTION WHEN SQLSTATE 'PT409' THEN
    NULL;
  END;
  IF (SELECT count(*) FROM public.audit_events) <> 1 THEN
    RAISE EXCEPTION 'Stale write created a false audit record.';
  END IF;
  INSERT INTO storage.objects (bucket_id, name) VALUES (
    'book-covers',
    '00000000-0000-4000-8000-000000000010/0123456789abcdef0123456789abcdef.webp'
  );
  BEGIN
    PERFORM public.update_edition_metadata(
      '00000000-0000-4000-8000-000000000010', 2,
      'An edited title', 'hardback', 'en', '9780306406157',
      'released', '2030-02-28', 'Updated description',
      '00000000-0000-4000-8000-000000000010/ffffffffffffffffffffffffffffffff.png'
    );
    RAISE EXCEPTION 'Unuploaded cover reference unexpectedly succeeded.';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
  PERFORM public.update_edition_metadata(
    '00000000-0000-4000-8000-000000000010', 2,
    'An edited title', 'hardback', 'en', '9780306406157',
    'released', '2030-02-28', 'Updated description',
    '00000000-0000-4000-8000-000000000010/0123456789abcdef0123456789abcdef.webp'
  );
  BEGIN
    PERFORM public.update_edition_metadata(
      '00000000-0000-4000-8000-000000000010', 3,
      'An edited title', 'hardback', 'en', '9780306406157',
      'released', '2030-02-30', 'Invalid date',
      '00000000-0000-4000-8000-000000000010/0123456789abcdef0123456789abcdef.webp'
    );
    RAISE EXCEPTION 'Invalid full-date metadata unexpectedly succeeded.';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
  SELECT record INTO current_record
  FROM public.catalog_editions
  WHERE id = '00000000-0000-4000-8000-000000000010';
  SELECT count(*) INTO audit_count FROM public.audit_events;
  IF current_record->>'format' <> 'hardback'
    OR current_record->>'publication_status' <> 'released'
    OR current_record->>'release_date' <> '2030-02-28'
    OR current_record->>'description' <> 'Updated description'
    OR current_record->>'cover_key'
      <> '00000000-0000-4000-8000-000000000010/0123456789abcdef0123456789abcdef.webp'
    OR (current_record->>'revision')::integer <> 3
    OR audit_count <> 2 THEN
    RAISE EXCEPTION 'Metadata update, revision, or atomic audit failed.';
  END IF;
  SELECT public.create_work_and_edition(
    'A newly cataloged work', 'ebook', 'en', NULL, 'planned',
    '2032-05', 'A synthetic description.'
  ) INTO created_record;
  SELECT count(*) INTO audit_count FROM public.audit_events;
  IF created_record->>'title' <> 'A newly cataloged work'
    OR created_record->>'format' <> 'ebook'
    OR created_record->>'release_date' <> '2032-05'
    OR (created_record->>'revision')::integer <> 1
    OR audit_count <> 3 THEN
    RAISE EXCEPTION 'Editor create, revision, or initial audit failed.';
  END IF;
  BEGIN
    UPDATE public.audit_events SET after_record = '{}'::jsonb;
    RAISE EXCEPTION 'Audit mutation unexpectedly succeeded.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$$;
COMMIT;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
DO $$
DECLARE
  members jsonb;
  member jsonb;
BEGIN
  members := public.list_catalog_members();
  IF jsonb_array_length(members) <> 3
    OR members->0->>'email' <> 'admin@example.com' THEN
    RAISE EXCEPTION 'Administrator member listing or ordering failed.';
  END IF;
  member := public.add_catalog_member(' CANDIDATE@EXAMPLE.COM ', 'editor');
  IF member->>'email' <> 'candidate@example.com'
    OR member->>'role' <> 'editor'
    OR member->>'active' <> 'true' THEN
    RAISE EXCEPTION 'Administrator could not add a registered account.';
  END IF;
  BEGIN
    PERFORM public.add_catalog_member('candidate@example.com', 'viewer');
    RAISE EXCEPTION 'Duplicate catalog membership unexpectedly succeeded.';
  EXCEPTION WHEN unique_violation THEN
    NULL;
  END;
  BEGIN
    PERFORM public.add_catalog_member('not-registered@example.com', 'viewer');
    RAISE EXCEPTION 'Unregistered account unexpectedly received access.';
  EXCEPTION WHEN no_data_found THEN
    NULL;
  END;
  member := public.update_catalog_member(
    '00000000-0000-4000-8000-000000000004', 'viewer', false
  );
  IF member->>'role' <> 'viewer' OR member->>'active' <> 'false' THEN
    RAISE EXCEPTION 'Administrator could not change role or deactivate a member.';
  END IF;
  BEGIN
    PERFORM public.update_catalog_member(
      '00000000-0000-4000-8000-000000000001', 'editor', true
    );
    RAISE EXCEPTION 'Administrator unexpectedly changed their own role.';
  EXCEPTION WHEN SQLSTATE '22023' THEN
    NULL;
  END;
END
$$;
COMMIT;
DO $$
BEGIN
  IF (SELECT count(*) FROM public.membership_audit_events) <> 2 THEN
    RAISE EXCEPTION 'Membership changes were not audited exactly once.';
  END IF;
END
$$;

DO $$
DECLARE
  mutation_rejected boolean := false;
  original_after jsonb;
BEGIN
  SELECT after_record INTO original_after
  FROM public.audit_events
  ORDER BY id DESC
  LIMIT 1;
  BEGIN
    UPDATE public.audit_events SET after_record = '{}'::jsonb;
  EXCEPTION WHEN raise_exception THEN
    mutation_rejected := true;
  END;
  IF NOT mutation_rejected
    OR (
      SELECT after_record FROM public.audit_events ORDER BY id DESC LIMIT 1
    ) <> original_after THEN
    RAISE EXCEPTION 'Audit events are not immutable.';
  END IF;
END
$$;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000001', true);
INSERT INTO storage.objects (bucket_id, name) VALUES (
  'book-covers',
  '00000000-0000-4000-8000-000000000010/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg'
);
DO $$
BEGIN
  IF (SELECT count(*) FROM storage.objects WHERE bucket_id = 'book-covers') <> 2 THEN
    RAISE EXCEPTION 'Editor cover upload policy failed.';
  END IF;
  DELETE FROM storage.objects
  WHERE bucket_id = 'book-covers'
    AND name = '00000000-0000-4000-8000-000000000010/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.jpg';
  IF (SELECT count(*) FROM storage.objects WHERE bucket_id = 'book-covers') <> 1 THEN
    RAISE EXCEPTION 'Editor cover delete policy failed.';
  END IF;
END
$$;
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000099', true);
DO $$
BEGIN
  IF public.current_catalog_role() IS NOT NULL
    OR (SELECT count(*) FROM public.catalog_editions) <> 0
    OR (SELECT count(*) FROM storage.objects) <> 0 THEN
    RAISE EXCEPTION 'Unapproved identity can access catalog or covers.';
  END IF;
  BEGIN
    PERFORM public.list_catalog_members();
    RAISE EXCEPTION 'Unapproved identity unexpectedly listed memberships.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.update_edition_title(
      '00000000-0000-4000-8000-000000000010', 1, 'Unapproved write'
    );
    RAISE EXCEPTION 'Unapproved identity unexpectedly edited an edition.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.update_edition_metadata(
      '00000000-0000-4000-8000-000000000010', 1,
      'Unapproved write', 'paperback', 'en', NULL, 'planned', NULL, '', NULL
    );
    RAISE EXCEPTION 'Unapproved identity unexpectedly changed metadata.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
  BEGIN
    PERFORM public.create_work_and_edition(
      'Unapproved create', 'paperback', 'en', NULL, 'planned', NULL, ''
    );
    RAISE EXCEPTION 'Unapproved identity unexpectedly created an edition.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$$;
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', true);
DO $$
BEGIN
  BEGIN
    INSERT INTO storage.objects (bucket_id, name) VALUES ('book-covers', 'viewer.jpg');
    RAISE EXCEPTION 'Viewer unexpectedly uploaded a cover.';
  EXCEPTION WHEN insufficient_privilege THEN
    NULL;
  END;
END
$$;
ROLLBACK;
SQL

for regression in supabase/tests/*.sql; do
  docker exec -i "$container" psql -U postgres -v ON_ERROR_STOP=1 < "$regression"
done

echo "Supabase authorization, memberships, relationships, atomic imports, revision/audit, date/ISBN, and covers passed."
