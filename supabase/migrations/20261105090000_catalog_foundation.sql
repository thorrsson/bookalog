CREATE ROLE catalog_client NOLOGIN NOBYPASSRLS;

CREATE FUNCTION public.is_valid_release_date(candidate text)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT SET search_path = ''
AS $$
  SELECT CASE
    WHEN candidate ~ '^[1-9][0-9]{3}$' THEN true
    WHEN candidate ~ '^[1-9][0-9]{3}-(0[1-9]|1[0-2])$' THEN true
    WHEN candidate ~ '^[1-9][0-9]{3}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])$'
      THEN pg_catalog.split_part(candidate, '-', 3)::integer
        <= pg_catalog.date_part('day', (
          pg_catalog.make_date(
            pg_catalog.split_part(candidate, '-', 1)::integer,
            pg_catalog.split_part(candidate, '-', 2)::integer,
            1
          ) + interval '1 month - 1 day'
        ))::integer
    ELSE false
  END
$$;

CREATE FUNCTION public.is_valid_isbn13(candidate text)
RETURNS boolean
LANGUAGE sql IMMUTABLE STRICT SET search_path = ''
AS $$
  SELECT candidate ~ '^97[89][0-9]{10}$'
    AND (
      SELECT pg_catalog.sum(
        (pg_catalog.ascii(pg_catalog.substr(candidate, digit_position, 1)) - 48)
        * CASE WHEN digit_position % 2 = 0 THEN 3 ELSE 1 END
      ) % 10 = 0
      FROM pg_catalog.generate_series(1, 13) AS digit_position
    )
$$;

CREATE TABLE public.memberships (
  user_id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  role text NOT NULL CHECK (role IN ('administrator', 'editor', 'viewer')),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE TABLE public.membership_audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  target_user_id uuid NOT NULL REFERENCES auth.users(id),
  before_role text,
  before_active boolean,
  after_role text NOT NULL,
  after_active boolean NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE INDEX membership_audit_target_occurred_idx
  ON public.membership_audit_events (target_user_id, occurred_at DESC);

CREATE TABLE public.works (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 500),
  subtitle text,
  description text NOT NULL DEFAULT '',
  revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE TABLE public.editions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  work_id uuid NOT NULL REFERENCES public.works(id),
  title text NOT NULL CHECK (length(btrim(title)) BETWEEN 1 AND 500),
  format text NOT NULL CHECK (format IN ('paperback', 'hardback', 'ebook', 'audio')),
  language text NOT NULL DEFAULT 'und' CHECK (length(language) BETWEEN 2 AND 35),
  isbn13 text CHECK (isbn13 IS NULL OR public.is_valid_isbn13(isbn13)),
  publication_status text NOT NULL CHECK (
    publication_status IN ('planned', 'announced', 'released', 'out_of_print')
  ),
  release_date text CHECK (
    release_date IS NULL OR public.is_valid_release_date(release_date)
  ),
  description text NOT NULL DEFAULT '',
  cover_key text,
  revision integer NOT NULL DEFAULT 1 CHECK (revision > 0),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now(),
  updated_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE UNIQUE INDEX editions_isbn13_unique
  ON public.editions (isbn13) WHERE isbn13 IS NOT NULL;
CREATE INDEX editions_work_id_idx ON public.editions (work_id);
CREATE INDEX editions_release_date_idx ON public.editions (release_date);
CREATE INDEX editions_publication_status_idx ON public.editions (publication_status);

CREATE TABLE public.contributors (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 300),
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE INDEX contributors_name_idx ON public.contributors (name);

CREATE TABLE public.edition_credits (
  edition_id uuid NOT NULL REFERENCES public.editions(id) ON DELETE CASCADE,
  contributor_id uuid NOT NULL REFERENCES public.contributors(id),
  credit_role text NOT NULL CHECK (length(btrim(credit_role)) BETWEEN 1 AND 80),
  display_order integer NOT NULL DEFAULT 0,
  PRIMARY KEY (edition_id, contributor_id, credit_role)
);

CREATE TABLE public.categories (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL UNIQUE CHECK (length(btrim(name)) BETWEEN 1 AND 160),
  source_code text,
  created_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);

CREATE TABLE public.edition_categories (
  edition_id uuid NOT NULL REFERENCES public.editions(id) ON DELETE CASCADE,
  category_id uuid NOT NULL REFERENCES public.categories(id),
  PRIMARY KEY (edition_id, category_id)
);

CREATE TABLE public.audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  edition_id uuid NOT NULL REFERENCES public.editions(id),
  before_record jsonb NOT NULL,
  after_record jsonb NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
CREATE INDEX audit_events_edition_occurred_idx
  ON public.audit_events (edition_id, occurred_at DESC);

CREATE VIEW public.catalog_editions WITH (security_invoker = true) AS
SELECT
  edition.id,
  pg_catalog.jsonb_build_object(
    'id', edition.id,
    'work_id', edition.work_id,
    'title', edition.title,
    'format', edition.format,
    'language', edition.language,
    'isbn13', edition.isbn13,
    'publication_status', edition.publication_status,
    'release_date', edition.release_date,
    'description', edition.description,
    'cover_key', edition.cover_key,
    'revision', edition.revision,
    'contributors', COALESCE((
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object(
          'name', contributor.name,
          'role', credit.credit_role
        ) ORDER BY credit.display_order, contributor.name, credit.credit_role
      )
      FROM public.edition_credits AS credit
      JOIN public.contributors AS contributor
        ON contributor.id = credit.contributor_id
      WHERE credit.edition_id = edition.id
    ), '[]'::jsonb),
    'categories', COALESCE((
      SELECT pg_catalog.jsonb_agg(category.name ORDER BY category.name)
      FROM public.edition_categories AS assignment
      JOIN public.categories AS category
        ON category.id = assignment.category_id
      WHERE assignment.edition_id = edition.id
    ), '[]'::jsonb)
  ) AS record
