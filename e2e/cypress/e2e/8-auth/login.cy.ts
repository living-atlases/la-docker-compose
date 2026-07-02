import { serviceUrl } from "../../support/services";

// GATED spec: CAS/OIDC login. Off by default (login is the most fragile flow and needs demo
// credentials). Enable with CYPRESS_ENABLE_AUTH_TESTS=true plus CYPRESS_LADEMO_USERNAME /
// CYPRESS_LADEMO_PASSWORD (a Jenkins secret in CI). See cy.login in support/commands.ts.
describe("Authentication (CAS/OIDC)", () => {
  before(function () {
    if (Cypress.env("ENABLE_AUTH_TESTS") !== "true") {
      this.skip();
    }
  });

  it("logs in through CAS and lands back logged-in on the records hub", () => {
    cy.login();
    cy.visit(serviceUrl("records"));
    cy.get('a[href*="logout"], #logoutButton, .logout, [class*="logout"]', {
      timeout: 20000,
    }).should("exist");
  });
});
