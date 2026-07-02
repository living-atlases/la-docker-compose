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
    // Defaults to the seeded demo/demo account (roles/la-compose/tasks/init-e2e-user.yml).
    // Override via CYPRESS_LADEMO_USERNAME / CYPRESS_LADEMO_PASSWORD if the deployment uses
    // a different e2e user.
    username: string = Cypress.env("LADEMO_USERNAME") || "demo@l-a.site",
    password: string = Cypress.env("LADEMO_PASSWORD") || "demo",
  ): void => {
    const authOrigin = new URL(authUrl()).origin; // e.g. https://auth.l-a.site

    cy.session(
      username,
      () => {
        // Start on a hub and trigger the login → redirects to CAS on the auth subdomain.
        cy.visit(serviceUrl("records"));
        cy.get(
          'a[href*="/cas/login"], a[href*="login"], #loginButton, .loginBtn, [class*="login"]',
        )
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
