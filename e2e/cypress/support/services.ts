// Inventory-driven service catalog. The URLs come from e2e-targets.json (emitted by the
// deployment's config-gen from the same inventory vars that drive nginx/Gatus). Specs never
// hardcode a hostname or path — they ask for a service key and get whatever the inventory
// resolved (subdomain like https://records.l-a.site, or path like https://portal/biocache-hub).

export interface AlaUpstreamFallback {
  host: string;
  /** Optional config key the exemption is scoped to. Omit to exempt the whole host. */
  property?: string;
  reason: string;
}

export interface Targets {
  env: string;
  root: string;
  auth: string;
  services: Record<string, string>;
  /**
   * ALA-hosted upstreams this deployment deliberately still depends on, declared in the
   * inventory (roles/la-compose/defaults/main.yml: ala_upstream_fallbacks). Optional: an
   * older manifest predating the field must still load.
   */
  alaUpstreamFallbacks?: AlaUpstreamFallback[];
}

export function targets(): Targets {
  const t = Cypress.env("TARGETS") as Targets | undefined;
  if (!t || !t.services) {
    throw new Error("e2e-targets manifest missing from Cypress.env('TARGETS').");
  }
  return t;
}

/** Full URL for a service key, optional path/query suffix. Throws on unknown key. */
export function serviceUrl(key: string, suffix = ""): string {
  const t = targets();
  const base = t.services[key];
  if (!base) {
    throw new Error(
      `Unknown service '${key}' in e2e-targets manifest. ` +
        `Available: ${Object.keys(t.services).join(", ")}`,
    );
  }
  return base + suffix;
}

export function rootUrl(suffix = ""): string {
  return targets().root + suffix;
}

export function authUrl(suffix = ""): string {
  return targets().auth + suffix;
}

/** True if a service key is present in the manifest (lets specs skip cleanly when a
 *  service is not deployed in this inventory). */
export function hasService(key: string): boolean {
  return Boolean(targets().services[key]);
}

/** Declared ALA upstream fallbacks, or [] on a manifest generated before the field existed. */
export function declaredAlaFallbacks(): AlaUpstreamFallback[] {
  return targets().alaUpstreamFallbacks ?? [];
}

/**
 * Every hostname this deployment owns, from the manifest: the portal root, the auth server
 * and every service. Used by the effective-config audit to tell "our own URL" from a foreign
 * one without hardcoding a single hostname.
 */
export function ownHosts(): string[] {
  const t = targets();
  const hosts = new Set<string>();
  [t.root, t.auth, ...Object.values(t.services)].forEach((url) => {
    try {
      if (url) hosts.add(new URL(url).hostname.toLowerCase());
    } catch {
      /* a relative or malformed entry is simply not a host */
    }
  });
  return [...hosts];
}
