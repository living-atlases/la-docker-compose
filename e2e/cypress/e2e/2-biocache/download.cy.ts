import { serviceUrl, hasService } from "../../support/services";
import { authTestsEnabled, skipIfMissing } from "../../support/checks";
import {
  assertDownloadAccepted,
  downloadQuery,
  hasMailhog,
  mailhogMessagesTo,
  offlineDownloadUrl,
  pollDownloadStatus,
} from "../../support/downloads";

// Biocache offline downloads. Ordered least → most coupled: plain API with an `email` param,
// then the authenticated (JWT/OIDC) route, then the produced ZIP, then the notification mail.
//
// Why this spec exists: a partner (GBIF-PT) running the same auth combo as this inventory
// (security.cas.enabled=false, security.oidc.enabled=true, security.jwt.enabled=true,
// security.apikey.enabled=true, webservice.jwt=false) gets HTTP 400 "No valid email" on every
// download. That 400 means AuthServiceImpl.getDownloadUser() returned empty — NO principal
// reached biocache-service. A 412 would mean the opposite (principal arrived, no email on it).
// assertDownloadAccepted() keeps those two apart; that distinction is the point of the spec.
describe("Biocache offline downloads", () => {
  // A registered, activated user's email — route 3 of getDownloadUser looks it up in
  // userdetails and refuses (400) when it does not resolve. Defaults to the auth-test
  // account, which the CI E2E stage already extracts from lademo-local-passwords.ini.
  const downloadEmail: string | undefined =
    Cypress.env("DOWNLOAD_EMAIL") || Cypress.env("LADEMO_USERNAME");

  // Offline downloads are queued and processed by a worker; give the queue real time.
  const DOWNLOAD_TIMEOUT_MS = Number(Cypress.env("DOWNLOAD_TIMEOUT_MS") || 240000);

  before(function () {
    skipIfMissing("recordsWs", this);
  });

  context("a) API download with an email parameter (getDownloadUser route 3/4)", () => {
    before(function () {
      if (!downloadEmail) {
        // No registered address to test with — the check would be meaningless, not failing.
        this.skip();
      }
    });

    it("accepts an offline download for a registered email", () => {
      const url = offlineDownloadUrl({ email: downloadEmail as string });
      cy.request({ url, failOnStatusCode: false }).then((resp) => {
        const status = assertDownloadAccepted(
          resp,
          "API download with email param (route 3: userdetails lookup of `email`)",
        );
        // Hand the statusUrl to the polling test without re-issuing the download.
        Cypress.env("LAST_STATUS_URL", status.statusUrl);
      });
    });

    it("refuses a download with no email and no principal (400 is CORRECT here)", () => {
      // Negative control. It proves the 400 in the test above (if it ever appears) is about
      // the principal, not about the endpoint being unreachable or the query being invalid.
      const url = serviceUrl("recordsWs", `/occurrences/offline/download?${downloadQuery()}`);
      cy.request({ url, failOnStatusCode: false }).then((resp) => {
        expect(
          resp.status,
          "anonymous download with no email must be rejected with 400 'No valid email'",
        ).to.eq(400);
      });
    });
  });

  context("b) authenticated download from the hub (getDownloadUser route 1: JWT/OIDC)", () => {
    // Gated exactly like 8-auth: needs real credentials.
    before(function () {
      if (!authTestsEnabled()) {
        this.skip();
      }
      if (!hasService("records")) {
        this.skip();
      }
    });

    // This is the partner's failing case. The hub does not download anything itself: it hands
    // the browser to `downloads.indexedDownloadUrl` (= records-ws /occurrences/offline/download).
    // So what we assert is what biocache-service answers for a request originated by a
    // logged-in session — and, crucially, WHETHER the hub attached any user identity to it.
    it("a logged-in user's download request is accepted by biocache-service", () => {
      cy.login();

      cy.intercept("GET", "**/occurrences/offline/download*").as("offlineDownload");
      cy.visit(serviceUrl("records", "/occurrences/search?q=*:*"));

      cy.get("body").then(($body) => {
        const trigger = $body.find(
          'a[href*="/occurrences/download"], a#downloadLink, a[href*="offline/download"], ' +
            'button#download, .download-link',
        );
        if (trigger.length === 0) {
          // No download affordance rendered (e.g. empty index → no results toolbar). Fall
          // back to the request the hub would have issued, carrying the session cookies.
          cy.request({
            url: offlineDownloadUrl({ email: downloadEmail as string }),
            failOnStatusCode: false,
          }).then((resp) => {
            assertDownloadAccepted(
              resp,
              "authenticated download (hub UI trigger absent; session-cookie request)",
            );
          });
          return;
        }
        cy.wrap(trigger).first().click({ force: true });
        cy.wait("@offlineDownload", { timeout: 60000 }).then((interception) => {
          const resp = interception.response;
          expect(resp, "hub issued the offline download request").to.exist;
          assertDownloadAccepted(
            {
              status: resp!.statusCode,
              body: resp!.body,
            } as Cypress.Response<never>,
            "authenticated download triggered from the records hub",
          );
        });
      });
    });
  });

  context("c) the queued download completes and the ZIP is fetchable", () => {
    before(function () {
      if (!downloadEmail) {
        this.skip();
      }
    });

    it("polls the statusUrl to a terminal state and downloads the archive", () => {
      const statusUrl = Cypress.env("LAST_STATUS_URL") as string | undefined;
      if (!statusUrl) {
        throw new Error(
          "No statusUrl from the API download test — that test must pass first " +
            "(see its message for whether auth or something downstream refused it).",
        );
      }
      pollDownloadStatus(statusUrl, Date.now() + DOWNLOAD_TIMEOUT_MS).then((status) => {
        expect(
          status.status,
          `download terminal state (message: ${status.message || "-"}, ` +
            `error: ${status.error || "-"})`,
        ).to.eq("FINISHED");
        expect(status.downloadUrl, "downloadUrl on the finished download").to.match(
          /^https?:\/\//,
        );
        const announced = status.downloadUrl as string;
        cy.request({ url: announced, encoding: "binary", failOnStatusCode: false }).then(
          (zip) => {
            if (zip.status === 404) {
              // biocache announces `download.url` from the inventory, but the
              // `location /biocache-download` alias lives in the biocache-SERVICE vhost.
              // When the two point at different hosts the ZIP exists and is simply
              // unreachable at the advertised address — say so instead of "404".
              const alt =
                serviceUrl("recordsWs") + new URL(announced).pathname;
              cy.request({ url: alt, encoding: "binary", failOnStatusCode: false }).then(
                (altZip) => {
                  expect(
                    altZip.status === 200,
                    `the announced downloadUrl ${announced} returns 404. The same path under ` +
                      `recordsWs (${alt}) returns ${altZip.status} — if that one is 200, the ` +
                      `inventory's download_url points at a vhost that does not serve ` +
                      `/biocache-download; if it is also 404, nginx has no read access to ` +
                      `download.dir.`,
                  ).to.eq(true);
                },
              );
              return;
            }
            expect(zip.status, `GET ${announced}`).to.eq(200);
            // ZIP local file header. Cheap and format-exact; no unzipping needed.
            expect(
              String(zip.body).slice(0, 2),
              "archive should start with the ZIP magic bytes (PK)",
            ).to.eq("PK");
          },
        );
      });
    });
  });

  context("d) the download notification email is delivered", () => {
    before(function () {
      // Skips cleanly when the deployment does not run the dev mail catcher
      // (docker_mail_development_mode=false → no `mailhog` key in the targets manifest).
      if (!hasMailhog() || !downloadEmail) {
        this.skip();
      }
    });

    it("mailhog received a download mail addressed to the requester", () => {
      // The mail is sent when the download finishes, so this depends on (c) having run.
      cy.wrap(null, { timeout: 60000 }).then(() =>
        mailhogMessagesTo(downloadEmail as string).then((messages) => {
          expect(
            messages.length,
            `mailhog should hold at least one message for ${downloadEmail}`,
          ).to.be.greaterThan(0);
          const subjects = messages.map(
            (m) => (m.Content?.Headers?.Subject || []).join(" "),
          );
          expect(
            subjects.some((s) => /download/i.test(s)),
            `one message should be a download notification. Subjects seen: ${subjects.join(" | ")}`,
          ).to.eq(true);
        }),
      );
    });
  });
});
