// The WireGuard package's own API (DD-200; magaza/wireguard/api.py), which the route table does not
// describe: its shapes are written here and checked at run time. Every change goes through the package's
// tool master-wg on the server. QR codes and device profiles carry a device's private key: they are fetched
// only on an explicit click, never cached (getBlob), and the caller revokes their object URL after use.
import { getBlob, getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

export interface WgPeer {
  name: string;
  ipv4: string;
  ipv6: string;
  /** Unix seconds of the last handshake; 0 when never. */
  handshake: number;
  rx: number;
  tx: number;
  /** Whether a profile (and so a QR code) exists on the server. */
  profile: boolean;
  dns: string;
  provider: string;
  keepalive: number;
  mtu: number;
  enabled: boolean;
  online: boolean;
  active_at: number | null;
}

export interface WgNetwork {
  iface: string;
  port: number;
  server4: string;
  subnet4: string;
  server6: string;
  subnet6: string;
  dns: string;
  label: string;
  active: boolean;
  count: number;
  /** Guards the network's settings (64 hex digits); a stale one is refused with 409. */
  revision: string;
  peers: WgPeer[];
}

export interface WgState {
  endpoint: string;
  /** How many networks there may be (wg0 … wg<max-1>). */
  max: number;
  /** UDP ports a new network may not take (the base's and the packages'). */
  reserved: number[];
  defaults: { dns: string; keepalive: number; mtu: number; port: number };
  now: number;
  active_window: number;
  networks: WgNetwork[];
}

export const WG_BASE = "/api/uygulama/wireguard";

const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const isBool = (v: unknown): v is boolean => typeof v === "boolean";
const num = (v: unknown, fallback = 0) => (isNumber(v) ? v : fallback);

function isPeer(v: unknown): v is WgPeer {
  return isObject(v) && isText(v.name) && isText(v.ipv4) && isBool(v.enabled);
}

function peer(v: WgPeer): WgPeer {
  return {
    name: v.name, ipv4: v.ipv4, ipv6: isText(v.ipv6) ? v.ipv6 : "", handshake: num(v.handshake), rx: num(v.rx), tx: num(v.tx),
    profile: v.profile === true, dns: isText(v.dns) ? v.dns : "", provider: isText(v.provider) ? v.provider : "",
    keepalive: num(v.keepalive), mtu: num(v.mtu), enabled: v.enabled, online: v.online === true, active_at: isNumber(v.active_at) ? v.active_at : null,
  };
}

function isNetwork(v: unknown): v is WgNetwork {
  return isObject(v) && isText(v.iface) && /^wg[0-9]$/.test(v.iface) && isNumber(v.port) && isText(v.subnet4) && isBool(v.active) && Array.isArray(v.peers);
}

function network(v: WgNetwork): WgNetwork {
  return {
    iface: v.iface, port: v.port, server4: isText(v.server4) ? v.server4 : "", subnet4: v.subnet4, server6: isText(v.server6) ? v.server6 : "",
    subnet6: isText(v.subnet6) ? v.subnet6 : "", dns: isText(v.dns) ? v.dns : "", label: isText(v.label) ? v.label : "", active: v.active,
    count: num(v.count), revision: isText(v.revision) ? v.revision : "", peers: v.peers.filter(isPeer).map(peer),
  };
}

export async function readWgState(): Promise<WgState> {
  const value = shaped<WgState>(await getJson(`${WG_BASE}/state`), (v) => Array.isArray(v.networks) && isObject(v.defaults));
  const d = value.defaults;
  return {
    endpoint: isText(value.endpoint) ? value.endpoint : "",
    max: num(value.max, 10),
    reserved: Array.isArray(value.reserved) ? value.reserved.filter(isNumber) : [],
    defaults: { dns: isText(d.dns) ? d.dns : "", keepalive: num(d.keepalive, 21), mtu: num(d.mtu, 1420), port: num(d.port, 61001) },
    now: num(value.now, Date.now() / 1000),
    active_window: num(value.active_window, 45),
    networks: value.networks.filter(isNetwork).map(network),
  };
}

const net = (iface: string) => `${WG_BASE}/nets/${encodeURIComponent(iface)}`;
const dev = (iface: string, name: string) => `${net(iface)}/peers/${encodeURIComponent(name)}`;
const done = (data: unknown) => (isObject(data) ? data : {});

export async function addNetwork(port: number, dns: string, label: string): Promise<{ iface: string; port: number }> {
  return shaped(await postJson(`${WG_BASE}/nets`, { port: String(port), dns, label }), (v) => isText(v.iface));
}

export async function saveNetworkSettings(iface: string, dns: string, revision: string, label: string): Promise<Record<string, unknown>> {
  return done(await postJson(`${net(iface)}/ayarlar`, { dns, revision, label }));
}

export async function setNetwork(iface: string, on: boolean): Promise<Record<string, unknown>> {
  return done(await postJson(`${net(iface)}/durum`, { on }));
}

export async function removeNetwork(iface: string): Promise<{ peers: number }> {
  const value = done(await postJson(`${net(iface)}/remove`, { confirm: "onayla" }));
  return { peers: num(value.peers) };
}

export async function regenerateNetwork(iface: string): Promise<{ peers: number }> {
  const value = done(await postJson(`${net(iface)}/reset`, { confirm: "onayla" }));
  return { peers: num(value.peers) };
}

export async function addDevice(iface: string, name: string, dns: string, keepalive: number, mtu: number): Promise<Record<string, unknown>> {
  return done(await postJson(`${net(iface)}/peers`, { name, dns, keepalive, mtu }));
}

export async function removeDevice(iface: string, name: string): Promise<Record<string, unknown>> {
  return done(await postJson(`${dev(iface, name)}/remove`, {}));
}

export async function setDevice(iface: string, name: string, on: boolean): Promise<Record<string, unknown>> {
  return done(await postJson(`${dev(iface, name)}/durum`, { on }));
}

export async function setDeviceKeepalive(iface: string, name: string, keepalive: number): Promise<Record<string, unknown>> {
  return done(await postJson(`${dev(iface, name)}/keepalive`, { keepalive }));
}

export async function setDeviceDns(iface: string, name: string, dns: string): Promise<Record<string, unknown>> {
  return done(await postJson(`${dev(iface, name)}/dns`, { dns }));
}

/** The device's QR code (PNG); contains its private key. */
export function fetchQr(iface: string, name: string): Promise<Blob> {
  return getBlob(`${dev(iface, name)}/qr.png`);
}

/** The device's profile (text); contains its private key. */
export function fetchProfile(iface: string, name: string): Promise<Blob> {
  return getBlob(`${dev(iface, name)}/profile`);
}
