CREATE ROLE catalog_client NOLOGIN NOBYPASSRLS;

CREATE TABLE public.memberships (
  user_id text PRIMARY KEY,
  role text NOT NULL CHECK (role IN ('administrator', 'editor', 'viewer')),
  active boolean NOT NULL DEFAULT true
);

CREATE TABLE public.works (
  id uuid PRIMARY KEY,
  title text NOT NULL
);

-- A deliberately narrow read projection for the comparison, not the production catalog schema.
CREATE TABLE public.editions (
  id uuid PRIMARY KEY,
  work_id uuid NOT NULL REFERENCES public.works(id),
  record jsonb NOT NULL,
  CHECK (record->>'id' = id::text),
  CHECK (record->>'work_id' = work_id::text),
  CHECK ((record->>'revision')::integer > 0),
  CHECK (length(btrim(record->>'title')) BETWEEN 1 AND 500)
);
CREATE UNIQUE INDEX editions_isbn ON public.editions ((record->>'isbn13'))
  WHERE record->>'isbn13' IS NOT NULL;

CREATE TABLE public.audit_events (
  id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id text NOT NULL,
  edition_id uuid NOT NULL REFERENCES public.editions(id),
  before_record jsonb NOT NULL,
  after_record jsonb NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE FUNCTION public.current_actor() RETURNS text
LANGUAGE sql STABLE SET search_path = ''
AS $$ SELECT nullif(current_setting('request.jwt.claims', true), '')::jsonb->>'sub' $$;

CREATE FUNCTION public.current_catalog_role() RETURNS text
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = ''
AS $$
  SELECT role FROM public.memberships
  WHERE user_id = public.current_actor() AND active
$$;

ALTER TABLE public.memberships ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.works ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.editions ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;

CREATE POLICY own_membership ON public.memberships FOR SELECT TO catalog_client
  USING (user_id = public.current_actor());
CREATE POLICY member_works ON public.works FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_editions ON public.editions FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);
CREATE POLICY member_audit ON public.audit_events FOR SELECT TO catalog_client
  USING (public.current_catalog_role() IS NOT NULL);

CREATE FUNCTION public.update_edition_title(edition_id uuid, expected_revision integer, new_title text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  previous jsonb;
  updated jsonb;
BEGIN
  IF coalesce(public.current_catalog_role(), '') NOT IN ('administrator', 'editor') THEN
    RAISE EXCEPTION 'Catalog editing is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF new_title IS NULL OR length(btrim(new_title)) NOT BETWEEN 1 AND 500 THEN
    RAISE EXCEPTION 'A title of 1-500 characters is required.' USING ERRCODE = '22023';
  END IF;
  SELECT record INTO previous FROM public.editions WHERE id = edition_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edition not found.' USING ERRCODE = 'P0002';
  END IF;
  IF expected_revision IS NULL OR (previous->>'revision')::integer <> expected_revision THEN
    RAISE EXCEPTION 'The edition changed. Reload and compare your draft.' USING ERRCODE = 'PT409';
  END IF;
  updated := previous || jsonb_build_object('title', btrim(new_title), 'revision', expected_revision + 1);
  UPDATE public.editions SET record = updated WHERE id = edition_id;
  INSERT INTO public.audit_events (actor_id, edition_id, before_record, after_record)
    VALUES (public.current_actor(), edition_id, previous, updated);
  RETURN updated;
END
$$;

REVOKE ALL ON FUNCTION public.current_actor() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.current_catalog_role() FROM PUBLIC;
REVOKE ALL ON FUNCTION public.update_edition_title(uuid, integer, text) FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO catalog_client;
GRANT SELECT ON public.memberships, public.works, public.editions, public.audit_events TO catalog_client;
GRANT EXECUTE ON FUNCTION public.current_actor(), public.current_catalog_role(),
  public.update_edition_title(uuid, integer, text) TO catalog_client;
