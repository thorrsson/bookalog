BEGIN;
SET LOCAL ROLE authenticated;
SELECT set_config('request.jwt.claim.sub', '00000000-0000-4000-8000-000000000003', true);
DO $$
BEGIN
  BEGIN
    PERFORM public.update_edition_relations(
      '00000000-0000-4000-8000-000000000010', 3, '[]', '[]'
    );
    RAISE EXCEPTION 'Viewer changed relationships.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  BEGIN
    PERFORM public.create_catalog_edition(
      'Denied', 'ebook', 'en', NULL, 'planned', NULL, '',
      '00000000-0000-4000-8000-000000100000'
    );
    RAISE EXCEPTION 'Viewer created an edition on an existing work.';
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
  initial jsonb;
  updated jsonb;
  created jsonb;
  event_count integer;
  contributor_count integer;
  work_count integer;
BEGIN
  SELECT record INTO initial FROM public.catalog_editions
  WHERE id = '00000000-0000-4000-8000-000000000010';
  SELECT count(*) INTO event_count FROM public.audit_events;
  SELECT count(*) INTO contributor_count FROM public.contributors;
  SELECT count(*) INTO work_count FROM public.works;
  IF initial->'contributors'->0->>'id' <> '00000000-0000-4000-8000-000000200000'
    OR initial->'category_refs'->0->>'id' <> '00000000-0000-4000-8000-000000300000' THEN
    RAISE EXCEPTION 'Projection discarded relationship identity.';
  END IF;
  BEGIN
    PERFORM public.replace_edition_relations(
      '00000000-0000-4000-8000-000000000010', '[]', '[]'
    );
    RAISE EXCEPTION 'Editor invoked the unguarded internal helper.';
  EXCEPTION WHEN insufficient_privilege THEN NULL;
  END;
  updated := public.update_edition_relations(
    '00000000-0000-4000-8000-000000000010', 3,
    '[{"name":"A. Contributor","role":"translator"},
      {"id":"00000000-0000-4000-8000-000000200000","role":"author"}]',
    '[{"id":"00000000-0000-4000-8000-000000300000"},{"name":"Travel"}]'
  );
  IF updated->'contributors'->0->>'name' <> 'A. Contributor'
    OR updated->'contributors'->0->>'role' <> 'translator'
    OR updated->'contributors'->0->>'id' = '00000000-0000-4000-8000-000000200000'
    OR updated->'contributors'->1->>'role' <> 'author'
    OR updated->'categories' <> '["Fiction","Travel"]'::jsonb
    OR (updated->>'revision')::integer <> 4
    OR (SELECT count(*) FROM public.contributors) <> contributor_count + 1
    OR (SELECT count(*) FROM public.audit_events) <> event_count + 1
    OR NOT EXISTS (
      SELECT 1 FROM public.audit_events WHERE before_record = initial AND after_record = updated
    ) THEN
    RAISE EXCEPTION 'Relationship ordering, identity, revision or audit failed.';
  END IF;
  BEGIN
    PERFORM public.update_edition_relations(
      '00000000-0000-4000-8000-000000000010', 3, '[]', '[]'
    );
    RAISE EXCEPTION 'Stale relationship edit succeeded.';
  EXCEPTION WHEN SQLSTATE 'PT409' THEN NULL;
  END;
  BEGIN
    PERFORM public.update_edition_relations(
      '00000000-0000-4000-8000-000000000010', 4,
      '[{"name":"Must roll back","role":"author"}]',
      '[{"id":"00000000-0000-4000-8000-999999999999"}]'
    );
    RAISE EXCEPTION 'Missing category was accepted.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  BEGIN
    PERFORM public.update_edition_relations(
      '00000000-0000-4000-8000-000000000010', 4,
      '[{"id":"00000000-0000-4000-8000-000000200000","role":"author"},
        {"id":"00000000-0000-4000-8000-000000200000","role":"author"}]', '[]'
    );
    RAISE EXCEPTION 'Duplicate credit was accepted.';
  EXCEPTION WHEN unique_violation THEN NULL;
  END;
  BEGIN
    PERFORM public.update_edition_relations(
      '00000000-0000-4000-8000-000000000010', 4, 'null', '[]'
    );
    RAISE EXCEPTION 'Null relationship input was accepted.';
  EXCEPTION WHEN SQLSTATE '22023' THEN NULL;
  END;
  IF (SELECT record FROM public.catalog_editions
      WHERE id = '00000000-0000-4000-8000-000000000010') <> updated
    OR (SELECT count(*) FROM public.audit_events) <> event_count + 1
    OR (SELECT count(*) FROM public.contributors) <> contributor_count + 1 THEN
    RAISE EXCEPTION 'Failed edits did not roll back atomically.';
  END IF;
  created := public.create_catalog_edition(
    'An additional edition', 'audio', 'en', NULL, 'planned', '2035', '',
    '00000000-0000-4000-8000-000000100000'
  );
  IF created->>'work_id' <> initial->>'work_id'
    OR created->>'id' = initial->>'id'
    OR created->'contributors' <> '[]'::jsonb
    OR created->'category_refs' <> '[]'::jsonb
    OR (SELECT count(*) FROM public.works) <> work_count
    OR (SELECT count(*) FROM public.audit_events) <> event_count + 2 THEN
    RAISE EXCEPTION 'Additional edition created a work or inherited metadata implicitly.';
  END IF;
  PERFORM public.update_edition_relations(
    '00000000-0000-4000-8000-000000000010', 4, '[]', '[{"name":"Travel"}]'
  );
  IF (SELECT count(*) FROM public.categories WHERE name = 'Travel') <> 1
    OR (SELECT record FROM public.catalog_editions WHERE id = (created->>'id')::uuid) <> created THEN
    RAISE EXCEPTION 'Category reuse or edition-scoped editing failed.';
  END IF;
END
$$;
ROLLBACK;
