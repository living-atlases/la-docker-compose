import { serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// Species lists.
describe("Species lists", () => {
  before(function () {
    skipIfMissing("lists", this);
  });

  it("species-list ws responds", () => {
    apiOk(serviceUrl("lists", "/ws/speciesList"));
  });

  it("lists home renders", () => {
    cy.visit(serviceUrl("lists", "/"));
    pageRenders();
    cy.get("body").invoke("text").its("length").should("be.greaterThan", 50);
  });
});
