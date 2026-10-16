"""Shared-hour routing check against the live DB, inside one transaction that is ROLLED BACK.

Usage: python scripts/v3_shared_hour_check.py [migration.sql ...]
Simulates tomorrow 10:00 CDMX: owner 5 min alone, owner+guard until min 65, fallback
Sandy/BYG, owner==guard -> Sandy, typed "tomo". Prints PASS/FAIL per scenario; writes nothing.
"""
import json, sys, psycopg
from pathlib import Path
from psycopg.rows import dict_row
R = Path(r"C:/Users/esteb/Desktop/PROJECTS/Inmobiliaria24")
env = {}
for raw in (R / ".env").read_text(encoding="utf-8-sig").splitlines():
    if "=" in raw and not raw.lstrip().startswith("#"):
        k, v = raw.split("=", 1); env[k.strip()] = v.strip().strip('"').strip("'")
c = psycopg.connect(host=env["SUPABASE_DB_HOST"], port=env["SUPABASE_DB_PORT"], user=env["SUPABASE_DB_USER"],
                    password=env["SUPABASE_DB_PASSWORD"], dbname=env["SUPABASE_DB_NAME"], row_factory=dict_row)
one = lambda s, *a: c.execute(s, a).fetchone()
ok = True


def check(name, cond, got):
    global ok
    print(("PASS " if cond else "FAIL ") + name, json.dumps(got, default=str)[:300]); ok &= bool(cond)


for f in sys.argv[1:]:
    c.execute((R / f).read_text(encoding="utf-8"))
FR = '33628457768'
CAROL = '5215554311526'
n = [0]
# Simulate tomorrow 10:00 CDMX: every timestamp we create is shifted by OFF.
OFF = "((date_trunc('day', now() at time zone 'America/Mexico_City') + interval '1 day 10 hours') at time zone 'America/Mexico_City' - now())"
SHIFT = "'morning'"
DAY = f"((now()+{OFF}) at time zone 'America/Mexico_City')::date"


def deliver(a, w):
    c.execute("update lead_routing_delivery_attempts set provider_message_id=%s,status='sent' where attempt_id=%s", (w, a))
    c.execute("select record_delivery_callback(%s,'delivered',now(),'{}')", (w,))
    c.execute(f"update lead_routing_delivery_attempts set requested_at=requested_at+{OFF}, delivered_at=delivered_at+{OFF} where attempt_id=%s and requested_at<now()+interval '1 hour'", (a,))
    c.execute(f"update lead_routing_opportunities o set delivered_at=o.delivered_at+{OFF}, expires_at=case when o.expires_at<now()+interval '1 hour' then o.expires_at+{OFF} else o.expires_at end from lead_routing_delivery_attempts a where a.attempt_id=%s and o.opportunity_id=a.opportunity_id and o.current_delivery_attempt_id=a.attempt_id and o.delivered_at<now()+interval '1 hour'", (a,))


def mk(owner='agent_test_fr', num=FR):
    n[0] += 1; k = f"txtest{n[0]}"
    o = one("insert into lead_routing_opportunities(state,v3_enabled,property_id) values('resolved',true,'EB-TXTEST') returning opportunity_id")['opportunity_id']
    cap = one("""insert into i24_capture_events(account_key,source,happened_at,idempotency_key,disposition,contactado_status,opportunity_id,offer_context)
      values('default','inmuebles24',now(),%s,'created_new','verified',%s,'{}') returning capture_event_id""", k, o)['capture_event_id']
    a = one("select public.v3_request_offer(%s,'owner',%s,%s,%s) a", cap, 'tx:owner:' + k, owner, num)['a']
    deliver(a, 'wamid.' + k + 'o')
    return o, cap, a, 'wamid.' + k + 'o'


