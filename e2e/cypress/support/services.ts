// Inventory-driven service catalog. The URLs come from e2e-targets.json (emitted by the
// deployment's config-gen from the same inventory vars that drive nginx/Gatus). Specs never
// hardcode a hostname or path — they ask for a service key and get whatever the inventory
// resolved (subdomain like https://records.l-a.site, or path like https://portal/biocache-hub).

export interface Targets {
  env: string;
  root: string;
  auth: string;
  services: Record<string, string>;
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
