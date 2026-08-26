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
      /**
       * Log in against ONE specific hub and cache that hub's session.
       *
       * cy.login() logs in on the records hub. It does NOT give you the other hubs: the CAS
       * ticket-granting cookie is not among the cookies cy.session restores (verified by
       * dumping the auth-origin cookie jar after a successful login -- only i18next, SESSION
       * and the locale cookie survive), so a later visit to collections/species/regions
       * starts a fresh OIDC handshake, finds no SSO session and lands on the CAS login form.
       *
       * Use this whenever a spec needs an authenticated page on a hub other than records.
       */
      loginTo(
        serviceKey: string,
        protectedPath?: string,
        username?: string,
        password?: string,
      ): Chainable<void>;
    }
  }
}

/**
 * The ALA admin/CAS GSPs load Bootstrap's JS before jQuery and throw on load
 * ("Bootstrap's JavaScript requires jQuery", "jQuery is not defined", "$ is not defined").
 * Cypress fails a test on any uncaught application exception, so those pages are unusable
 * without ignoring exactly these three messages -- and nothing else, so a genuine application
 * error still fails the test instead of being swallowed into a false green.
 */
export function isMissingJqueryError(message: string): boolean {
  return (
    /(^|\s)(jQuery|\$) is not defined/.test(message) ||
    /Bootstrap's JavaScript requires jQuery/.test(message)
  );
}

/**
 * Register the ignore inside a cy.session setup/validate callback.
 *
 * `Cypress.on(...)` in a spec file does NOT reach into cy.session callbacks -- verified the
 * hard way: with the handler registered at spec level, session validation still died on
 * "Bootstrap's JavaScript requires jQuery". `cy.on` binds to the running context and does.
 */
function ignoreMissingJqueryHere(): void {
  cy.on("uncaught:exception", (err) => !isMissingJqueryError(err.message));
}

/**
 * Assert we are really signed in on `serviceKey`, by asking for a page the hub protects.
 *
 * This replaced a UI-state check ("a logout affordance appears"), which was a false positive:
 * the ALA navbar renders `href="…/logout"` whether or not anyone is signed in. Fetching the
 * hub root with no session at all still satisfied it, which is how a login command that never
 * logged in stayed green.
 *
 * A protected path cannot be faked: signed in it answers 200, signed out it 302s to CAS.
 * Requested rather than visited so the redirect survives to be inspected, and so these pages'
 * broken JavaScript (Bootstrap before jQuery) cannot fail the check for unrelated reasons.
 */
function loggedInAssertion(serviceKey: string, protectedPath = "/alaAdmin"): void {
  cy.request({
    url: serviceUrl(serviceKey, protectedPath),
    followRedirect: false,
    failOnStatusCode: false,
  })
    .its("status")
    .should("eq", 200);
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
        // Start on a hub, assert it offers a login link, then FOLLOW that link by URL.
        //
        // It used to reveal the collapsed Bootstrap dropdown with jQuery .show() and click
        // the anchor, relying on the click producing a NATIVE cross-origin navigation. That
        // chain has now broken twice the same way — #268, and again from #341 — always with
        // "expected to run against origin auth.l-a.site but the application is at origin
        // records.l-a.site", i.e. the click landed but the browser never left the hub. The
        // server side was fine both times: following the anchor's href by hand ends on
        // https://auth.l-a.site/cas/login?service=... after 2 redirects, HTTP 200.
        //
        // Reading the href and visiting it exercises the identical server-side flow
        // (hub /login?path=… -> CAS oidcAuthorize -> CAS login form) and keeps the real
        // coverage — that the signed-out navbar renders a login link pointing at /login —
        // as an explicit assertion, without depending on dropdown visibility or on the
        // browser's default click action.
        cy.visit(serviceUrl("records"));
        cy.get('#dropdown-auth-menu a.loginBtn[href*="/login"]', {
          timeout: 20000,
        })
          .should("have.attr", "href")
          .then((href) => {
            // Relative in the rendered markup (href="/login?path=…"), so resolve it
            // against the hub before visiting.
            cy.visit(new URL(String(href), serviceUrl("records")).toString());
          });

        // On the CAS origin: fill the CAS 6.x login form and submit.
        cy.origin(
          authOrigin,
          { args: { username, password } },
          ({ username, password }) => {
            // Scope EVERYTHING to the CAS form (#fm1).
            //
            // The old selector was an unscoped union ending in `.first()`, and cy.get returns
            // matches in document order. The CAS login page is wrapped in the portal's
            // branding, whose navbar carries
            //     <form action="https://species.l-a.site/search"> <button type="submit">
            // which appears BEFORE the login form. So `.first()` clicked the navbar's search
            // button and submitted a search: the browser left for species.l-a.site/search?q=
            // and no session was ever created. It looked like a login because the navbar
            // renders a logout link whether or not anyone is signed in.
            //
            // The real control is <input name="submit" type="submit" value="Login"> inside
            // <form method="post" id="fm1">.
            cy.get("#fm1", { timeout: 20000 }).within(() => {
              cy.get("#username").type(username);
              cy.get("#password").type(password, { log: false });
              cy.get('[name="submit"], input[type="submit"], button[type="submit"]')
                .first()
                .click();
            });
          },
        );

        // Back on the hub: confirm the OIDC callback really produced a session.
        loggedInAssertion("records");
      },
      {
        validate: () => {
          loggedInAssertion("records");
        },
      },
    );
  },
);