def inbox(frm, body=None, button=None, ctx=None):
    n[0] += 1; w = f"wamid.in{n[0]}"
    ev = {"id": w, "from": frm, "type": "text" if body else "button"}
    if body: ev["text"] = {"body": body}
    if button: ev["button"] = {"payload": button, "text": "Tomo"}
    if ctx: ev["context"] = {"id": ctx}
    return one(f"""insert into lead_routing_meta_webhook_inbox(idempotency_key,event_kind,wamid,sanitized_payload,payload_sha256,hmac_verified,created_at)
      values(%s,'message',%s,%s,md5(%s)||md5(%s),true,now()+{OFF}+interval '8 min') returning webhook_event_id""", 'tx' + w, w,
               json.dumps({"kind": "message", "event": ev, "wamid": w, "context_id": ctx}), w, w + 'b')['webhook_event_id']


def claim(*a, **k):
    return one("select public.claim_v3_delivery_from_webhook(%s) r", inbox(*a, **k))['r']


def sched(agent):
    c.execute(f"delete from agent_schedule where schedule_date={DAY} and shift={SHIFT} and coverage_role='primary'")
    if agent:
        c.execute(f"insert into agent_schedule(schedule_date,shift,agent_id,coverage_role) values({DAY},{SHIFT},%s,'primary')", (agent,))


c.execute("update agents set is_available=true where agent_id in ('agent_test_fr','agent_carol','agent_manager')")
def adv(o, t, m):
    r = one(f"select public.v3_advance_routing_tier(%s,%s,now()+{OFF}+make_interval(mins=>%s)) r", o, t, m)['r']
    if r.get('attempt_id'):
        c.execute(f"update lead_routing_delivery_attempts set requested_at=requested_at+{OFF} where attempt_id=%s and requested_at<now()+interval '1 hour'", (r['attempt_id'],))
    return r
st = lambda o: one(f"select state,routing_tier,assigned_agent_id,expires_at-(now()+{OFF}) exp,current_delivery_attempt_id cur from lead_routing_opportunities where opportunity_id=%s", o)
tgt = lambda a: one("select target_agent_id t from lead_routing_delivery_attempts where attempt_id=%s", a)['t']

# S1: owner open at 3; at 6 guard Carol offered; owner typed "Tomo" wins; Carol's late tap told.
sched('agent_carol')
o, cap, a, ow = mk()
check("S1 open at 3", adv(o, 'owner', 3)['state'] == 'open', st(o))
r = adv(o, 'owner', 6); check("S1 guard requested", r['state'] == 'guard_delivery_requested', r)
g = r['attempt_id']; check("S1 guard is carol", tgt(g) == 'agent_carol', tgt(g))
s = st(o); check("S1 expires ~65m", 64 * 60 < s['exp'].total_seconds() <= 65 * 60, s)
deliver(g, 'wamid.g1')
s = st(o); check("S1 guard delivered keeps shared expiry", s['state'] == 'primary_guard_open' and s['exp'].total_seconds() > 3600, s)
r = claim(FR, body='Tomo'); check("S1 owner typed tomo claims", r.get('outcome') == 'claimed' and r.get('assigned_agent_id') == 'agent_test_fr', r)
r = claim(CAROL, button=f"claim:v3:{o}:{g}", ctx='wamid.g1'); check("S1 guard late tap", r.get('outcome') == 'already_assigned_other', r)

# S2: guard button claim during shared hour; then owner button -> already_assigned_other
o, cap, a, ow = mk(); g = adv(o, 'owner', 6)['attempt_id']; deliver(g, 'wamid.g2')
r = claim(CAROL, button=f"claim:v3:{o}:{g}", ctx='wamid.g2'); check("S2 guard button claims", r.get('outcome') == 'claimed' and r['assigned_agent_id'] == 'agent_carol', r)
r = claim(FR, button=f"claim:v3:{o}:{a}", ctx=ow); check("S2 owner late button", r.get('outcome') == 'already_assigned_other', r)

# S2b: owner button AFTER guard offer still claims
o, cap, a, ow = mk(); g = adv(o, 'owner', 6)['attempt_id']; deliver(g, 'wamid.g2b')
r = claim(FR, button=f"claim:v3:{o}:{a}", ctx=ow); check("S2b owner button in shared hour", r.get('outcome') == 'claimed', r)

