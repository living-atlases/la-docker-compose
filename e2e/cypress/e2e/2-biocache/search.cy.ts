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
    cy.visit(serviceUrl("records", "/occurrences/search?q=*:*"));
    pageRenders();
    // Results UI present (tolerant to hub markup differences).
    cy.get("#results, .results, [class*='result'], #totalRecords, .totalRecords", {
      timeout: 20000,
    }).should("exist");
  });
});
