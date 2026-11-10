-- Apply catalog.sql first in a disposable Supabase project, never a production project.
-- PostgREST supplies request.jwt.claims after verifying the Supabase access token.
GRANT catalog_client TO authenticated;
REVOKE ALL ON public.memberships, public.works, public.editions, public.audit_events FROM anon;
REVOKE ALL ON FUNCTION public.update_edition_title(uuid, integer, text) FROM anon;
