// Helpers for the biocache offline-download spec.
//
// The whole diagnostic value of that spec is in telling apart the two ways biocache-service
// refuses a download, so the failure message names the actual broken layer instead of
// "download failed". Both come from DownloadController.occurrenceDownload:
//
//   400 "No valid email"  -> AuthServiceImpl.getDownloadUser() returned Optional.empty().
//                            NO AlaUserProfile reached biocache-service at all: neither a JWT/
//                            OIDC principal (route 1) nor a userdetails lookup of the `email`
//                            query param (route 3). This is the partner-reported failure.
//   412 (PRECONDITION)    -> a principal DID arrive, but its email is blank. Auth works;
//                            the claim/attribute release is what is incomplete.
//
// Anything else (500, 502, ...) is a downstream fault and is reported verbatim, because a
// download that gets past auth and then dies on storage is a different bug entirely.

import { hasService, serviceUrl } from "./services";

/** Status shape returned by /occurrences/offline/download and its statusUrl. */
export interface DownloadStatus {
  status?: string;
  statusUrl?: string;
  downloadUrl?: string;
  message?: string;
  error?: string;
  totalRecords?: number;
  queueSize?: number;
}

// Terminal states of DownloadStatusDTO.DownloadStatus. FINISHED is the success one; the
// others end the poll too, so a broken download fails fast instead of burning the timeout.
const TERMINAL_STATES = ["FINISHED", "TOO_LARGE", "SKIPPED", "FAILED", "ERROR"];

/**
 * Assert biocache-service ACCEPTED an offline download request, and when it did not, say
 * which layer refused it. `context` labels the auth route under test in the message.
 */
export function assertDownloadAccepted(
  resp: Cypress.Response<DownloadStatus | string>,
  context: string
): DownloadStatus {
  const body =
    typeof resp.body === "string" ? { message: resp.body } : resp.body || {};
  const detail = JSON.stringify(body).slice(0, 500);

  if (resp.status === 400) {
    throw new Error(
      `${context}: biocache-service returned 400 "No valid email" — ` +
        `no user principal reached biocache-service. ` +
        `getDownloadUser() found neither a JWT/OIDC principal (security.jwt) nor a ` +
        `userdetails-resolvable email query param. Body: ${detail}`
    );
  }
  if (resp.status === 412) {
    throw new Error(
      `${context}: biocache-service returned 412 — ` +
        `principal without email. Authentication DID reach biocache-service, but the ` +
        `profile carries no email address (missing claim / attribute release). ` +
        `Body: ${detail}`
    );
  }
  expect(
    resp.status,
    `${context}: offline download should be accepted (neither 400 no-principal nor ` +
      `412 principal-without-email). Body: ${detail}`
  ).to.eq(200);

  expect(body, `${context}: download status body`).to.have.property(
    "statusUrl"
  );
  expect(body.statusUrl, `${context}: statusUrl`).to.match(/^https?:\/\//);
  return body as DownloadStatus;
}

/** Query string for a generic, data-agnostic offline download request. */
export function downloadQuery(extra: Record<string, string> = {}): string {
  const params: Record<string, string> = {
    // Same generic query the search spec uses, so this works against any inventory's data.
    q: "*:*",
    // "testing" reason; reasonTypeId is mandatory for offline downloads.
    reasonTypeId: "10",
    fileType: "csv",
    ...extra,
  };
  return Object.entries(params)
    .map(([k, v]) => `${encodeURIComponent(k)}=${encodeURIComponent(v)}`)
    .join("&");
}

export function offlineDownloadUrl(extra: Record<string, string> = {}): string {
  return serviceUrl(
    "recordsWs",
    `/occurrences/offline/download?${downloadQuery(extra)}`
  );
}

/**
 * Poll a statusUrl until the download reaches a terminal state. Recursion (not a loop) so
 * every hop stays inside Cypress's command queue.
 */
export function pollDownloadStatus(
  statusUrl: string,
  deadline: number,
  intervalMs = 5000
): Cypress.Chainable<DownloadStatus> {
  return cy.request({ url: statusUrl, failOnStatusCode: false }).then((resp):
    | Cypress.Chainable<DownloadStatus>
    | DownloadStatus => {
    const body = (resp.body || {}) as DownloadStatus;
    expect(resp.status, `GET ${statusUrl}`).to.be.lessThan(400);
    const state = (body.status || "").toUpperCase();
    if (TERMINAL_STATES.includes(state)) {
      return body;
    }
    if (Date.now() > deadline) {
      throw new Error(
        `Download did not reach a terminal state before the timeout. ` +
          `Last status: ${JSON.stringify(body).slice(0, 500)}`
      );
    }
    return cy
      .wait(intervalMs, { log: false })
      .then(() => pollDownloadStatus(statusUrl, deadline, intervalMs));
  }) as Cypress.Chainable<DownloadStatus>;
}

/** True when this deployment runs the dev mail catcher (docker_mail_development_mode). */
export function hasMailhog(): boolean {
  return hasService("mailhog");
}

export interface MailhogMessage {
  Content: { Headers: Record<string, string[]> };
  Raw: { To: string[]; From: string };
}

/**
 * Fetch messages addressed to `recipient` from the Mailhog API, newest first.
 * Uses /api/v2/search (v1 has no server-side filter) and falls back to v1 + client-side
 * filtering on older mailhog images.
 */
export function mailhogMessagesTo(
  recipient: string
): Cypress.Chainable<MailhogMessage[]> {
  const base = serviceUrl("mailhog");
  return cy
    .request({
      url: `${base}/api/v2/search?kind=to&query=${encodeURIComponent(
        recipient
      )}&limit=50`,
      failOnStatusCode: false,
    })
    .then((resp) => {
      if (resp.status === 200 && resp.body && Array.isArray(resp.body.items)) {
        return resp.body.items as MailhogMessage[];
      }
      return cy
        .request({ url: `${base}/api/v1/messages`, failOnStatusCode: false })
        .then((v1) => {
          const all: MailhogMessage[] = Array.isArray(v1.body) ? v1.body : [];
          return all.filter((m) =>
            (m.Raw?.To || []).some(
              (to) => to.toLowerCase() === recipient.toLowerCase()
            )
          );
        });
    }) as Cypress.Chainable<MailhogMessage[]>;
}
