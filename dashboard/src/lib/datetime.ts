// Single source of truth for time in the dashboard: EVERYTHING is displayed and
// bucketed in Ciudad de México time, regardless of where the server (Vercel =
// UTC) or the viewer's browser runs.
//
// Mexico abolished nationwide DST in 2022, so America/Mexico_City is a fixed
// UTC-6 year-round. We still pass the IANA zone to Intl (not a hardcoded offset)
// so formatting stays correct if that ever changes.
export const MX_TZ = "America/Mexico_City";

/** Format an instant in CDMX time. Pass any Intl.DateTimeFormat options. */
export function formatMx(
  value: string | number | Date,
  opts: Intl.DateTimeFormatOptions,
): string {
  return new Date(value).toLocaleString("es-MX", { timeZone: MX_TZ, ...opts });
}

/** Today's date in CDMX as "YYYY-MM-DD" (for date-column queries / day buckets). */
export function mxToday(): string {
  // en-CA renders ISO YYYY-MM-DD.
  return new Date().toLocaleDateString("en-CA", { timeZone: MX_TZ });
}

/** The UTC instant of CDMX local midnight today (for created_at >= comparisons). */
export function mxStartOfToday(): Date {
  // -06:00 = CDMX fixed offset (no DST). Anchored to the CDMX calendar date.
  return new Date(`${mxToday()}T00:00:00-06:00`);
}