FROM public.editions AS edition;

CREATE FUNCTION public.current_catalog_role()
RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT membership.role
  FROM public.memberships AS membership
  WHERE membership.user_id = auth.uid()
    AND membership.active
$$;

CREATE FUNCTION public.list_catalog_members()
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  members jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR public.current_catalog_role() IS DISTINCT FROM 'administrator' THEN
    RAISE EXCEPTION 'Catalog administration is not permitted.' USING ERRCODE = '42501';
  END IF;
  SELECT COALESCE(
    pg_catalog.jsonb_agg(
      pg_catalog.jsonb_build_object(
        'user_id', membership.user_id,
        'email', COALESCE(account.email, ''),
        'role', membership.role,
        'active', membership.active,
        'created_at', membership.created_at
      ) ORDER BY pg_catalog.lower(account.email), membership.user_id
    ),
    '[]'::jsonb
  )
  INTO members
  FROM public.memberships AS membership
  JOIN auth.users AS account ON account.id = membership.user_id;
  RETURN members;
END
$$;

CREATE FUNCTION public.add_catalog_member(p_email text, p_role text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  target_user_id uuid;
  member jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR public.current_catalog_role() IS DISTINCT FROM 'administrator' THEN
    RAISE EXCEPTION 'Catalog administration is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF p_email IS NULL OR length(btrim(p_email)) NOT BETWEEN 3 AND 320
     OR p_role IS NULL OR p_role NOT IN ('administrator', 'editor', 'viewer') THEN
    RAISE EXCEPTION 'Enter an account email and a supported catalog role.'
      USING ERRCODE = '22023';
  END IF;
  SELECT account.id
  INTO target_user_id
  FROM auth.users AS account
  WHERE pg_catalog.lower(account.email) = pg_catalog.lower(btrim(p_email))
  ORDER BY account.id
  LIMIT 1;
  IF target_user_id IS NULL THEN
    RAISE EXCEPTION 'That account has not signed in. Ask an operator to invite it first.'
      USING ERRCODE = 'P0002';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.memberships WHERE user_id = target_user_id
  ) THEN
    RAISE EXCEPTION 'This account already has a catalog membership.'
      USING ERRCODE = '23505';
  END IF;
  INSERT INTO public.memberships (user_id, role, active)
  VALUES (target_user_id, p_role, true);
  INSERT INTO public.membership_audit_events (
    actor_id, target_user_id, before_role, before_active, after_role, after_active
  ) VALUES (auth.uid(), target_user_id, NULL, NULL, p_role, true);
  SELECT pg_catalog.jsonb_build_object(
    'user_id', account.id,
    'email', COALESCE(account.email, ''),
    'role', membership.role,
    'active', membership.active,
    'created_at', membership.created_at
  )
  INTO member
  FROM public.memberships AS membership
  JOIN auth.users AS account ON account.id = membership.user_id
  WHERE membership.user_id = target_user_id;
  RETURN member;
