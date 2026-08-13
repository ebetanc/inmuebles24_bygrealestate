# Routing V2 contract fixtures

No production data is stored here. The capture script returns allowlisted schema
metadata and four server-derived booleans only; function source is never returned.
Contract tests strip SQL comments, extract the dollar-quoted body of each exact
`CREATE OR REPLACE FUNCTION`, and scope assertions to that body or one exact
`UPDATE`/`CREATE UNIQUE INDEX` statement. A comment, unrelated function, or inert
column cannot satisfy them.

| Scenarios | Required behavior | Implementation source | Owner ticket |
| --- | --- | --- | --- |
| S-01 | `delivered` opens owner tier and sets `expires_at = delivered_at + 5 minutes` | `0021_lead_routing_v2.sql` | LRV2-003/LRV2-008 |
| S-02, S-03 | Partial unique active identity on `(identity_key, property_id)` | `0021_lead_routing_v2.sql` | LRV2-003/LRV2-006 |
| S-04 | CDMX `08 <= hour < 20`; 08:05 drain claims locked pending rows once | `0023_routing_business_time.sql` | LRV2-005 |
| S-05–S-07 | `owner` -> primary -> backup -> unassigned alert; never manager assignment | `0027_advance_routing_tier.sql` | LRV2-010 |
| S-08, S-09 | One assignment `UPDATE` validates tier, authorization, delivery, expiry and unassigned state; explicit reject branch emits late event without assignment mutation | `0026_claim_lead_opportunity.sql` | LRV2-009 |
| S-10 | Delivery failure emits event and never writes SLA timestamps | `0021_lead_routing_v2.sql` | LRV2-003/LRV2-008 |
| S-11 | `resolve_first_property_tag` uses only `p_tags[1]`, returns explicit invalid-owner reasons, and dedicated `route_missing_owner_data` opens primary without manager assignment | `0025_resolve_first_property_tag.sql` | LRV2-007 |
| S-12 | No portal ID, email, or E.164 creates `manual_non_deduplicable` with reason | `0024_upsert_lead_opportunity.sql` | LRV2-006 |
| S-13, S-14 | Explicit stubs only; no green assertion in LRV2-002 | `0028_routing_safe_mode.sql` (future) | LRV2-013 |

Expected before implementation: eight clear `missing routing-v2 implementation` failures
for S-01 through S-12. S-13/S-14 remain mapped to LRV2-013 and are not claimed green.
Tests import no application/integration modules and open no database connection.
