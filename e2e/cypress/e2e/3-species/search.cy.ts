import { serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// BIE (species information). "Acacia" is a broad genus present in virtually any LA index, so
// the query is data-robust without asserting exact counts.
describe("Species (BIE) search", () => {
  before(function () {
    skipIfMissing("species", this);
  });

  it("species-ws answers a name search", () => {
    apiOk(serviceUrl("speciesWs", "/search?q=Acacia"));
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
