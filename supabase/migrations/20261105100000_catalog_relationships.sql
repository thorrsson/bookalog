CREATE OR REPLACE VIEW public.catalog_editions WITH (security_invoker = true) AS
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
          'id', contributor.id,
          'name', contributor.name,
          'role', credit.credit_role
        ) ORDER BY credit.display_order, contributor.name, credit.credit_role
      )
      FROM public.edition_credits AS credit
      JOIN public.contributors AS contributor ON contributor.id = credit.contributor_id
      WHERE credit.edition_id = edition.id
    ), '[]'::jsonb),
    'categories', COALESCE((
      SELECT pg_catalog.jsonb_agg(category.name ORDER BY category.name)
      FROM public.edition_categories AS assignment
      JOIN public.categories AS category ON category.id = assignment.category_id
      WHERE assignment.edition_id = edition.id
    ), '[]'::jsonb),
    'category_refs', COALESCE((
      SELECT pg_catalog.jsonb_agg(
        pg_catalog.jsonb_build_object('id', category.id, 'name', category.name)
        ORDER BY category.name
      )
      FROM public.edition_categories AS assignment
      JOIN public.categories AS category ON category.id = assignment.category_id
      WHERE assignment.edition_id = edition.id
    ), '[]'::jsonb)
  ) AS record
FROM public.editions AS edition;

-- Only the authorized, revision-checked RPC below may call this helper.
CREATE FUNCTION public.replace_edition_relations(
  p_edition_id uuid, p_credits jsonb, p_categories jsonb
) RETURNS void
LANGUAGE plpgsql SET search_path = ''
AS $$
DECLARE
  item jsonb;
  reference_id uuid;
  reference_name text;
  credit_position integer := 0;
BEGIN
  IF pg_catalog.jsonb_typeof(p_credits) IS DISTINCT FROM 'array'
    OR pg_catalog.jsonb_typeof(p_categories) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'Contributors and categories must be arrays.' USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_array_length(p_credits) > 100
    OR pg_catalog.jsonb_array_length(p_categories) > 100 THEN
    RAISE EXCEPTION 'An edition supports at most 100 credits and 100 categories.'
      USING ERRCODE = '22023';
  END IF;
  DELETE FROM public.edition_credits WHERE edition_id = p_edition_id;
  DELETE FROM public.edition_categories WHERE edition_id = p_edition_id;
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_credits)
  LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR item - ARRAY['id', 'name', 'role']::text[] <> '{}'::jsonb
      OR (item ? 'id') = (item ? 'name')
      OR pg_catalog.jsonb_typeof(item->'role') IS DISTINCT FROM 'string'
      OR length(btrim(item->>'role')) NOT BETWEEN 1 AND 80 THEN
      RAISE EXCEPTION 'Each credit needs an existing ID or a new name, and a role.'
        USING ERRCODE = '22023';
    END IF;
    IF item ? 'id' THEN
      SELECT id INTO reference_id FROM public.contributors
      WHERE id = (item->>'id')::uuid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Contributor not found.' USING ERRCODE = '22023';
      END IF;
    ELSE
      reference_name := btrim(item->>'name');
      IF pg_catalog.jsonb_typeof(item->'name') IS DISTINCT FROM 'string'
        OR length(reference_name) NOT BETWEEN 1 AND 300 THEN
        RAISE EXCEPTION 'Contributor names must contain 1-300 characters.'
          USING ERRCODE = '22023';
      END IF;
      -- Names are not identities: two contributors may legitimately share one.
      INSERT INTO public.contributors (name) VALUES (reference_name)
      RETURNING id INTO reference_id;
    END IF;
    INSERT INTO public.edition_credits (
      edition_id, contributor_id, credit_role, display_order
    ) VALUES (
      p_edition_id, reference_id, btrim(item->>'role'), credit_position
    );
    credit_position := credit_position + 1;
  END LOOP;
  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_categories)
  LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR item - ARRAY['id', 'name']::text[] <> '{}'::jsonb
      OR (item ? 'id') = (item ? 'name') THEN
      RAISE EXCEPTION 'Each category needs an existing ID or a new name.'
        USING ERRCODE = '22023';
    END IF;
    IF item ? 'id' THEN
      SELECT id INTO reference_id FROM public.categories
      WHERE id = (item->>'id')::uuid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'Category not found.' USING ERRCODE = '22023';
      END IF;
    ELSE
      reference_name := btrim(item->>'name');
      IF pg_catalog.jsonb_typeof(item->'name') IS DISTINCT FROM 'string'
        OR length(reference_name) NOT BETWEEN 1 AND 160 THEN
        RAISE EXCEPTION 'Category names must contain 1-160 characters.'
          USING ERRCODE = '22023';
      END IF;
      INSERT INTO public.categories (name) VALUES (reference_name)
      ON CONFLICT (name) DO NOTHING;
      SELECT id INTO reference_id FROM public.categories WHERE name = reference_name;
    END IF;
    INSERT INTO public.edition_categories (edition_id, category_id)
    VALUES (p_edition_id, reference_id);
  END LOOP;