END
$$;

CREATE FUNCTION public.update_catalog_member(
  p_user_id uuid,
  p_role text,
  p_active boolean
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  previous public.memberships%ROWTYPE;
  member jsonb;
BEGIN
  IF auth.uid() IS NULL
     OR public.current_catalog_role() IS DISTINCT FROM 'administrator' THEN
    RAISE EXCEPTION 'Catalog administration is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF p_user_id IS NULL OR p_role IS NULL
     OR p_role NOT IN ('administrator', 'editor', 'viewer')
     OR p_active IS NULL THEN
    RAISE EXCEPTION 'Choose a supported catalog role and active state.'
      USING ERRCODE = '22023';
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended('bookalog-membership-admin', 0)
  );
  IF public.current_catalog_role() IS DISTINCT FROM 'administrator' THEN
    RAISE EXCEPTION 'Catalog administration is not permitted.' USING ERRCODE = '42501';
  END IF;
  SELECT * INTO previous
  FROM public.memberships
  WHERE user_id = p_user_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Catalog membership not found.' USING ERRCODE = 'P0002';
  END IF;
  IF p_user_id = auth.uid()
     AND (p_role <> previous.role OR NOT p_active) THEN
    RAISE EXCEPTION 'Ask another administrator to change your own access.'
      USING ERRCODE = '22023';
  END IF;
  IF previous.role = 'administrator' AND previous.active
     AND (p_role <> 'administrator' OR NOT p_active)
     AND (
       SELECT pg_catalog.count(*)
       FROM public.memberships
       WHERE role = 'administrator' AND active
     ) <= 1 THEN
    RAISE EXCEPTION 'At least one active administrator must remain.'
      USING ERRCODE = '22023';
  END IF;
  UPDATE public.memberships
  SET role = p_role, active = p_active
  WHERE user_id = p_user_id;
  INSERT INTO public.membership_audit_events (
    actor_id, target_user_id, before_role, before_active, after_role, after_active
  ) VALUES (
    auth.uid(), p_user_id, previous.role, previous.active, p_role, p_active
  );
  SELECT pg_catalog.jsonb_build_object(
    'user_id', account.id,
    'email', COALESCE(account.email, ''),
    'role', membership.role,
    'active', membership.active,
    'created_at', membership.created_at
  )
  INTO member
  FROM public.memberships AS membership
  JOIN auth.users AS account ON account.id = membership.user_id
  WHERE membership.user_id = p_user_id;
  RETURN member;
END
$$;

