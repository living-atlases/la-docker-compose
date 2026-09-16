// Helpers for the species-list mutation spec (6-lists/manage.cy.ts).
//
// Inspired by & adapted from inbo/vlaams-biodiversiteitsportaal (MPL-2.0):
//   https://github.com/inbo/vlaams-biodiversiteitsportaal
// Specifically test/cypress/support/utils.ts (getTestOccurrenceCsv/TEST_LIST_PREFIX) and
// test/cypress/e2e/5-species-list/manage.cy.ts, which upload the same shape of CSV through
// the same specieslist-webapp Upload form (both are Living Atlases deployments running the
// same upstream service). Adapted for this deployment: a STABLE (non-timestamped) list name
// instead of Flanders' per-run timestamp, because this suite seeds a list that Gatus's
// "lists count" Data check depends on staying present — Flanders creates and deletes within
// the same run, we deliberately don't delete (see manage.cy.ts for why).

/** A single-row occurrence CSV the specieslist-webapp Upload form can parse into one taxon. */
export function getTestOccurrenceCsv(scientificName: string): string {
  const occurrenceId = `E2E:${scientificName.replace(/\s+/g, "_")}:${Date.now()}`;
  return (
    `"scientificName","eventDate","decimalLatitude","decimalLongitude","occurrenceID"\n` +
    `"${scientificName}","2026-01-01T00:00:00+00:00",0,0,"${occurrenceId}"`
  );
}

// Stable on purpose (no timestamp): the mutation spec looks for a list with exactly this
// name before creating one, so repeated CI runs converge on a single seeded list instead of
// accumulating a new one per build.
export const TEST_LIST_NAME = "E2E seeded test list";

// A broad, stable genus name — same reasoning as 3-species/search.cy.ts's "Acacia" query.
export const TEST_LIST_SCIENTIFIC_NAME = "Acacia";
