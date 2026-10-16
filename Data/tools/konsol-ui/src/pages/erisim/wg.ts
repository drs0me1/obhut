// The WireGuard tab's vocabulary: the DNS providers, a device's state, a network's name and the checks a
// form makes before asking the server.
import type { WireGuard as WgState, WireGuardAgi as WgNetwork, WireGuardCihazi as WgPeer } from "../../api/sema";

export const DNS_PRESETS = [
  { name: "Cloudflare", tag: "Hızlı; kurulumun varsayılanı", ips: "1.1.1.1, 1.0.0.1, 2606:4700:4700::1001" },
  { name: "Cloudflare Aile", tag: "Zararlı ve yetişkin içerik engelli", ips: "1.1.1.3, 1.0.0.3, 2606:4700:4700::1113" },
  { name: "Quad9", tag: "Zararlı site engelli", ips: "9.9.9.9, 149.112.112.112, 2620:fe::fe" },
  { name: "AdGuard", tag: "Reklam ve izleyici engelli", ips: "94.140.14.14, 94.140.15.15, 2a10:50c0::ad1:ff" },
  { name: "Google", tag: "", ips: "8.8.8.8, 8.8.4.4, 2001:4860:4860::8888" },
] as const;

/** Addresses separated by commas, without spaces inside; null when one is not an IP address. */
export function normDns(text: string): string | null {
  const parts = text.split(",").map((t) => t.replace(/\s+/g, "")).filter(Boolean);
  if (!parts.length) return null;
  for (const t of parts) {
    if (!/^\d{1,3}(\.\d{1,3}){3}$/.test(t) && !/^[0-9a-f]*:[0-9a-f:]*$/i.test(t)) return null;
  }
  return parts.join(", ");
}

export const providerOf = (ips: string, fallback = ""): string => DNS_PRESETS.find((d) => d.ips === ips)?.name ?? (fallback || "Özel");

export const NAME_RE = /^[A-Za-z0-9][A-Za-z0-9._-]{0,31}$/;
export const keepaliveText = (ka: number): string => (ka ? `${ka} sn` : "kapalı");
export const labelOf = (n: Pick<WgNetwork, "label" | "iface">): string => n.label || (n.iface === "wg0" ? "Ana ağ" : "Etiketsiz");

export type DeviceState = "ok" | "idle" | "never" | "off" | "netoff";
export const DEVICE_STATE: Record<DeviceState, string> = { ok: "Bağlı", idle: "Boşta", never: "Görülmedi", off: "Kapalı", netoff: "Ağ kapalı" };

/** Bağlı: data arrived recently; Boşta: a handshake within a day; Görülmedi: older or never. */
export function deviceState(n: Pick<WgNetwork, "active">, p: WgPeer, now: number): DeviceState {
  if (!n.active) return "netoff";
  if (!p.enabled) return "off";
  if (p.online) return "ok";
  if (p.handshake && now - p.handshake < 86400) return "idle";
  return "never";
}

export const onlineCount = (n: WgNetwork, now: number): number => n.peers.filter((p) => deviceState(n, p, now) === "ok").length;

/** The next free network: wg<i> with 10.8.<i>.0/24, or null at the limit. */
export function nextNetwork(state: WgState): number | null {
  for (let i = 0; i < state.max; i++) if (!state.networks.some((n) => n.iface === `wg${i}`)) return i;
  return null;
}

/** Who holds a UDP port already: a network's interface, "sunucu" for the base's own ports, or null. */
export function portOwner(state: WgState, port: number): string | null {
  const n = state.networks.find((x) => x.port === port);
  if (n) return n.iface;
  return state.reserved.includes(port) ? "sunucu" : null;
}

const PORT_START = 61020;

/** The first network gets the installation's default port when it is free; later ones 61020 and up. */
export function suggestPort(state: WgState): number {
  const first = state.defaults.port;
  if (!state.networks.length && first && !portOwner(state, first)) return first;
  let port = PORT_START;
  while (portOwner(state, port)) port += 1;
  return port;
}

export function portProblem(state: WgState, text: string): string {
  const port = /^\d+$/.test(text.trim()) ? Number(text.trim()) : NaN;
  if (!(port >= 1024 && port <= 65535)) return "1024 ile 65535 arasında bir port yazın.";
  const owner = portOwner(state, port);
  return owner ? `UDP ${port} kullanımda (${owner}); başka bir port yazın.` : "";
}

/** A network's name: at most 64 bytes, no spaces at either end, no control characters. */
export function labelProblem(text: string): string {
  if (text !== text.trim()) return "Ağ adının başında ya da sonunda boşluk olamaz.";
  if (new TextEncoder().encode(text).length > 64) return "Ağ adı en çok 64 bayt olabilir.";
  if (/[\u0000-\u001f\u007f]/.test(text)) return "Ağ adında denetim karakteri olamaz.";
  return "";
}

export function keepaliveProblem(text: string): string {
  const value = /^\d+$/.test(text.trim()) ? Number(text.trim()) : NaN;
  return value >= 0 && value <= 65535 ? "" : "0 ile 65535 arasında saniye yazın (0 = kapalı).";
}
