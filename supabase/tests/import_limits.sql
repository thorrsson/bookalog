BEGIN;
SET LOCAL ROLE authenticated;
SET LOCAL statement_timeout = '60s';
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  rows jsonb;
  report jsonb;
  initial_editions integer;
  initial_events integer;
BEGIN
  SELECT count(*) INTO initial_editions FROM public.editions;
  SELECT count(*) INTO initial_events FROM public.audit_events;
  SELECT jsonb_agg(jsonb_build_object(
    'source_row', n + 1, 'edition_id', NULL, 'work_id', NULL, 'expected_revision', NULL,
    'metadata', jsonb_build_object(
      'title', 'Imported edition ' || n, 'format', 'ebook', 'language', 'en',
      'isbn13', NULL, 'publication_status', 'planned', 'release_date', '2030-02',
      'description', 'Synthetic import limit regression'
    )
  ) ORDER BY n) INTO rows FROM generate_series(1, 5000) AS n;
  report := public.import_catalog_metadata(
    gen_random_uuid(), '5000-editions.csv', repeat('e',64), rows
  );
  IF report->>'created' <> '5000' OR jsonb_array_length(report->'rows') <> 5000
    OR (SELECT count(*) FROM public.editions) <> initial_editions + 5000
    OR (SELECT count(*) FROM public.audit_events) <> initial_events + 5000
    OR EXISTS (
      SELECT 1 FROM jsonb_array_elements(report->'rows') AS result
      LEFT JOIN public.editions AS edition ON edition.id = (result->>'edition_id')::uuid
      WHERE edition.id IS NULL OR edition.title <> 'Imported edition ' || ((result->>'source_row')::integer - 1)
        OR edition.release_date <> '2030-02' OR edition.revision <> 1
    ) THEN
    RAISE EXCEPTION 'A 5,000-edition import lost or changed records, dates, revisions, or audit events.';
  END IF;
  BEGIN
    PERFORM public.import_catalog_metadata(
      gen_random_uuid(), '5001-editions.csv', repeat('f',64), rows || jsonb_build_array(rows->0)
    );
    RAISE EXCEPTION 'The 5,000-row import limit was not enforced.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
END
$$;
ROLLBACK;
