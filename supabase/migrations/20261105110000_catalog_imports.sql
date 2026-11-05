CREATE TABLE public.catalog_imports (
  request_id uuid PRIMARY KEY,
  actor_id uuid NOT NULL REFERENCES auth.users(id),
  source_name text NOT NULL,
  source_sha256 text NOT NULL UNIQUE,
  request_rows jsonb NOT NULL,
  report jsonb NOT NULL,
  occurred_at timestamptz NOT NULL DEFAULT pg_catalog.now()
);
ALTER TABLE public.catalog_imports ENABLE ROW LEVEL SECURITY;
GRANT SELECT ON public.catalog_imports TO catalog_client;
CREATE POLICY catalog_imports_read ON public.catalog_imports FOR SELECT TO catalog_client
USING (
  public.current_catalog_role() = 'administrator'
  OR (public.current_catalog_role() = 'editor' AND actor_id = auth.uid())
);
CREATE TRIGGER catalog_imports_immutable BEFORE UPDATE OR DELETE ON public.catalog_imports
FOR EACH ROW EXECUTE FUNCTION public.prevent_audit_mutation();

CREATE FUNCTION public.import_catalog_metadata(
  p_request_id uuid, p_source_name text, p_source_sha256 text, p_rows jsonb
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = ''
AS $$
DECLARE
  prior public.catalog_imports%ROWTYPE;
  item jsonb;
  metadata jsonb;
  previous jsonb;
  saved jsonb;
  action text;
  results jsonb := '[]'::jsonb;
  report jsonb;
  created_count integer := 0;
  updated_count integer := 0;
  unchanged_count integer := 0;
BEGIN
  IF auth.uid() IS NULL OR COALESCE(
    public.current_catalog_role() NOT IN ('administrator', 'editor'), true
  ) THEN
    RAISE EXCEPTION 'Catalog importing is not permitted.' USING ERRCODE = '42501';
  END IF;
  IF p_request_id IS NULL OR p_source_name IS NULL
    OR length(p_source_name) NOT BETWEEN 1 AND 200
    OR p_source_sha256 IS NULL OR p_source_sha256 !~ '^[a-f0-9]{64}$'
    OR pg_catalog.jsonb_typeof(p_rows) IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'An import ID, source name, SHA-256 and row array are required.'
      USING ERRCODE = '22023';
  END IF;
  IF pg_catalog.jsonb_array_length(p_rows) NOT BETWEEN 1 AND 5000
    OR pg_catalog.pg_column_size(p_rows) > 16777216 THEN
    RAISE EXCEPTION 'Import at most 5,000 rows and 16 MiB of normalized data.'
      USING ERRCODE = '22023';
  END IF;

  -- Serialize retries of one request; a lost response must not duplicate creates.
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_request_id::text, 0)
  );
  SELECT * INTO prior FROM public.catalog_imports WHERE request_id = p_request_id;
  IF FOUND THEN
    IF prior.actor_id <> auth.uid() THEN
      RAISE EXCEPTION 'This import belongs to another account.' USING ERRCODE = '42501';
    END IF;
    IF prior.source_name <> p_source_name OR prior.source_sha256 <> p_source_sha256
      OR prior.request_rows <> p_rows THEN
      RAISE EXCEPTION 'An import ID cannot be reused for a different request.'
        USING ERRCODE = 'PT409';
    END IF;
    RETURN prior.report;
  END IF;
  PERFORM pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(p_source_sha256, 1)
  );
  IF EXISTS (SELECT 1 FROM public.catalog_imports WHERE source_sha256 = p_source_sha256) THEN
    RAISE EXCEPTION 'This file was already imported. Consult import history before using a revised file.'
      USING ERRCODE = 'PT409';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(p_rows) AS entry
    GROUP BY entry->>'source_row' HAVING count(*) > 1
  ) OR EXISTS (
    SELECT 1 FROM pg_catalog.jsonb_array_elements(p_rows) AS entry
    WHERE entry->>'edition_id' IS NOT NULL
    GROUP BY entry->>'edition_id' HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'Repeated source rows or edition IDs are not accepted.'
      USING ERRCODE = '22023';
  END IF;
  -- Lock existing editions consistently across concurrent imports.
  PERFORM id FROM public.editions
  WHERE id IN (
    SELECT (entry->>'edition_id')::uuid
    FROM pg_catalog.jsonb_array_elements(p_rows) AS entry
  ) ORDER BY id FOR UPDATE;

  FOR item IN SELECT value FROM pg_catalog.jsonb_array_elements(p_rows)
  LOOP
    IF pg_catalog.jsonb_typeof(item) IS DISTINCT FROM 'object'
      OR NOT item ?& ARRAY['source_row','edition_id','work_id','expected_revision','metadata']
      OR item - ARRAY['source_row','edition_id','work_id','expected_revision','metadata','source_context'] <> '{}'
      OR pg_catalog.jsonb_typeof(item->'source_row') IS DISTINCT FROM 'number'
      OR (item->>'source_row') !~ '^[0-9]+$'
      OR (item->>'source_row')::integer NOT BETWEEN 2 AND 5001 THEN
      RAISE EXCEPTION 'Invalid import row shape or source row number.'
        USING ERRCODE = '22023';
    END IF;
    IF item ? 'source_context' THEN
      IF pg_catalog.jsonb_typeof(item->'source_context') IS DISTINCT FROM 'object'
        OR NOT (item->'source_context') ?& ARRAY[
          'profile','record_reference','sender','sent_at','publisher'
        ]
        OR (item->'source_context') - ARRAY[
          'profile','record_reference','sender','sent_at','publisher'
        ] <> '{}'
        OR item->'source_context'->>'profile' <> 'bookalog-onix-core-v1'
        OR EXISTS (
          SELECT 1 FROM pg_catalog.jsonb_each(item->'source_context') AS field
          WHERE pg_catalog.jsonb_typeof(field.value) IS DISTINCT FROM 'string'
            OR length(field.value #>> '{}') NOT BETWEEN 1 AND 200
        ) THEN
        RAISE EXCEPTION 'Invalid ONIX source provenance.' USING ERRCODE = '22023';
      END IF;
    END IF;
    metadata := item->'metadata';
    IF pg_catalog.jsonb_typeof(metadata) IS DISTINCT FROM 'object'
      OR NOT metadata ?& ARRAY[
        'title','format','language','isbn13','publication_status','release_date','description'
      ]
      OR metadata - ARRAY[
        'title','format','language','isbn13','publication_status','release_date','description'
      ] <> '{}'
      OR EXISTS (
        SELECT 1 FROM pg_catalog.jsonb_each(metadata) AS field
        WHERE (field.key NOT IN ('isbn13','release_date')
          AND pg_catalog.jsonb_typeof(field.value) IS DISTINCT FROM 'string')
          OR (field.key IN ('isbn13','release_date')
            AND pg_catalog.jsonb_typeof(field.value) NOT IN ('string','null'))
      ) THEN
      RAISE EXCEPTION 'Only the documented core metadata fields are accepted.'
        USING ERRCODE = '22023';
    END IF;
    IF item->>'edition_id' IS NULL THEN
      IF item->>'expected_revision' IS NOT NULL THEN
        RAISE EXCEPTION 'A new edition cannot have an expected revision.'
          USING ERRCODE = '22023';
      END IF;
      saved := public.create_catalog_edition(
        metadata->>'title', metadata->>'format', metadata->>'language',
        metadata->>'isbn13', metadata->>'publication_status', metadata->>'release_date',
        metadata->>'description', (item->>'work_id')::uuid
      );
      action := 'created';
      created_count := created_count + 1;
    ELSE
      SELECT record INTO previous FROM public.catalog_editions
      WHERE id = (item->>'edition_id')::uuid;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'An import edition no longer exists.' USING ERRCODE = 'PT409';
      END IF;
      IF item->>'work_id' IS DISTINCT FROM previous->>'work_id'
        OR pg_catalog.jsonb_typeof(item->'expected_revision') IS DISTINCT FROM 'number'
        OR item->>'expected_revision' IS DISTINCT FROM previous->>'revision' THEN
        RAISE EXCEPTION 'An edition changed since preview. Rebuild the import review.'
          USING ERRCODE = 'PT409';
      END IF;
      IF metadata = (SELECT pg_catalog.jsonb_object_agg(field.key, field.value)
          FROM pg_catalog.jsonb_each(previous) AS field
          WHERE field.key = ANY(ARRAY[
            'title','format','language','isbn13','publication_status','release_date','description'
          ])) THEN
        saved := previous;
        action := 'unchanged';
        unchanged_count := unchanged_count + 1;
      ELSE
        saved := public.update_edition_metadata(
          (item->>'edition_id')::uuid, (item->>'expected_revision')::integer,
          metadata->>'title', metadata->>'format', metadata->>'language',
          metadata->>'isbn13', metadata->>'publication_status', metadata->>'release_date',
          metadata->>'description', previous->>'cover_key'
        );
        action := 'updated';
        updated_count := updated_count + 1;
      END IF;
    END IF;
    results := results || pg_catalog.jsonb_build_array(pg_catalog.jsonb_build_object(
      'source_row', (item->>'source_row')::integer, 'action', action,
      'edition_id', saved->>'id', 'revision', (saved->>'revision')::integer
    ) || CASE WHEN item ? 'source_context'
      THEN pg_catalog.jsonb_build_object('source_context', item->'source_context')
      ELSE '{}'::jsonb END);
  END LOOP;
  report := pg_catalog.jsonb_build_object(
    'request_id', p_request_id, 'source_name', p_source_name,
    'source_sha256', p_source_sha256, 'occurred_at', pg_catalog.now(),
    'created', created_count, 'updated', updated_count, 'unchanged', unchanged_count,
    'rows', results
  );
  INSERT INTO public.catalog_imports (
    request_id, actor_id, source_name, source_sha256, request_rows, report
  ) VALUES (p_request_id, auth.uid(), p_source_name, p_source_sha256, p_rows, report);
  RETURN report;
END
$$;
REVOKE ALL ON FUNCTION public.import_catalog_metadata(uuid, text, text, jsonb)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.import_catalog_metadata(uuid, text, text, jsonb)
  TO catalog_client;