CREATE FUNCTION public.update_edition_title(
  edition_id uuid,
  expected_revision integer,
  new_title text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  previous jsonb;
  updated jsonb;
BEGIN
  IF auth.uid() IS NULL OR COALESCE(
    public.current_catalog_role() NOT IN ('administrator', 'editor'), true
  ) THEN
    RAISE EXCEPTION 'Catalog editing is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF new_title IS NULL OR length(btrim(new_title)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'A title of 1-500 characters is required.' USING ERRCODE = '22023';
  END IF;
  SELECT record INTO previous
  FROM public.catalog_editions
  WHERE id = edition_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edition not found.' USING ERRCODE = 'P0002';
  END IF;
  IF expected_revision IS NULL
     OR (previous->>'revision')::integer <> expected_revision THEN
    RAISE EXCEPTION 'The edition changed. Reload and compare your draft.'
      USING ERRCODE = 'PT409';
  END IF;
  UPDATE public.editions AS edition
  SET title = btrim(new_title),
      revision = edition.revision + 1,
      updated_at = pg_catalog.now()
  WHERE edition.id = edition_id
    AND edition.revision = expected_revision;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The edition changed. Reload and compare your draft.'
      USING ERRCODE = 'PT409';
  END IF;
  SELECT record INTO updated
  FROM public.catalog_editions
  WHERE id = edition_id;
  INSERT INTO public.audit_events (
    actor_id, edition_id, before_record, after_record
  ) VALUES (auth.uid(), edition_id, previous, updated);
  RETURN updated;
END
$$;

CREATE FUNCTION public.update_edition_metadata(
  p_edition_id uuid,
  p_expected_revision integer,
  p_title text,
  p_format text,
  p_language text,
  p_isbn13 text,
  p_publication_status text,
  p_release_date text,
  p_description text,
  p_cover_key text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  previous jsonb;
  updated jsonb;
BEGIN
  IF auth.uid() IS NULL OR COALESCE(
    public.current_catalog_role() NOT IN ('administrator', 'editor'), true
  ) THEN
    RAISE EXCEPTION 'Catalog editing is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'A title of 1-500 characters is required.' USING ERRCODE = '22023';
  END IF;
  IF p_format IS NULL OR p_format NOT IN ('paperback', 'hardback', 'ebook', 'audio') THEN
    RAISE EXCEPTION 'Choose a supported edition format.' USING ERRCODE = '22023';
  END IF;
  IF p_language IS NULL OR length(p_language) NOT BETWEEN 2 AND 35 THEN
    RAISE EXCEPTION 'Enter a language code of 2-35 characters.' USING ERRCODE = '22023';
  END IF;
  IF p_publication_status IS NULL
     OR p_publication_status NOT IN ('planned', 'announced', 'released', 'out_of_print') THEN
    RAISE EXCEPTION 'Choose a supported publication status.' USING ERRCODE = '22023';
  END IF;
  IF p_release_date IS NOT NULL AND NOT public.is_valid_release_date(p_release_date) THEN
    RAISE EXCEPTION 'Enter a valid release date as YYYY, YYYY-MM, or YYYY-MM-DD.'
      USING ERRCODE = '22023';
  END IF;
  IF p_isbn13 IS NOT NULL AND NOT public.is_valid_isbn13(p_isbn13) THEN
    RAISE EXCEPTION 'Enter a valid ISBN-13 or leave the field blank.'
      USING ERRCODE = '22023';
  END IF;
  IF p_description IS NULL THEN
    RAISE EXCEPTION 'Description cannot be null.' USING ERRCODE = '22023';
  END IF;

  SELECT record INTO previous
  FROM public.catalog_editions
  WHERE id = p_edition_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edition not found.' USING ERRCODE = 'P0002';
  END IF;
  IF p_expected_revision IS NULL
     OR (previous->>'revision')::integer <> p_expected_revision THEN
    RAISE EXCEPTION 'The edition changed. Reload and compare your draft.'
      USING ERRCODE = 'PT409';
  END IF;
  IF p_cover_key IS DISTINCT FROM previous->>'cover_key'
     AND p_cover_key IS NOT NULL
     AND (
       p_cover_key !~ (
         '^' || p_edition_id::text || '/[0-9a-f]{32}\.(jpg|png|webp)$'
       )
       OR NOT EXISTS (
         SELECT 1
         FROM storage.objects
         WHERE bucket_id = 'book-covers'
           AND name = p_cover_key
       )
     ) THEN
    RAISE EXCEPTION 'The uploaded cover reference is invalid.' USING ERRCODE = '22023';
  END IF;
  UPDATE public.editions AS edition
  SET title = btrim(p_title),
      format = p_format,
      language = btrim(p_language),
      isbn13 = p_isbn13,
      publication_status = p_publication_status,
      release_date = p_release_date,
      description = p_description,
      cover_key = p_cover_key,
      revision = edition.revision + 1,
      updated_at = pg_catalog.now()
  WHERE edition.id = p_edition_id
    AND edition.revision = p_expected_revision;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'The edition changed. Reload and compare your draft.'
      USING ERRCODE = 'PT409';
  END IF;
  SELECT record INTO updated
  FROM public.catalog_editions
  WHERE id = p_edition_id;
  INSERT INTO public.audit_events (
    actor_id, edition_id, before_record, after_record
  ) VALUES (auth.uid(), p_edition_id, previous, updated);
  RETURN updated;
END
$$;

CREATE FUNCTION public.create_work_and_edition(
  p_title text,
  p_format text,
  p_language text,
  p_isbn13 text,
  p_publication_status text,
  p_release_date text,
  p_description text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  created_work_id uuid;
  created_edition_id uuid;
  created_record jsonb;
BEGIN
  IF auth.uid() IS NULL OR COALESCE(
    public.current_catalog_role() NOT IN ('administrator', 'editor'), true
  ) THEN
    RAISE EXCEPTION 'Catalog editing is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'A title of 1-500 characters is required.' USING ERRCODE = '22023';
  END IF;
  IF p_format IS NULL OR p_format NOT IN ('paperback', 'hardback', 'ebook', 'audio') THEN
    RAISE EXCEPTION 'Choose a supported edition format.' USING ERRCODE = '22023';
  END IF;
  IF p_language IS NULL OR length(p_language) NOT BETWEEN 2 AND 35 THEN
    RAISE EXCEPTION 'Enter a language code of 2-35 characters.' USING ERRCODE = '22023';
  END IF;
  IF p_publication_status IS NULL
     OR p_publication_status NOT IN ('planned', 'announced', 'released', 'out_of_print') THEN
    RAISE EXCEPTION 'Choose a supported publication status.' USING ERRCODE = '22023';
  END IF;
  IF p_release_date IS NOT NULL AND NOT public.is_valid_release_date(p_release_date) THEN
    RAISE EXCEPTION 'Enter a valid release date as YYYY, YYYY-MM, or YYYY-MM-DD.'
      USING ERRCODE = '22023';
  END IF;
  IF p_isbn13 IS NOT NULL AND NOT public.is_valid_isbn13(p_isbn13) THEN
    RAISE EXCEPTION 'Enter a valid ISBN-13 or leave the field blank.'
      USING ERRCODE = '22023';
  END IF;
  IF p_description IS NULL THEN
    RAISE EXCEPTION 'Description cannot be null.' USING ERRCODE = '22023';
  END IF;

  INSERT INTO public.works (title, description)
  VALUES (btrim(p_title), p_description)
  RETURNING id INTO created_work_id;
  INSERT INTO public.editions (
    work_id, title, format, language, isbn13, publication_status,
    release_date, description
  ) VALUES (
    created_work_id, btrim(p_title), p_format, btrim(p_language), p_isbn13,
    p_publication_status, p_release_date, p_description
  )
  RETURNING id INTO created_edition_id;
  SELECT record INTO created_record
  FROM public.catalog_editions
  WHERE id = created_edition_id;
  INSERT INTO public.audit_events (
    actor_id, edition_id, before_record, after_record
  ) VALUES (auth.uid(), created_edition_id, '{}'::jsonb, created_record);
  RETURN created_record;
END
$$;

CREATE FUNCTION public.prevent_audit_mutation()
RETURNS trigger
LANGUAGE plpgsql SET search_path = ''
AS $$
BEGIN
  RAISE EXCEPTION 'Catalog audit events are immutable.';
END
$$;
CREATE TRIGGER audit_events_immutable
  BEFORE UPDATE OR DELETE ON public.audit_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_mutation();
CREATE TRIGGER membership_audit_events_immutable
  BEFORE UPDATE OR DELETE ON public.membership_audit_events
  FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_mutation();

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.works ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.editions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.contributors ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.edition_credits ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.edition_categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.membership_audit_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY own_membership ON public.memberships
  FOR SELECT TO catalog_client
  USING (user_id = auth.uid());
CREATE POLICY member_works ON public.works
  FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_editions ON public.editions
  FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_contributors ON public.contributors
  FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_edition_credits ON public.edition_credits
  FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_categories ON public.categories
  FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_edition_categories ON public.edition_categories
  FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_audit ON public.audit_events
  FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);

INSERT INTO storage.buckets (
  id, name, public, file_size_limit, allowed_mime_types
) VALUES (
  'book-covers', 'book-covers', false, 10485760,
  ARRAY['image/jpeg', 'image/png', 'image/webp']::text[]
)
ON CONFLICT (id) DO UPDATE SET
  public = false,
  file_size_limit = 10485760,
  allowed_mime_types = ARRAY['image/jpeg', 'image/png', 'image/webp']::text[];
CREATE POLICY member_cover_read ON storage.objects
  FOR SELECT TO authenticated
  USING (
    bucket_id = 'book-covers'
    AND public.current_catalog_role() IS NOT NULL
  );
CREATE POLICY editors_cover_insert ON storage.objects
  FOR INSERT TO authenticated
  WITH CHECK (
    bucket_id = 'book-covers'
    AND public.current_catalog_role() IN ('administrator', 'editor')
    AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.(jpg|png|webp)$'
  );
CREATE POLICY editors_cover_update ON storage.objects
  FOR UPDATE TO authenticated
  USING (
    bucket_id = 'book-covers'
    AND public.current_catalog_role() IN ('administrator', 'editor')
    AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.(jpg|png|webp)$'
  )
  WITH CHECK (
    bucket_id = 'book-covers'
    AND public.current_catalog_role() IN ('administrator', 'editor')
    AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.(jpg|png|webp)$'
  );
CREATE POLICY editors_cover_delete ON storage.objects
  FOR DELETE TO authenticated
  USING (
    bucket_id = 'book-covers'
    AND public.current_catalog_role() IN ('administrator', 'editor')
    AND name ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/[0-9a-f]{32}\.(jpg|png|webp)$'
  );

REVOKE ALL ON public.memberships, public.works, public.editions,
  public.contributors, public.edition_credits, public.categories,
  public.edition_categories, public.audit_events,
  public.membership_audit_events FROM PUBLIC, anon, authenticated;
REVOKE ALL ON public.catalog_editions FROM PUBLIC, anon, authenticated;
GRANT USAGE ON SCHEMA public TO catalog_client;
GRANT SELECT ON public.memberships, public.works, public.editions,
  public.contributors, public.edition_credits, public.categories,
  public.edition_categories, public.audit_events TO catalog_client;
GRANT SELECT ON public.catalog_editions TO catalog_client;

REVOKE ALL ON FUNCTION public.is_valid_release_date(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.is_valid_isbn13(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.current_catalog_role() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.list_catalog_members() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.add_catalog_member(text, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_catalog_member(uuid, text, boolean)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_edition_title(uuid, integer, text)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.update_edition_metadata(
  uuid, integer, text, text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_work_and_edition(
  text, text, text, text, text, text, text
) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.prevent_audit_mutation() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.current_catalog_role(),
  public.list_catalog_members(),
  public.add_catalog_member(text, text),
  public.update_catalog_member(uuid, text, boolean),
  public.update_edition_title(uuid, integer, text),
  public.update_edition_metadata(
    uuid, integer, text, text, text, text, text, text, text, text
  ),
  public.create_work_and_edition(
    text, text, text, text, text, text, text
  ) TO catalog_client;

GRANT catalog_client TO authenticated;
GRANT USAGE ON SCHEMA storage TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON storage.objects TO authenticated;