# S3: nobody claims -> open at 30, fallback at 66
o, cap, a, ow = mk(); adv(o, 'owner', 6); g = st(o)['cur']; deliver(g, 'wamid.g3')
check("S3 open at 30", adv(o, 'primary_guard', 30)['state'] == 'open', st(o))
r = adv(o, 'primary_guard', 66); exp_agent = one(f"select public.v3_fallback_agent(now()+{OFF}+interval '66 min') a")['a']
check("S3 fallback assigned", r['state'] == 'assigned' and st(o)['assigned_agent_id'] == exp_agent, [r, st(o)])
nt = one("select count(*) n from lead_routing_delivery_attempts where opportunity_id=%s and delivery_kind='assigned_notice' and target_agent_id=%s", o, exp_agent)['n']
check("S3 notice enqueued", nt == 1, nt)
v = one("select assignment_method,assigned_name from v3_leads_dashboard where opportunity_id=%s", o); check("S3 dashboard", v['assignment_method'] == 'sandy_fallback', v)

# S3b: guard offer never delivered -> open (not unassigned) at 10, fallback at 66
o, cap, a, ow = mk(); adv(o, 'owner', 6)
check("S3b undelivered guard waits", adv(o, 'primary_guard', 10)['state'] == 'open', st(o))
check("S3b fallback", adv(o, 'primary_guard', 66)['state'] == 'assigned', st(o))

# S4: owner == guard -> Sandy second
sched('agent_test_fr'); o, cap, a, ow = mk(); r = adv(o, 'owner', 6)
check("S4 owner==guard -> sandy", r['state'] == 'guard_delivery_requested' and tgt(r['attempt_id']) == 'agent_manager', r)

# S5: Sandy owner and guard -> no second, open until 65, fallback after
sched('agent_manager'); o, cap, a, ow = mk('agent_manager', '5215591970405'); r = adv(o, 'owner', 6)
check("S5 sandy owner+guard stays open", r['state'] == 'open' and st(o)['routing_tier'] == 'owner', [r, st(o)])
check("S5 fallback", adv(o, 'owner', 66)['state'] == 'assigned', st(o))

# S6: no guard -> Sandy second
sched(None); o, cap, a, ow = mk(); r = adv(o, 'owner', 6)
check("S6 no guard -> sandy", r['state'] == 'guard_delivery_requested' and tgt(r['attempt_id']) == 'agent_manager', r)

# S7: two open offers for FR -> ambiguous; Carol none open -> no_open_offer; quoted reply resolves
sched('agent_carol'); o1, _, _, ow1 = mk(); o2, _, _, ow2 = mk()
r = claim(FR, body='tomo'); check("S7 ambiguous", r.get('outcome') == 'ambiguous_text_claim', r)
r = claim(CAROL, body='tomo'); check("S7 no open offer", r.get('outcome') == 'no_open_offer', r)
r = claim(FR, body='tomo', ctx=ow1); check("S8 quoted tomo", r.get('outcome') == 'claimed' and r['opportunity_id'] == o1, r)
r = claim(FR, body='tomo nota'); check("S8b non-claim text ignored", r.get('outcome') == 'verified_webhook_mismatch', r)

# S10 (opp 1277): guard send fails -> owner offer stays claimable; nobody -> fallback at 66
sched('agent_carol')
for take in (True, False):
    o, cap, a, ow = mk(); g = adv(o, 'owner', 6)['attempt_id']
    one("select public.fallback_failed_owner_delivery(%s,'131000') r", g)
    s = st(o); check("S10 guard send failed keeps owner open", s['state'] == 'owner_open' and s['cur'] == a and s['exp'].total_seconds() > 3000, s)
    if take:
        r = claim(FR, button=f"claim:v3:{o}:{a}", ctx=ow); check("S10 owner still claims", r.get('outcome') == 'claimed', r)
    else:
        check("S10b fallback at 66", adv(o, 'owner', 66)['state'] == 'assigned' and st(o)['assigned_agent_id'] == exp_agent, st(o))

