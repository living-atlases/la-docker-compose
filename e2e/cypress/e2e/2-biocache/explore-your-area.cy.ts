import { serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// Explore your area lists the species recorded around a point, with their common names.
// The hub only renders the `commonName` that biocache-service returns from
// /explore/group, which in turn comes from the names_and_lsid field written at ingest.
//
// With a COL name index the taxon IDs are alphanumeric (8P4G, 34WN9). Older stacks lost
// the common name for those IDs: ala-name-matching 3.x lowercased the LSID in the
// language-filtered lookup (biocache-store with commonname.lang set), so only numeric
// GBIF keys ever matched and every COL taxon showed "[Not supplied]". This spec picks a
// real record that carries a common name and checks the name survives all the way to
// the page, whatever the ID looks like.

type ExploreEntry = { name: string; commonName: string; guid: string };
type Probe = { lat: number; lon: number; guid: string; vernacular: string };

const probeUrl = () =>
  serviceUrl(
    "recordsWs",
    "/occurrences/search?q=*:*&fq=vernacularName:*&fq=decimalLatitude:*&pageSize=1"
  );

const exploreUrl = (p: Probe, radius: number | string) =>
  serviceUrl(
    "recordsWs",
    `/explore/group/ALL_SPECIES?q=*:*&lat=${p.lat}&lon=${p.lon}&radius=${radius}` +
      `&pageSize=500&includeRank=false`
  );

// A record with coordinates and a common name, or null on an index without one.
function findProbe(): Cypress.Chainable<Probe | null> {
  return cy.request({ url: probeUrl(), failOnStatusCode: false }).then((resp) => {
    const occ = resp.body?.occurrences?.[0];
    const probe: Probe | null =
      occ?.taxonConceptID && occ?.vernacularName
        ? {
            lat: occ.decimalLatitude,
            lon: occ.decimalLongitude,
            guid: occ.taxonConceptID,
            vernacular: occ.vernacularName,
          }
        : null;
    return cy.wrap(probe);
  });
}

describe("Explore your area", () => {
  before(function () {
    skipIfMissing("recordsWs", this);
  });

  it("explore/group returns the common name of the taxa around a record", () => {
    apiOk(probeUrl());
    findProbe().then((p) => {
      if (!p) {
        cy.log("no georeferenced record with a common name — nothing to check");
        return;
      }
      cy.request({ url: exploreUrl(p, 1), failOnStatusCode: false }).then((resp) => {
        expect(resp.status, `GET ${exploreUrl(p, 1)}`).to.eq(200);
        const entries: ExploreEntry[] = resp.body;
        const entry = entries.find((e) => e.guid === p.guid);
        expect(entry, `taxon ${p.guid} listed around its own record`).to.exist;
        expect(
          entry!.commonName,
          `common name of ${p.guid} lost in explore/group (the record has "${p.vernacular}")`
        ).to.not.be.empty;
      });
    });
  });

  it("the hub page renders the same common names as the web service", function () {
    skipIfMissing("records", this);
    findProbe().then((p) => {
      if (!p) {
        cy.log("no georeferenced record with a common name — nothing to check");
        return;
      }
      // Hash format read by exploreYourArea.js: lat|lng|zoom|speciesGroup.
      cy.visit(serviceUrl("records", `/explore/your-area#${p.lat}|${p.lon}|14|ALL_SPECIES`));
      pageRenders();
      cy.get("#rightList tbody tr", { timeout: 30000 }).should("have.length.greaterThan", 0);

      // Compare against the service with the radius the page actually used.
      cy.get("select#radius")
        .invoke("val")
        .then((radius) => {
          cy.request({ url: exploreUrl(p, String(radius)), failOnStatusCode: false }).then(
            (resp) => {
              const byGuid = new Map<string, ExploreEntry>(
                (resp.body as ExploreEntry[]).map((e) => [e.guid, e])
              );
              cy.get("#rightList tbody tr a.taxonBrowse2").each(($a) => {
                const expected = byGuid.get($a.attr("id") ?? "");
                if (!expected?.commonName) return;
                const shown = $a.closest("tr").find("td.sciName").first().text().trim();
                expect(shown, `common name shown for ${expected.guid}`).to.eq(
                  expected.commonName.trim()
                );
              });
            }
          );
        });
    });
  });
});
