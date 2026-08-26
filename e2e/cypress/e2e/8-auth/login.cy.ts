import { serviceUrl, hasService } from "../../support/services";
import { authTestsEnabled } from "../../support/checks";

// GATED spec: CAS/OIDC login. Off by default (login is the most fragile flow and needs demo
// credentials). Enable with CYPRESS_ENABLE_AUTH_TESTS=true plus CYPRESS_LADEMO_USERNAME /
// CYPRESS_LADEMO_PASSWORD (a Jenkins secret in CI). See cy.login in support/commands.ts.
describe("Authentication (CAS/OIDC)", () => {
  before(function () {
    if (!authTestsEnabled()) {
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
  // HOLLOW BEFORE, DO NOT REVERT. This used to be:
  //     cy.login(); cy.visit(collections/admin);
  //     cy.get("h1").should("exist");
  //     cy.contains("ROLE_ADMIN is required").should("not.exist");
  // and it passed on the CAS LOGIN PAGE. Verified by fetching the page directly: when
  // collectory bounces an unauthorised request to CAS, the login page it serves contains
  // `<h1 class="hidden">Welcome the Atlas of Living Australia` and does not contain the
  // string "ROLE_ADMIN is required" -- so both assertions held while the admin tools were
  // completely unreachable. The regression guard was passing over the very regression it
  // was written to catch.
  //
  // Rewritten to ask the only question that distinguishes the two: does /admin answer 200
  // by itself, or does it 302 to the auth server? A request, not a visit, because the
  // redirect is what carries the answer and following it destroys the evidence.
  it("admin retains ROLE_ADMIN — collectory admin tools are accessible", function () {
    if (!hasService("collections")) {
      this.skip();
    }
    cy.loginTo("collections", "/admin");
    cy.request({
      url: serviceUrl("collections", "/admin"),
      followRedirect: false,
      failOnStatusCode: false,
    }).then((resp) => {
      expect(
        resp.status,
        "collectory /admin with an authenticated admin session. A 302 to the auth server " +
          "means the token carries no ROLE_ADMIN and the hub is bouncing the admin back to " +
          "CAS, which is what this guard exists to detect.",
      ).to.eq(200);
      expect(String(resp.body || "")).to.not.contain("ROLE_ADMIN is required");
    });
  });
});
