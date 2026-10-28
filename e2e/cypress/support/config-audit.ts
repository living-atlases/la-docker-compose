// Effective-config auditing: layer 3 of the config-validation strategy.
//
// Layers 1 and 5 (diff our rendered .properties against ALA's, then freeze a baseline) answer
// "did we render the right value". They are structurally blind to a different failure: a key
// ala-install never parameterises at all, where the Grails app falls back to a compiled-in
// default that points at ALA. That value exists in no file, so no file diff can see it.
//
// It is not hypothetical. In gbif.es PRODUCTION, collectory's /alaAdmin/viewConfig showed:
//     security.apiKey.auth.serviceUrl = https://auth.gbif.es/apikey/
//     security.apikey.auth.serviceUrl = https://auth-test.ala.org.au/apikey/
// a lowercase case-variant resolving to ALA's *test* auth server, in production, invisible to
// every other layer.
//
// This module holds the pure logic so it can be exercised offline against fixtures
// (9-config/config-audit.selftest.cy.ts) rather than only against a live stack. That self-test
// is the proof the guard actually bites; it plants known-bad rows and asserts they are caught,
// and plants the known false-positive traps and asserts they are not.

import alaHosts from "./ala-hosts.json";

export interface DeclaredFallback {
  /** Hostname the deployment deliberately still depends on, e.g. "pdfgen.ala.org.au". */
  host: string;
  /**
   * Optional config key the exemption is scoped to. Omit to exempt the whole host.
   * Scoping matters: spatial.ala.org.au is an accepted OSM tile source, but the same host
   * appearing under some other key would mean we are pointing at ALA's spatial portal.
   */
  property?: string;
  /** Why it is still there, and what would remove it. Surfaced in the report. */
  reason: string;
}

export interface AuditInput {
  /** Flattened key -> value pairs as shown by /alaAdmin/viewConfig. */
  props: Record<string, string>;
  /** Hostnames this deployment owns, derived from the e2e-targets manifest. */
  ownHosts: string[];
  declaredFallbacks: DeclaredFallback[];
}

export interface AuditEntry {
  key: string;
  value: string;
  host: string;
  /** Present on declared-fallback entries only. */
  reason?: string;
}

export interface AuditResult {
  /** Undeclared references to ALA infrastructure. These FAIL the spec. */
  findings: AuditEntry[];
  /** Declared fallbacks, ALA documentation/content links. Reported, never fatal. */
  informational: AuditEntry[];
  /**
   * Declared fallbacks that matched nothing IN THIS CALL. Per-service, so it is only
   * meaningful once intersected across every service audited — a fallback that lives in
   * ala-hub is legitimately absent from collectory. The spec aggregates before reporting.
   */
  staleFallbacks: DeclaredFallback[];
  /** key -> URL for every URL-valued, non-secret config property. Seed for the layer-5 baseline. */
  urlMap: Record<string, string>;
}

/**
 * ALA hosts that serve a role we deploy ourselves. A config value pointing here means the
 * deployment is using ALA's instance instead of its own — the class of defect behind the
 * 127.0.0.1 proxies, the swarm-era ZooKeeper, data-quality's userDetails.url and spatial-hub's
 * lists.urlUi.
 *
 * Read from ala-hosts.json, which the offline pre-deploy check (scripts/config-baseline.py
 * ala-hosts) reads too, so the two guards cannot drift apart. Deliberately SERVICE hosts only:
 * documentation and content hosts are left out, because flagging them would make this check
 * permanently noisy, which is how a guard dies.
 */
export const ALA_SERVICE_HOSTS: Record<string, string> = alaHosts.serviceHosts;

/** ALA-family domains. Anything here that is not a service host is informational. */
const ALA_FAMILY = new RegExp(alaHosts.familyPattern, "i");

/**
 * Non-production ALA infrastructure. Always a finding, whatever the service: depending on
 * somebody else's test/staging environment is never a defensible production configuration.
 * This is the rule that would have caught auth-test.ala.org.au in gbif.es production.
 */
const NONPROD_ALA_HOST = new RegExp(alaHosts.nonProdPattern, "i");