END
$$;

CREATE FUNCTION public.update_edition_relations(
  p_edition_id uuid, p_expected_revision integer, p_credits jsonb, p_categories jsonb
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
  PERFORM 1 FROM public.editions WHERE id = p_edition_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Edition not found.' USING ERRCODE = 'P0002';
  END IF;
  SELECT record INTO previous FROM public.catalog_editions WHERE id = p_edition_id;
  IF p_expected_revision IS NULL
    OR (previous->>'revision')::integer <> p_expected_revision THEN
    RAISE EXCEPTION 'The edition changed. Reload and compare your draft.'
      USING ERRCODE = 'PT409';
  END IF;
  PERFORM public.replace_edition_relations(p_edition_id, p_credits, p_categories);
  UPDATE public.editions SET revision = revision + 1, updated_at = pg_catalog.now()
  WHERE id = p_edition_id;
  SELECT record INTO updated FROM public.catalog_editions WHERE id = p_edition_id;
  INSERT INTO public.audit_events (actor_id, edition_id, before_record, after_record)
  VALUES (auth.uid(), p_edition_id, previous, updated);
  RETURN updated;
END
$$;

CREATE FUNCTION public.create_catalog_edition(
  p_title text, p_format text, p_language text, p_isbn13 text,
  p_publication_status text, p_release_date text, p_description text,
  p_work_id uuid DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  target_work_id uuid := p_work_id;
  created_edition_id uuid;
  created_record jsonb;
BEGIN
  IF auth.uid() IS NULL OR COALESCE(
    public.current_catalog_role() NOT IN ('administrator', 'editor'), true
  ) THEN
    RAISE EXCEPTION 'Catalog editing is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF p_title IS NULL OR length(btrim(p_title)) NOT BETWEEN 1 AND 500
    OR p_format IS NULL OR p_format NOT IN ('paperback', 'hardback', 'ebook', 'audio')
    OR p_language IS NULL OR length(btrim(p_language)) NOT BETWEEN 2 AND 35
    OR p_publication_status IS NULL
    OR p_publication_status NOT IN ('planned', 'announced', 'released', 'out_of_print')
    OR p_description IS NULL THEN
    RAISE EXCEPTION 'Valid title, format, language, status and description are required.'
      USING ERRCODE = '22023';
  END IF;
  IF p_release_date IS NOT NULL AND NOT public.is_valid_release_date(p_release_date) THEN
    RAISE EXCEPTION 'Enter a valid release date as YYYY, YYYY-MM, or YYYY-MM-DD.'
      USING ERRCODE = '22023';
  END IF;
  IF p_isbn13 IS NOT NULL AND NOT public.is_valid_isbn13(p_isbn13) THEN
    RAISE EXCEPTION 'Enter a valid ISBN-13 or leave the field blank.'
      USING ERRCODE = '22023';
  END IF;
  IF target_work_id IS NULL THEN
    INSERT INTO public.works (title, description) VALUES (btrim(p_title), p_description)
    RETURNING id INTO target_work_id;
  ELSE
    PERFORM 1 FROM public.works WHERE id = target_work_id FOR KEY SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Work not found.' USING ERRCODE = 'P0002';
    END IF;
  END IF;
  INSERT INTO public.editions (
    work_id, title, format, language, isbn13, publication_status, release_date, description
  ) VALUES (
    target_work_id, btrim(p_title), p_format, btrim(p_language), p_isbn13,
    p_publication_status, p_release_date, p_description
  ) RETURNING id INTO created_edition_id;
  SELECT record INTO created_record FROM public.catalog_editions WHERE id = created_edition_id;
  INSERT INTO public.audit_events (actor_id, edition_id, before_record, after_record)
  VALUES (auth.uid(), created_edition_id, '{}'::jsonb, created_record);
  RETURN created_record;
END
$$;

CREATE OR REPLACE FUNCTION public.create_work_and_edition(
  p_title text, p_format text, p_language text, p_isbn13 text,
  p_publication_status text, p_release_date text, p_description text
) RETURNS jsonb
LANGUAGE sql SECURITY INVOKER SET search_path = ''
AS $$
  SELECT public.create_catalog_edition(
    p_title, p_format, p_language, p_isbn13,
    p_publication_status, p_release_date, p_description
  )
$$;

REVOKE ALL ON FUNCTION public.replace_edition_relations(uuid, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated, catalog_client;
REVOKE ALL ON FUNCTION public.update_edition_relations(uuid, integer, jsonb, jsonb)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION public.create_catalog_edition(
  text, text, text, text, text, text, text, uuid
) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.update_edition_relations(uuid, integer, jsonb, jsonb),
  public.create_catalog_edition(text, text, text, text, text, text, text, uuid)
  TO catalog_client;
