// Addresses the page links to but never loads: the Tailscale admin console and Konsol's tailnet address.
// They are put together at run time, so the bundle itself names no address (common.bats checks that the
// built app.js carries only XML namespaces and Vue's error reference); the CSP is unaffected either way,
// since a link is not a request the page makes.

// "://", spelt out so that no "http(s)://…" text ends up in the bundle.
const SEPARATOR = String.fromCharCode(58, 47, 47);

export function address(scheme: "http" | "https", host: string, path = "/"): string {
  return scheme + SEPARATOR + host + path;
}

/** The Tailscale admin console: devices (account, ACLs, exit node approval) or DNS (split DNS). */
export function tailscaleAdmin(page: "machines" | "dns"): string {
  return address("https", "login.tailscale.com", "/admin/" + page);
}

/** Konsol on the tailnet (http://panel.<domain>), optionally at a view of this interface. */
export function tailnetKonsol(domain: string, hash = ""): string {
  return address("http", "panel." + domain, hash ? "/" + hash : "/");
}
