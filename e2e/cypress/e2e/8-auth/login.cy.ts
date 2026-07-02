import { serviceUrl, hasService } from "../../support/services";

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

  // Regression guard for ROLE_ADMIN release over OIDC. The login must request the `ala roles`
  // scope so CAS releases the role/authority claims; otherwise collectory (>=6.0.0, whose
  // ala-auth plugin no longer defaults the OIDC scope to include ala/roles) shows
  // "You do not have access to admin tools. ROLE_ADMIN is required." for the admin.
  // Root cause: ala-install collectory `security.oidc.scope` was rendered only inside the
  // cognito block, and the generator never emitted `scope`. Fixed in generator v1.8.27
  // (webservice scopes + `scope` var) and ala-install (render security.oidc.scope for CAS).
  it("admin retains ROLE_ADMIN — collectory admin tools are accessible", function () {
    if (!hasService("collections")) {
      this.skip();
    }
    cy.login();
    cy.visit(serviceUrl("collections", "/admin"));
    // admin page shell rendered (heading present)
    cy.get("h1", { timeout: 25000 }).should("exist");
    // with ROLE_ADMIN released, the access error must NOT be present
    cy.contains("ROLE_ADMIN is required").should("not.exist");
  });
});