# S11: owner send fails, nothing delivered -> straight to Sandy/BYG
o = one("insert into lead_routing_opportunities(state,v3_enabled,property_id) values('resolved',true,'EB-TXTEST') returning opportunity_id")['opportunity_id']
cap = one("""insert into i24_capture_events(account_key,source,happened_at,idempotency_key,disposition,contactado_status,opportunity_id,offer_context)
  values('default','inmuebles24',now(),'txtest_s11','created_new','verified',%s,'{}') returning capture_event_id""", o)['capture_event_id']
a = one("select public.v3_request_offer(%s,'owner','tx:owner:s11','agent_test_fr',%s) a", cap, FR)['a']
one("select public.fallback_failed_owner_delivery(%s,'131000') r", a)
fb = one("select public.v3_fallback_agent(now()) a")['a']
check("S11 owner send failed -> fallback", st(o)['assigned_agent_id'] == fb, st(o))

# S12-S15 returning client (Marusa 16-oct): same email taken by Carol in the last 90 days.
def mk_lead(email, phone, portal, prev_days=None):
    n[0] += 1; k = f"txrc{n[0]}"
    if prev_days is not None:
        c.execute(f"""insert into lead_routing_opportunities(state,v3_enabled,property_id,normalized_email,e164_phone,assigned_agent_id,assigned_at)
          values('assigned',true,'EB-TXPREV',%s,%s,'agent_carol',now()+{OFF}-make_interval(days=>%s))""", (email, phone, prev_days))
    o = one("""insert into lead_routing_opportunities(state,v3_enabled,property_id,normalized_email,e164_phone,v3_offer_context)
      values('captured',true,'EB-TXNEW',%s,%s,jsonb_build_object('portal',%s::text)) returning opportunity_id""", email, phone, portal)['opportunity_id']
    cap = one("""insert into i24_capture_events(account_key,source,happened_at,idempotency_key,disposition,contactado_status,opportunity_id,offer_context)
      values('default','inmuebles24',now(),%s,'created_new','verified',%s,'{}') returning capture_event_id""", k, o)['capture_event_id']
    return o, one(f"select public.v3_route_ready_opportunity(%s,%s,ARRAY[]::text[],now()+{OFF}) r", o, cap)['r']
sched('agent_gina')
o, r = mk_lead('rc1@x.mx', '+525500000901', 'inmuebles24', 10)
nt = one("select count(*) n from lead_routing_delivery_attempts where opportunity_id=%s and delivery_kind='assigned_notice' and target_agent_id='agent_carol'", o)['n']
check("S12 returning client -> Carol direct", r.get('state') == 'direct_assigned' and st(o)['assigned_agent_id'] == 'agent_carol' and nt == 1, [r, st(o), nt])
v = one("select assignment_method from v3_leads_dashboard where opportunity_id=%s", o); check("S12 dashboard direct", v['assignment_method'] == 'direct', v)
o, r = mk_lead('rc2@x.mx', '+525500000902', 'MLS', 10)
check("S13 MLS broker -> normal offer", r.get('state') == 'guard_delivery_requested', [r, st(o)])
o, r = mk_lead('rc3@x.mx', '+525500000903', 'inmuebles24', 100)
check("S14 older than 90 days -> normal offer", r.get('state') == 'guard_delivery_requested', [r, st(o)])
byg = one("select whatsapp_number w from agents where agent_id='agent_manager_2'")['w']
o, r = mk_lead('rc4@x.mx', '+52' + ''.join(ch for ch in byg if ch.isdigit())[-10:], 'inmuebles24', 10)
check("S15 BYG own number -> normal offer", r.get('state') == 'guard_delivery_requested', [r, st(o)])

for ts, exp in [("2026-10-14 10:00", "agent_manager"), ("2026-10-14 08:59", "agent_manager_2"),
                ("2026-10-14 18:00", "agent_manager_2"), ("2026-10-17 11:00", "agent_manager_2")]:
    a_ = one("select public.v3_fallback_agent((%s::timestamp at time zone 'America/Mexico_City')) a", ts)['a']; check("S9 " + ts, a_ == exp, a_)
c.rollback(); print("ALL OK" if ok else "SOME FAILED")