/**
 * JVM and container system-property namespaces. These are dotted and lower-cased just like
 * Grails config, so the shape rules above do not exclude them, and several carry URLs
 * (java.vendor.url, java.vendor.url.bug). Excluding them by namespace is deliberate.
 *
 * They would never be *findings* — oracle.com is not an ALA host — but they would land in
 * urlMap, and urlMap is what seeds the layer-5 frozen baseline. Left in, the baseline would
 * churn on every JVM upgrade and the ratchet would get disabled for being noisy. The
 * self-test asserts their absence from urlMap for exactly that reason.
 */
const SYSTEM_NAMESPACES = [
  "java.",
  "sun.",
  "jdk.",
  "os.",
  "user.",
  "file.",
  "line.",
  "path.",
  "awt.",
  "native.",
  "catalina.",
  "common.",
  "shared.",
  "package.",
  "socks",
  "http.",
  "https.",
  "ftp.",
  "javax.",
  "jna.",
];

/**
 * Grails `environments.<env>.*` blocks: the compiled defaults for each environment, listed raw
 * by viewConfig. Inert as such -- the value in force is the same key without the prefix, which
 * is audited -- and noisy: lists and logger carry dev/test/production blocks full of ALA hosts
 * (lists-test.ala.org.au, logger.ala.org.au), which made every one of them a "finding".
 */
const INERT_PREFIXES: string[] = alaHosts.inertKeyPrefixes;

/** Keys whose value must never be emitted anywhere. Handoff rule 3: when in doubt, redact. */
const SECRET_SHAPED = /pass|secret|key|token|credential|salt|private/i;

export function isSecretShaped(key: string): boolean {
  return SECRET_SHAPED.test(key);
}

/**
 * True for a Grails/Spring configuration property, false for everything else on the page.
 *
 * /alaAdmin/viewConfig does not render Grails config — it renders the flattened
 * `grailsApplication.config`, which has the whole process environment merged into it:
 * JAVA_OPTS, PATH, HOME, PWD, LANG, CATALINA_BASE, INVOCATION_ID, JOURNAL_STREAM. Without
 * this filter the check reports environment noise forever and gets switched off.
 *
 * The handoff describes the discriminator as case — env vars ALL_CAPS, config properties
 * dotted and lower-cased. In practice the dot alone does that job: every environment
 * variable on the page (PATH, HOME, PWD, LANG, JAVA_OPTS, CATALINA_BASE, INVOCATION_ID,
 * JOURNAL_STREAM, SPRING_ELASTICSEARCH_URIS) is dot-free, because POSIX env var names are.
 *
 * Two case-based rules were written here first and both were deleted, because breaking each
 * on purpose changed nothing — the self-test stayed green without them. A rule that cannot
 * be made to fail is decoration, and decoration is what makes a check look stronger than it
 * is. What is left is two rules, each verified to turn the self-test red when removed.
 *
 * Dropping the case rule also fixes a real gap rather than merely simplifying: a dotted key
 * injected as an environment variable (docker permits `-e some.key=…`, which POSIX shells do
 * not) is genuinely part of the effective config, and now gets audited instead of skipped.
 */
export function isConfigProperty(key: string): boolean {
  if (!key || !key.includes(".")) return false; // PATH, HOME, JAVA_OPTS, CATALINA_BASE
  if (INERT_PREFIXES.some((p) => key.startsWith(p))) return false; // environments.test.*
  return !SYSTEM_NAMESPACES.some((ns) => key.startsWith(ns)); // java.vendor.url, user.home
}

