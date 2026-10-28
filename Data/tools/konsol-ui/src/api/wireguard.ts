// WireGuard, a built-in of the base (DD-271): the WireGuard section's reads and immediate writes under
// /api/konsol/wireguard. Starting or stopping WireGuard and adding, removing, opening, closing or regenerating
// a network are settings changes (DD-275): the page sends them through the settings plan with the state's
// `revizyon`, not from here. Paths and shapes come from sema.ts (generated from panel/master_api.py); a path's
// {iface} and {name} are filled in encoded. Every change goes through master-wg on the server; numbers go
// as integers. QR codes and device profiles carry a device's private key: they are fetched only on an
// explicit click, never cached (getBlob), and the caller revokes their object URL after use.
import {
  YOLLAR,
  type WireGuard,
  type WireGuardAgAyarSonucu,
  type WireGuardAgi,
  type WireGuardCihazEklendi,
  type WireGuardCihazi,
} from "./sema";
import { getBlob, getJson, postJson } from "./http";
import { isObject, isText, shaped } from "./konsol";

const isNumber = (v: unknown): v is number => typeof v === "number" && Number.isFinite(v);
const isBool = (v: unknown): v is boolean => typeof v === "boolean";
const num = (v: unknown, fallback = 0) => (isNumber(v) ? v : fallback);

/** A route's path with its {iface} and {name} filled in. */
function at(template: string, params: { iface: string; name?: string }): string {
  return template.replace(/\{(iface|name)\}/g, (_: string, key: string) => encodeURIComponent((key === "iface" ? params.iface : params.name) ?? ""));
}

function isPeer(v: unknown): v is WireGuardCihazi {
  return isObject(v) && isText(v.name) && isText(v.ipv4) && isBool(v.enabled);
}

function peer(v: WireGuardCihazi): WireGuardCihazi {
  return {
    name: v.name, ipv4: v.ipv4, ipv6: isText(v.ipv6) ? v.ipv6 : "", handshake: num(v.handshake), rx: num(v.rx), tx: num(v.tx),
    profile: v.profile === true, dns: isText(v.dns) ? v.dns : "", provider: isText(v.provider) ? v.provider : "",
    keepalive: num(v.keepalive), mtu: num(v.mtu), enabled: v.enabled, online: v.online === true, active_at: isNumber(v.active_at) ? v.active_at : null,
  };
}

function isNetwork(v: unknown): v is WireGuardAgi {
  return isObject(v) && isText(v.iface) && /^wg[0-9]$/.test(v.iface) && isNumber(v.port) && isText(v.subnet4) && isBool(v.active) && Array.isArray(v.peers);
}

function network(v: WireGuardAgi): WireGuardAgi {
  return {
    iface: v.iface, port: v.port, server4: isText(v.server4) ? v.server4 : "", subnet4: v.subnet4, server6: isText(v.server6) ? v.server6 : "",
    subnet6: isText(v.subnet6) ? v.subnet6 : "", dns: isText(v.dns) ? v.dns : "", label: isText(v.label) ? v.label : "", active: v.active,
    count: num(v.count), revision: isText(v.revision) ? v.revision : "", peers: v.peers.filter(isPeer).map(peer),
  };
}

export async function readWgState(): Promise<WireGuard> {
  const value = shaped<WireGuard>(await getJson(YOLLAR.wireguard), (v) => isBool(v.kurulu) && isBool(v.durduruldu) && Array.isArray(v.networks) && isObject(v.defaults));
  const d = value.defaults;
  return {
    kurulu: value.kurulu,
    durduruldu: value.durduruldu,
    endpoint: isText(value.endpoint) ? value.endpoint : "",
    max: num(value.max, 10),
    reserved: Array.isArray(value.reserved) ? value.reserved.filter(isNumber) : [],
    defaults: { dns: isText(d.dns) ? d.dns : "", keepalive: num(d.keepalive, 21), mtu: num(d.mtu, 1420), port: num(d.port, 61001) },
    now: num(value.now, Date.now() / 1000),
    active_window: num(value.active_window, 45),
    networks: value.networks.filter(isNetwork).map(network),
    revizyon: isText(value.revizyon) ? value.revizyon : "",
  };
}

export async function saveNetworkSettings(iface: string, dns: string, revision: string, label: string): Promise<WireGuardAgAyarSonucu> {
  return shaped(await postJson(at(YOLLAR.wireguard_ag_ayarlar, { iface }), { dns, revision, label }), (v) => isText(v.iface));
}

export async function addDevice(iface: string, name: string, dns: string, keepalive: number, mtu: number): Promise<WireGuardCihazEklendi> {
  return shaped(await postJson(at(YOLLAR.wireguard_cihaz_ekle, { iface }), { name, dns, keepalive, mtu }), (v) => isText(v.name));
}

export async function removeDevice(iface: string, name: string): Promise<void> {
  await postJson(at(YOLLAR.wireguard_cihaz_kaldir, { iface, name }), {});
}

export async function setDevice(iface: string, name: string, on: boolean): Promise<void> {
  await postJson(at(YOLLAR.wireguard_cihaz_durum, { iface, name }), { on });
}

export async function setDeviceKeepalive(iface: string, name: string, keepalive: number): Promise<void> {
  await postJson(at(YOLLAR.wireguard_cihaz_keepalive, { iface, name }), { keepalive });
}

export async function setDeviceDns(iface: string, name: string, dns: string): Promise<void> {
  await postJson(at(YOLLAR.wireguard_cihaz_dns, { iface, name }), { dns });
}

/** The device's QR code (PNG); contains its private key. */
export function fetchQr(iface: string, name: string): Promise<Blob> {
  return getBlob(at(YOLLAR.wireguard_qr, { iface, name }));
}

/** The device's profile (text); contains its private key. */
export function fetchProfile(iface: string, name: string): Promise<Blob> {
  return getBlob(at(YOLLAR.wireguard_profil, { iface, name }));
}
