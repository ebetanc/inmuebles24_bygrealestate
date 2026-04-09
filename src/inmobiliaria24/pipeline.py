"""Lead processing pipeline.

Orchestrates the flow: scraped leads → dedup → CRM duplicate check →
push to CRM → mark in state DB. Decouples scraping from delivery.
"""
from __future__ import annotations

from loguru import logger

from inmobiliaria24.crm.base import CRMAdapter, Lead
from inmobiliaria24.state import StateStore


async def process_leads(
    raw_leads: list[dict],
    store: StateStore,
    crm: CRMAdapter,
) -> tuple[list[Lead], list[Lead]]:
    """Process scraped leads through the full pipeline.

    Returns (all_leads, new_leads) where new_leads are the ones
    that were actually pushed to the CRM.
    """
    if not raw_leads:
        logger.info("Pipeline: no leads to process")
        return [], []

    # Convert to Lead objects.
    all_leads = [Lead.from_scraped(d) for d in raw_leads]

    # Dedup against local state.
    new_raw = store.filter_new(raw_leads)
    new_leads = [Lead.from_scraped(d) for d in new_raw]

    if not new_leads:
        logger.info("Pipeline: all {} leads already seen — nothing to push", len(all_leads))
        store.mark_seen(raw_leads)
        return all_leads, []

    # Mark all leads as seen before CRM push so mark_crm_pushed can update them.
    store.mark_seen(raw_leads)

    # Push new leads to CRM.
    pushed: list[Lead] = []
    for lead in new_leads:
        try:
            # Check CRM-side duplicates (by email/phone).
            existing_crm_id = await crm.check_duplicate(lead.email, lead.phone)
            if existing_crm_id:
                logger.info(
                    "Lead {} already in CRM (crm_id={}), skipping push",
                    lead.lead_id, existing_crm_id,
                )
                lead.crm_id = existing_crm_id
                lead.crm_pushed = True
                store.mark_crm_pushed(lead.lead_id, crm_id=existing_crm_id)
                pushed.append(lead)
                continue

            crm_id = await crm.push_lead(lead)
            lead.crm_id = crm_id
            lead.crm_pushed = True
            store.mark_crm_pushed(lead.lead_id, crm_id=crm_id)
            pushed.append(lead)
            logger.info("Lead {} pushed to CRM (crm_id={})", lead.lead_id, crm_id)

        except Exception as e:
            logger.error("Failed to push lead {} to CRM: {}", lead.lead_id, e)
            # Lead stays in unpushed state — will be retried next run.

    logger.info(
        "Pipeline: {} total, {} new, {} pushed to CRM",
        len(all_leads), len(new_leads), len(pushed),
    )
    return all_leads, pushed


async def retry_failed_pushes(store: StateStore, crm: CRMAdapter) -> int:
    """Retry pushing leads that were seen but failed CRM push.

    Returns the number of successfully retried pushes.
    """
    unpushed = store.get_unpushed_leads()
    if not unpushed:
        return 0

    logger.info("Retrying {} unpushed leads", len(unpushed))
    success = 0
    for row in unpushed:
        lead = Lead(
            lead_id=row["lead_id"],
            listing_id=row.get("listing_id", ""),
            name=row.get("name", ""),
            source_tab=row.get("source_tab", ""),
        )
        try:
            crm_id = await crm.push_lead(lead)
            store.mark_crm_pushed(lead.lead_id, crm_id=crm_id)
            success += 1
        except Exception as e:
            logger.warning("Retry failed for lead {}: {}", lead.lead_id, e)

    logger.info("Retry complete: {}/{} succeeded", success, len(unpushed))
    return success
