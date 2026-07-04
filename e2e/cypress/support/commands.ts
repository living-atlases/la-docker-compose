// Custom Cypress commands.
// Inspired by & adapted from inbo/vlaams-biodiversiteitsportaal (MPL-2.0):
//   https://github.com/inbo/vlaams-biodiversiteitsportaal
// vlaams logs in against Keycloak; this deployment uses CAS / OIDC, so the login flow and
// selectors differ (see cy.login below). Login is the most fragile part of the suite and is
// exercised only by the gated 8-auth spec.
import { serviceUrl, authUrl } from "./services";

declare global {
  // eslint-disable-next-line @typescript-eslint/no-namespace
  namespace Cypress {
    interface Chainable {
      /**
       * Log in through CAS/OIDC and cache the session. Defaults to the demo credentials
       * from CYPRESS_LADEMO_USERNAME / CYPRESS_LADEMO_PASSWORD.
       */
      login(username?: string, password?: string): Chainable<void>;
    }
  }
}

function loggedInAssertion(): void {
  // Robust "am I logged in?" check by UI state (a logout affordance appears), NOT by a
  // specific cookie name — the OIDC handshake crosses domains and hub session cookie names
  // are not stable across the ALA hubs.
  cy.get('a[href*="logout"], #logoutButton, .logout, [class*="logout"]', {
    timeout: 20000,
  }).should("exist");
}

Cypress.Commands.add(
  "login",
  (
    // Credentials come from the environment. In CI they are the CAS admin, read from the
    // inventory's local-passwords.ini (email var + the plaintext password the generator leaves
    // in a comment) and injected by the Jenkins E2E stage. Locally, export them yourself.
    username: string = Cypress.env("LADEMO_USERNAME"),
    password: string = Cypress.env("LADEMO_PASSWORD"),
  ): void => {
    if (!username || !password) {
      throw new Error(
        "login(): missing credentials. Set CYPRESS_LADEMO_USERNAME and " +
          "CYPRESS_LADEMO_PASSWORD (CI extracts the CAS admin from local-passwords.ini).",
      );
    }
    const authOrigin = new URL(authUrl()).origin; // e.g. https://auth.l-a.site

    cy.session(
      username,
      () => {
        // Start on a hub and trigger the login → redirects to CAS on the auth subdomain.
        cy.visit(serviceUrl("records"));
        // The login link sits in a collapsed Bootstrap auth dropdown (ul#dropdown-auth-menu.signedOut,
        // display:none). Reveal it with jQuery .show() so the anchor is genuinely visible and a plain
        // click performs a NATIVE navigation to CAS. A forced click on a display:none anchor dispatches
        // the click event but does not reliably trigger the browser's default navigation — that was the
        // #268 failure, where cy.origin(auth) ran while the app was still on records.l-a.site.
        // cy.get retries until the auth menu renders, so this survives a late-loading navbar.
        cy.get("#dropdown-auth-menu", { timeout: 20000 }).invoke("show");
        // Scope to the real login anchor (href points at /login), not the dropdown toggle that a
        // broad [class*="login"] match could grab first.
        cy.get(
          'a.loginBtn[href*="/login"], a[href*="/cas/login"], a[href*="/login"]',
        )
          .filter(":visible")
          .first()
          .click();

        // On the CAS origin: fill the CAS 6.x login form and submit.
        cy.origin(
          authOrigin,
          { args: { username, password } },
          ({ username, password }) => {
            cy.get("#username", { timeout: 20000 }).type(username);
            cy.get("#password").type(password, { log: false });
            cy.get(
              'button[name="submit"], input[name="submit"], button[type="submit"], .mdc-button, #loginButton',
            )
              .first()
              .click();
          },
        );

        // Back on the hub (OIDC callback completed): confirm logged-in UI state.
        loggedInAssertion();
      },
      {
        validate: () => {
          cy.visit(serviceUrl("records"));
          loggedInAssertion();
        },
      },
    );
  },
);

export {};
