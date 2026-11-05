BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.import_catalog_metadata(
      gen_random_uuid(), 'denied.csv', repeat('0',64), '[]'
    );
    RAISE EXCEPTION 'Viewer imported catalog data.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$$;
ROLLBACK;

BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000002', true);
DO $$
DECLARE
  request_id uuid := gen_random_uuid();
  rows jsonb;
  report jsonb;
  initial jsonb;
  events integer;
  editions integer;
  imports integer;
  onix_rows jsonb;
  onix_request uuid;
  provenance jsonb := '{"profile":"bookalog-onix-core-v1","record_reference":"external-001",
    "sender":"Example Sender","sent_at":"20300102T030405Z","publisher":"Example Press"}';
BEGIN
  SELECT record INTO initial FROM public.catalog_editions
  WHERE id = '00000000-0000-4000-8000-000000000010';
  SELECT count(*) INTO events FROM public.audit_events;
  SELECT count(*) INTO editions FROM public.editions;
  rows := pg_catalog.jsonb_build_array(
    pg_catalog.jsonb_build_object(
      'source_row', 2, 'edition_id', initial->>'id', 'work_id', initial->>'work_id',
      'expected_revision', (initial->>'revision')::integer,
      'metadata', pg_catalog.jsonb_build_object(
        'title','Imported title','format','hardback','language','en',
        'isbn13', initial->'isbn13', 'publication_status','released',
        'release_date','2030-02', 'description','Imported description'
      )
    ),
    '{"source_row":3,"edition_id":null,"work_id":null,"expected_revision":null,
      "metadata":{"title":"Created by import","format":"ebook","language":"en",
      "isbn13":null,"publication_status":"planned","release_date":"2031","description":""}}'::jsonb
  );
  report := public.import_catalog_metadata(request_id, 'source.csv', repeat('a',64), rows);
  IF report->>'created' <> '1' OR report->>'updated' <> '1'
    OR jsonb_array_length(report->'rows') <> 2
    OR (SELECT count(*) FROM public.audit_events) <> events + 2
    OR (SELECT count(*) FROM public.editions) <> editions + 1 THEN
    RAISE EXCEPTION 'Import counts, report, or audits are incorrect.';
  END IF;
  IF (SELECT record->'contributors' FROM public.catalog_editions WHERE id = (initial->>'id')::uuid)
      <> initial->'contributors'
    OR (SELECT record->'cover_key' FROM public.catalog_editions WHERE id = (initial->>'id')::uuid)
      <> initial->'cover_key' THEN
    RAISE EXCEPTION 'Core import damaged unrelated metadata.';
  END IF;
  IF public.import_catalog_metadata(request_id, 'source.csv', repeat('a',64), rows) <> report
    OR (SELECT count(*) FROM public.audit_events) <> events + 2 THEN
    RAISE EXCEPTION 'Retry duplicated changes or changed its report.';
  END IF;
  BEGIN
    PERFORM public.import_catalog_metadata(request_id, 'other.csv', repeat('a',64), rows);
    RAISE EXCEPTION 'Reused request ID accepted a different input.';
  EXCEPTION WHEN SQLSTATE 'PT409' THEN NULL;
  END;
  BEGIN
    PERFORM public.import_catalog_metadata(gen_random_uuid(), 'source.csv', repeat('a',64), rows);
    RAISE EXCEPTION 'A new request ID duplicated an already imported file.';
  EXCEPTION WHEN SQLSTATE 'PT409' THEN NULL;
  END;
  SELECT record INTO initial FROM public.catalog_editions
  WHERE id = '00000000-0000-4000-8000-000000000010';
  report := public.import_catalog_metadata(gen_random_uuid(), 'unchanged.csv', repeat('d',64),
    jsonb_build_array(jsonb_build_object(
      'source_row',2,'edition_id',initial->>'id','work_id',initial->>'work_id',
      'expected_revision',(initial->>'revision')::integer,
      'metadata',(SELECT jsonb_object_agg(field.key, field.value)
        FROM jsonb_each(initial) AS field WHERE field.key = ANY(ARRAY[
          'title','format','language','isbn13','publication_status','release_date','description'
        ]))
    )));
  IF report->>'unchanged' <> '1' OR (SELECT count(*) FROM public.audit_events) <> events + 2 THEN
    RAISE EXCEPTION 'Unchanged imports must not create spurious revisions or audits.';
  END IF;
  SELECT count(*) INTO imports FROM public.catalog_imports;
  BEGIN
    -- Create first, then encounter a stale update: the whole request must roll back.
    PERFORM public.import_catalog_metadata(
      gen_random_uuid(), 'conflict.csv', repeat('b',64),
      jsonb_build_array(rows->1, rows->0)
    );
    RAISE EXCEPTION 'Stale import succeeded.';
  EXCEPTION WHEN SQLSTATE 'PT409' THEN NULL;
  END;
  IF (SELECT count(*) FROM public.editions) <> editions + 1
    OR (SELECT count(*) FROM public.audit_events) <> events + 2
    OR (SELECT count(*) FROM public.catalog_imports) <> imports THEN
    RAISE EXCEPTION 'Failed import left partial changes or a false success report.';
  END IF;
  onix_rows := jsonb_build_array((rows->1) || jsonb_build_object('source_context', provenance));
  onix_request := gen_random_uuid();
  report := public.import_catalog_metadata(onix_request, 'source.onix', repeat('e',64), onix_rows);
  IF report->'rows'->0->'source_context' IS DISTINCT FROM provenance
    OR (SELECT request_rows->0->'source_context' FROM public.catalog_imports
      WHERE catalog_imports.request_id = onix_request)
        IS DISTINCT FROM provenance THEN
    RAISE EXCEPTION 'ONIX provenance was not preserved in the report and request history.';
  END IF;
  IF public.import_catalog_metadata(onix_request, 'source.onix', repeat('e',64), onix_rows) <> report THEN
    RAISE EXCEPTION 'ONIX retry changed the report.';
  END IF;
  BEGIN
    PERFORM public.import_catalog_metadata(onix_request, 'source.onix', repeat('e',64),
      jsonb_build_array(jsonb_set(onix_rows->0, '{source_context,publisher}', '"Changed"')));
    RAISE EXCEPTION 'Retry replaced ONIX provenance.';
  EXCEPTION WHEN SQLSTATE 'PT409' THEN NULL;
  END;
  FOREACH provenance IN ARRAY ARRAY[
    'null'::jsonb, '[]'::jsonb, '{}'::jsonb,
    (onix_rows->0->'source_context') || '{"unmapped":"must not disappear"}'::jsonb,
    (onix_rows->0->'source_context') || '{"publisher":null}'::jsonb
  ] LOOP
    BEGIN
      PERFORM public.import_catalog_metadata(gen_random_uuid(), 'bad.onix', repeat('f',64),
        jsonb_build_array((onix_rows->0) || jsonb_build_object('source_context', provenance)));
      RAISE EXCEPTION 'Invalid ONIX provenance was accepted.';
    EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
    END;
  END LOOP;
  BEGIN
    PERFORM public.import_catalog_metadata(gen_random_uuid(), 'repeat.csv', repeat('c',64),
      jsonb_build_array(rows->1, rows->1));
    RAISE EXCEPTION 'Repeated source rows were accepted.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    DELETE FROM public.catalog_imports;
    RAISE EXCEPTION 'Editor deleted import history.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000003',true);
  IF (SELECT count(*) FROM public.catalog_imports) <> 0 THEN
    RAISE EXCEPTION 'Viewer read import requests.';
  END IF;
  BEGIN
    PERFORM public.import_catalog_metadata(request_id, 'source.csv', repeat('a',64), rows);
    RAISE EXCEPTION 'Viewer replayed an editor import.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
END
$$;
ROLLBACK;
