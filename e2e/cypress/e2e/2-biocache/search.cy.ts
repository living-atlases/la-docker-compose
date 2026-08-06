import { serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// Biocache: the occurrence record store. Generic query (q=*:*) so it works against any
// inventory's data. Checks both the web service (JSON) and the hub (rendered search page).
describe("Biocache occurrence search", () => {
  before(function () {
    skipIfMissing("records", this);
  });

  it("records-ws returns occurrences for a generic query", () => {
    const url = serviceUrl("recordsWs", "/occurrences/search?q=*:*&pageSize=0");
    apiOk(url);
    cy.request({ url, failOnStatusCode: false }).then((resp) => {
      // Body shape is stable across LA: totalRecords present and numeric.
      expect(resp.body, "occurrence search body").to.have.property("totalRecords");
      expect(resp.body.totalRecords, "totalRecords").to.be.a("number");
    });
  });

  it("records hub renders the search results page", () => {
    const hubUrl = serviceUrl("records", "/occurrences/search?q=*:*");
    // Fetch before visiting so a 5xx reports the hub's OWN error page instead of dying
    // inside cy.visit with a bare status code. The hub 500s right after a deploy and
    // recovers later; without the body there is nothing to root-cause from a CI run.
    // Same idea as assertDownloadAccepted in support/downloads.ts.
    cy.request({ url: hubUrl, failOnStatusCode: false }).then((resp) => {
      expect(
        resp.status,
        `GET ${hubUrl} — first 500 chars of the response: ` +
          `${String(resp.body).replace(/\s+/g, " ").slice(0, 500)}`
      ).to.be.lessThan(400);
    });
    cy.visit(hubUrl);
    pageRenders();
    // Results UI present (tolerant to hub markup differences).
    cy.get("#results, .results, [class*='result'], #totalRecords, .totalRecords", {
      timeout: 20000,
    }).should("exist");
  });
});
