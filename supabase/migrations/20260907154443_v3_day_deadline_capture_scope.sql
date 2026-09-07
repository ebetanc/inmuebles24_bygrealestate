-- A returning assigned person gets a new capture deadline. The previous
-- opportunity's deadline must not suppress the new exact assigned notice.
CREATE OR REPLACE FUNCTION public.v3_day_deadline(p_capture_id bigint DEFAULT NULL,
 p_opportunity_id bigint DEFAULT NULL,p_request_id bigint DEFAULT NULL)
RETURNS timestamptz LANGUAGE sql STABLE SET search_path='' AS $$
 SELECT min(c.day_deadline_at) FROM public.i24_capture_events c
 WHERE (p_capture_id IS NOT NULL AND c.capture_event_id=p_capture_id)
    OR (p_capture_id IS NULL AND p_request_id IS NOT NULL AND EXISTS (
        SELECT 1 FROM public.easybroker_i24_request_links l
        WHERE l.eb_request_id=p_request_id AND l.i24_capture_event_id=c.capture_event_id))
    OR (p_capture_id IS NULL AND p_request_id IS NULL AND p_opportunity_id IS NOT NULL
        AND c.opportunity_id=p_opportunity_id AND c.disposition='created_new');
$$;
CREATE OR REPLACE FUNCTION public.v3_day_allowed(p_capture_id bigint DEFAULT NULL,
 p_opportunity_id bigint DEFAULT NULL,p_request_id bigint DEFAULT NULL)
RETURNS boolean LANGUAGE sql VOLATILE SET search_path='' AS $$
 SELECT (public.v3_day_deadline(p_capture_id,p_opportunity_id,p_request_id) IS NULL
     OR public.v3_day_deadline(p_capture_id,p_opportunity_id,p_request_id)
          > clock_timestamp()+interval '10 seconds')
 AND NOT EXISTS (SELECT 1 FROM public.i24_capture_events c
   WHERE c.day_hold_reason IS NOT NULL AND (
     (p_capture_id IS NOT NULL AND c.capture_event_id=p_capture_id)
     OR (p_capture_id IS NULL AND p_request_id IS NOT NULL AND EXISTS (
       SELECT 1 FROM public.easybroker_i24_request_links l
       WHERE l.eb_request_id=p_request_id AND l.i24_capture_event_id=c.capture_event_id))
     OR (p_capture_id IS NULL AND p_request_id IS NULL AND c.opportunity_id=p_opportunity_id)));
$$;
