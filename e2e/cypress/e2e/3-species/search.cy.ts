import { serviceUrl } from "../../support/services";
import { apiOk, bieHasData, pageRenders, skipIfMissing } from "../../support/checks";

// BIE (species information). "Acacia" is a broad genus present in virtually any LA index, so
// the query is data-robust without asserting exact counts.
describe("Species (BIE) search", () => {
  before(function () {
    skipIfMissing("species", this);
  });

  it("species-ws answers a name search", () => {
    apiOk(serviceUrl("speciesWs", "/search?q=Acacia"));
  });

  // Status alone says nothing here: an empty bie index answers 200 with
  // `{"searchResults":{"totalRecords":0,...}}`, so the assertion above passed for as long
  // as the index had never been populated. Gated because an empty index IS a legitimate
  // deployment; the CI sets CYPRESS_BIE_HAS_DATA only after the taxonomy import ran.
  it("species-ws returns taxa once a taxonomy has been imported", function () {
    if (!bieHasData()) {
      this.skip();
    }
    cy.request(serviceUrl("speciesWs", "/search?q=Acacia&pageSize=0")).then((resp) => {
      expect(resp.body?.searchResults?.totalRecords, "Acacia taxa in the bie index")
        .to.be.greaterThan(0);
    });
  });

  it("species hub renders the search page without a server error", () => {
    cy.visit(serviceUrl("species", "/search?q=Acacia"));
    pageRenders();
    // Either results are shown, or an explicit "no results" — both are valid, non-error UIs.
    cy.get("body")
      .invoke("text")
      .should((text) => {
        expect(text.length, "rendered species page text").to.be.greaterThan(50);
      });
  });
});
