import { serviceUrl } from "../../support/services";
import { apiOk, pageRenders, skipIfMissing } from "../../support/checks";

// Collectory (data resources / institutions registry).
describe("Collections (collectory)", () => {
  before(function () {
    skipIfMissing("collections", this);
  });

  it("collectory ws responds", () => {
    apiOk(serviceUrl("collections", "/ws"));
  });

  it("collections home renders", () => {
    cy.visit(serviceUrl("collections", "/"));
    pageRenders();
    cy.get("body").invoke("text").its("length").should("be.greaterThan", 50);
  });
});
