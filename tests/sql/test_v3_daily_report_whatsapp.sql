-- Execute after the migration, in the SAME transaction, then ROLLBACK.
-- No HTTP calls, no WhatsApp sends, nothing committed.
DO $$
DECLARE n integer; chunks text[];
BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.v3_report_recipients WHERE phone='33628457768' AND name='Esteban')
   THEN RAISE EXCEPTION 'missing Esteban seed'; END IF;

 DELETE FROM public.v3_report_recipients WHERE phone='33628457768';
 INSERT INTO public.v3_report_recipients(phone,name) VALUES ('33628457768','Esteban'),('5215591970405','Sandy');
 SELECT count(*) INTO n FROM public.v3_report_recipients WHERE phone IN ('33628457768','5215591970405');
 IF n<>2 THEN RAISE EXCEPTION 'valid E.164 recipients rejected'; END IF;

 BEGIN
   INSERT INTO public.v3_report_recipients(phone,name) VALUES ('+33628457768','Plus');
   RAISE EXCEPTION 'leading + accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;

 BEGIN
   INSERT INTO public.v3_report_recipients(phone,name) VALUES ('abc','Letters');
   RAISE EXCEPTION 'non-digit phone accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;

 INSERT INTO public.v3_daily_reports(report_date,text_chunks,summary)
   VALUES (date '2026-09-11',ARRAY['first'],'{"leads":1}'::jsonb);
 INSERT INTO public.v3_daily_reports(report_date,text_chunks,summary)
   VALUES (date '2026-09-11',ARRAY['second','third'],'{"leads":2}'::jsonb)
   ON CONFLICT (report_date) DO UPDATE
     SET text_chunks=EXCLUDED.text_chunks,summary=EXCLUDED.summary,updated_at=now();
 SELECT count(*) INTO n FROM public.v3_daily_reports WHERE report_date=date '2026-09-11';
 IF n<>1 THEN RAISE EXCEPTION 'upsert duplicated the day'; END IF;
 SELECT text_chunks INTO chunks FROM public.v3_daily_reports WHERE report_date=date '2026-09-11';
 IF chunks<>ARRAY['second','third'] THEN RAISE EXCEPTION 'upsert did not replace text_chunks'; END IF;

 INSERT INTO public.v3_report_sends(report_date,phone,wamid,status)
   VALUES (date '2026-09-11','33628457768','wamid.TEST','accepted');
 BEGIN
   INSERT INTO public.v3_report_sends(report_date,phone,status)
     VALUES (date '2026-09-11','33628457768','bogus');
   RAISE EXCEPTION 'bogus send status accepted';
 EXCEPTION WHEN check_violation THEN NULL; END;

 RAISE NOTICE 'V3_DAILY_REPORT_WHATSAPP_TESTS_PASS';
END $$;
