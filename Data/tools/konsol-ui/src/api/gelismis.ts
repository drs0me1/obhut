// Gelişmiş's reads (DD-266; read-only since the rebuild's phase 5, K8): the effective Caddy and dnsmasq
// configuration (shapes in panel/master_api.py's table). Paths and shapes come from sema.ts (generated from
// panel/master_api.py); every reply is checked before a page shows it, and a list item without its expected
// fields is left out.
import { YOLLAR, type Gelismis, type YapilandirmaDosyasi } from "./sema";
import { getJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

const isList = Array.isArray;
const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const texts = (v: unknown): string[] => (isList(v) ? v.filter(isText) : []);
const files = (v: unknown): YapilandirmaDosyasi[] => (isList(v) ? v.filter((f): f is YapilandirmaDosyasi => isObject(f) && isText(f.file) && isText(f.text)) : []);

export interface CaddyRoute {
  path: string;
  kind: string;
  to: string;
}

export interface DnsName {
  name: string;
  iface: string;
  family: number | null;
  address: string;
  source: string;
}

export interface Advanced {
  read_at: number;
  caddy: { entries: { address: string; routes: CaddyRoute[]; source: string; access: "tailscale" | "wan"; scheme: string }[]; raw: YapilandirmaDosyasi[] };
  dnsmasq: { listen: string[]; domains: string[]; dhcp: boolean; names: DnsName[]; raw: YapilandirmaDosyasi[] };
}

export async function readAdvanced(fresh = false): Promise<Advanced> {
  const value = shaped<Gelismis>(await getJson(YOLLAR.gelismis + (fresh ? "?yenile=1" : "")), (v) => isObject(v.caddy) && isObject(v.dnsmasq));
  const caddy = value.caddy as unknown as Record<string, unknown>;
  const dns = value.dnsmasq as unknown as Record<string, unknown>;
  return {
    read_at: isNumber(value.read_at) ? value.read_at : 0,
    caddy: {
      entries: (isList(caddy.entries) ? caddy.entries : [])
        .filter((e): e is Record<string, unknown> => isObject(e) && isText(e.address) && isText(e.source))
        .map((e) => ({
          address: e.address as string,
          source: e.source as string,
          access: e.access === "wan" ? "wan" : "tailscale",
          scheme: isText(e.scheme) ? e.scheme : "",
          routes: (isList(e.routes) ? e.routes : [])
            .filter((r): r is Record<string, unknown> => isObject(r) && isText(r.kind))
            .map((r) => ({ path: isText(r.path) ? r.path : "", kind: r.kind as string, to: isText(r.to) ? r.to : "" })),
        })),
      raw: files(caddy.raw),
    },
    dnsmasq: {
      listen: texts(dns.listen),
      domains: texts(dns.domains),
      dhcp: dns.dhcp === true,
      names: (isList(dns.names) ? dns.names : [])
        .filter((n): n is Record<string, unknown> => isObject(n) && isText(n.name))
        .map((n) => ({
          name: n.name as string,
          iface: isText(n.iface) ? n.iface : "",
          family: n.family === 4 || n.family === 6 ? n.family : null,
          address: isText(n.address) ? n.address : "",
          source: isText(n.source) ? n.source : "",
        })),
      raw: files(dns.raw),
    },
  };
}
