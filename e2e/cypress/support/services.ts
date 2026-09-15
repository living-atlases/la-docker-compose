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

/** One data hub: an extra front-end showing a data_hub_uid-filtered subset of the
 *  portal's records, with its own subdomain and, optionally, its own branding. */
export interface HubTarget {
  key: string;
  name: string;
  /** The data_hub_uid:… filter this hub is scoped to. */
  queryContext?: string;
  /** header_and_footer_baseurl: the hub's own branding, or the portal's when the
   *  hub declares no branding_source of its own. */
  branding?: string;
  services: Record<string, string>;
}

export interface Targets {
  env: string;
  root: string;
  auth: string;
  services: Record<string, string>;
  /** Data hubs deployed alongside the portal. Optional: a manifest predating hubs,
   *  or a deployment without any, must still load. */
  hubs?: HubTarget[];
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

/** Data hubs declared by the deployment. Empty when there are none, so every hub
 *  spec can skip cleanly instead of failing. */
export function hubs(): HubTarget[] {
  return targets().hubs ?? [];
}

export function hasHub(key: string): boolean {
  return hubs().some((h) => h.key === key);
}

/** Full URL for one service of one hub. Throws on an unknown hub or service so a
 *  typo in a spec never silently degrades into "nothing to test". */
export function hubServiceUrl(hubKey: string, key: string, suffix = ""): string {
  const hub = hubs().find((h) => h.key === hubKey);
  if (!hub) {
    throw new Error(
      `Unknown hub '${hubKey}' in e2e-targets manifest. ` +
        `Available: ${hubs().map((h) => h.key).join(", ") || "(none)"}`,
    );
  }
  const base = hub.services[key];
  if (!base) {
    throw new Error(
      `Hub '${hubKey}' does not deploy '${key}'. ` +
        `Available: ${Object.keys(hub.services).join(", ")}`,
    );
  }
  return base + suffix;
}