/** Hostname of a value that is an absolute http(s) URL; null otherwise. */
export function urlHost(value: string): string | null {
  const trimmed = (value || "").trim();
  if (!/^https?:\/\//i.test(trimmed)) return null;
  try {
    return new URL(trimmed).hostname.toLowerCase();
  } catch {
    return null;
  }
}

/**
 * A URL reduced to scheme + host + port + path, with userinfo, query and fragment dropped.
 *
 * Applied to EVERY value this module reports or stores, not just secret-shaped ones. A URL
 * under a key like security.apikey.auth.serviceUrl is the exact case this check exists to
 * catch, so it cannot simply be skipped — but it can also be the one carrying
 * https://user:password@host or ?apiKey=... . Stripping unconditionally keeps the report and
 * the layer-5 baseline free of credentials by construction rather than by vigilance, and the
 * origin and path are all the diagnosis needs.
 */
export function safeUrl(value: string): string {
  try {
    const u = new URL(value.trim());
    u.username = "";
    u.password = "";
    u.search = "";
    u.hash = "";
    return u.toString();
  } catch {
    return value.trim();
  }
}

function matchesFallback(
  fb: DeclaredFallback,
  key: string,
  host: string,
): boolean {
  if (fb.host.toLowerCase() !== host) return false;
  return !fb.property || fb.property === key;
}

/**
 * Read the property table out of a rendered /alaAdmin/viewConfig page.
 *
 * The page (ala-admin-plugin, AlaAdminController.viewConfig -> view-config.gsp) is a
 * Bootstrap table with no id: <thead> Property/Value, then one <tr> per entry with exactly
 * two <td>, key first. There is no JSON variant of the endpoint, so HTML parsing it is.
 *
 * Matched by row shape rather than by the Bootstrap classes, so a restyle upstream does not
 * silently break this into "found nothing". Callers must still assert a plausible property
 * count — a parser that returns {} would otherwise report zero findings and look green.
 */
export function parseConfigTable(doc: Document): Record<string, string> {
  const props: Record<string, string> = {};
  doc.querySelectorAll("table tr").forEach((tr) => {
    const cells = tr.querySelectorAll("td");
    if (cells.length !== 2) return;
    const key = (cells[0].textContent || "").trim();
    const value = (cells[1].textContent || "").trim();
    if (key) props[key] = value;
  });
  return props;
}

/**
 * Classify every config property of a service against the hosts this deployment owns.
 *
 * Two severities, by design:
 *   finding       an ALA host serving a role we deploy, or any ALA non-prod host, undeclared
 *   informational a declared fallback, or any other ALA-family host (docs, support, content)
 *
 * Everything else — our own hosts, container names, third parties — is left alone. Widening
 * this to "any foreign host" would bury the signal under GBIF, DOI, ORCID and OSM traffic.
 */
export function auditEffectiveConfig(input: AuditInput): AuditResult {
  const own = new Set(input.ownHosts.map((h) => h.toLowerCase()));
  const findings: AuditEntry[] = [];
  const informational: AuditEntry[] = [];
  const urlMap: Record<string, string> = {};
  const usedFallbacks = new Set<DeclaredFallback>();

  for (const [rawKey, rawValue] of Object.entries(input.props)) {
    if (!isConfigProperty(rawKey)) continue;
    const host = urlHost(rawValue);
    if (!host) continue;
    const key = rawKey;
    const value = safeUrl(rawValue);
    // Secret-shaped keys are still AUDITED — the gbif.es production defect was on
    // security.apikey.auth.serviceUrl — they are only kept out of the persisted baseline.
    if (!isSecretShaped(key)) urlMap[key] = value;
    if (own.has(host)) continue;
    if (!ALA_FAMILY.test(host)) continue; // third parties are not this check's business

    const fb = input.declaredFallbacks.find((f) => matchesFallback(f, key, host));
    if (fb) {
      usedFallbacks.add(fb);
      informational.push({ key, value, host, reason: `declared: ${fb.reason}` });
      continue;
    }

    if (NONPROD_ALA_HOST.test(host)) {
      findings.push({
        key,
        value,
        host,
        reason: "ALA non-production infrastructure (test/staging/sandbox/nectar)",
      });
      continue;
    }

    const role = ALA_SERVICE_HOSTS[host];
    if (role) {
      findings.push({ key, value, host, reason: `ALA's ${role}, which we deploy ourselves` });
      continue;
    }

    informational.push({ key, value, host, reason: "ALA documentation/content link" });
  }

  return {
    findings,
    informational,
    staleFallbacks: input.declaredFallbacks.filter((f) => !usedFallbacks.has(f)),
    urlMap,
  };
}

/** One-line-per-entry rendering for assertion messages and the run log. */
export function formatEntries(entries: AuditEntry[]): string {
  return entries
    .map((e) => `  ${e.key} = ${e.value}${e.reason ? `   [${e.reason}]` : ""}`)
    .join("\n");
}