Cypress.Commands.add(
  "loginTo",
  (
    serviceKey: string,
    // Path used to VALIDATE the cached session. It must be a page the hub protects, because
    // a public page renders the same signed out and would keep a dead session alive.
    protectedPath = "/alaAdmin/viewConfig",
    username: string = Cypress.env("LADEMO_USERNAME"),
    password: string = Cypress.env("LADEMO_PASSWORD"),
  ): void => {
    if (!username || !password) {
      throw new Error(
        "loginTo(): missing credentials. Set CYPRESS_LADEMO_USERNAME and " +
          "CYPRESS_LADEMO_PASSWORD (CI extracts the CAS admin from local-passwords.ini).",
      );
    }
    const authOrigin = new URL(authUrl()).origin;
    const hubOrigin = new URL(serviceUrl(serviceKey)).origin;

    cy.session(
      [username, serviceKey],
      () => {
        // Land on the hub first, THEN follow its /login endpoint. Going straight at /login
        // as the first visit makes cy.origin fail its location validation, the same class of
        // breakage cy.login hit in #268 and #341. Establishing the hub origin first and
        // letting /login produce the cross-origin navigation is the shape that works.
        //
        // /login rather than the navbar link: every ALA Grails hub exposes it (it is what the
        // navbar's loginBtn points at) and it 302s to CAS oidcAuthorize on all four audited
        // hubs, so this works uniformly without depending on each hub's navbar markup.
        // cy.login keeps the navbar route because asserting that link exists is its coverage.
        ignoreMissingJqueryHere();
        cy.visit(serviceUrl(serviceKey, "/"));
        cy.visit(serviceUrl(serviceKey, "/login?path=%2F"));

        cy.origin(
          authOrigin,
          { args: { username, password } },
          ({ username, password }) => {
            // The CAS login page loads Bootstrap's JS before jQuery and throws
            // "ReferenceError: jQuery is not defined". Cypress fails a test on any uncaught
            // application exception, and a handler registered in the spec does NOT reach
            // inside cy.origin -- it has to be registered here, in the origin's own context.
            // Narrow match: any other application error must still fail the login.
            cy.on("uncaught:exception", (err) =>
              !/(^|\s)(jQuery|\$) is not defined/.test(err.message),
            );

            // Scope EVERYTHING to the CAS form (#fm1).
            //
            // The old selector was an unscoped union ending in `.first()`, and cy.get returns
            // matches in document order. The CAS login page is wrapped in the portal's
            // branding, whose navbar carries
            //     <form action="https://species.l-a.site/search"> <button type="submit">
            // which appears BEFORE the login form. So `.first()` clicked the navbar's search
            // button and submitted a search: the browser left for species.l-a.site/search?q=
            // and no session was ever created. It looked like a login because the navbar
            // renders a logout link whether or not anyone is signed in.
            //
            // The real control is <input name="submit" type="submit" value="Login"> inside
            // <form method="post" id="fm1">.
            cy.get("#fm1", { timeout: 20000 }).within(() => {
              cy.get("#username").type(username);
              cy.get("#password").type(password, { log: false });
              cy.get('[name="submit"], input[type="submit"], button[type="submit"]')
                .first()
                .click();
            });
          },
        );

        // Only assert that we LEFT the auth origin. Where a hub sends you after login is a
        // deployment decision, not this command's business: collectory lands on
        // species.l-a.site/search here, because the plugin's post-login redirect goes to the
        // portal root and the root serves the species hub. Asserting the hub origin instead
        // failed for a deployment that was working perfectly.
        cy.location("origin", { timeout: 30000 }).should("not.eq", authOrigin);
      },
      {
        validate: () => {
          // Validate with a REQUEST against a protected path, not a page visit.
          //
          // Two reasons. It has to be a protected path, because a public page renders the
          // same signed out and would keep a dead session cached. And it has to be a request,
          // because rendering these admin pages throws "Bootstrap's JavaScript requires
          // jQuery" and Cypress fails session validation on the uncaught exception -- neither
          // Cypress.on in the spec nor cy.on inside this callback suppresses it, both tried.
          // A request loads no JavaScript, so the question stays "is the session alive"
          // instead of "does the page's JavaScript happen to work".
          cy.request({
            url: serviceUrl(serviceKey, protectedPath),
            followRedirect: false,
            failOnStatusCode: false,
          })
            .its("status")
            .should("eq", 200); // 302 here means the session is gone and CAS wants us back
        },
      },
    );
  },
);

export {};
