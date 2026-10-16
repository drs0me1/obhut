// The phase 2 reads and actions (DD-258): applications, their detail, log and lifecycle, the network card
// and repair. Paths and shapes come from sema.ts (generated from panel/master_api.py); a reply without the
// expected shape is an error, so a page never shows half a value as if it were whole.
import {
  YOLLAR,
  type Ag,
  type Onarim,
  type OnarimBasladi,
  type Uygulama,
  type UygulamaAyrinti,
  type UygulamaGunlugu,
  type UygulamaIslemi,
  type UygulamaIslemiBasladi,
} from "./sema";
import { ApiError, getJson, postJson } from "./http";

export const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
export const isText = (v: unknown): v is string => typeof v === "string";
const isCell = (v: unknown) => isObject(v) && isText(v.durum) && Array.isArray(v.adresler);

/** An application the pages can show; one without the expected shape is left out (or refused). */
export function isApp(v: unknown): v is Uygulama {
  return (
    isObject(v) && isText(v.id) && isText(v.ad) && isText(v.tur) && isText(v.aciklama) && isText(v.durum) &&
    isCell(v.tailscale) && isCell(v.internet) && isObject(v.kaynak) && isObject(v.adres) && Array.isArray(v.eylemler)
  );
}

/** The reply as T when it passes `test`; otherwise an error, so a page never shows half a value as whole. */
export function shaped<T>(data: unknown, test: (v: Record<string, unknown>) => boolean): T {
  if (!isObject(data) || !test(data)) throw new ApiError(0, "Sunucunun yanıtı beklenen biçimde değil.");
  return data as T;
}

const query = (path: string, params: Record<string, string>) => `${path}?${new URLSearchParams(params).toString()}`;

export async function readAppDetail(id: string): Promise<UygulamaAyrinti> {
  return shaped(await getJson(query(YOLLAR.uygulama_ayrinti, { id })), (v) => isApp(v.uygulama) && "konteyner" in v && "erisim" in v);
}

export async function readAppLog(id: string, lines = 200): Promise<UygulamaGunlugu> {
  return shaped(await getJson(query(YOLLAR.uygulama_gunlugu, { id, satir: String(lines) })), (v) => Array.isArray(v.satirlar));
}

export async function startAppAction(request: UygulamaIslemi): Promise<UygulamaIslemiBasladi> {
  return shaped(await postJson(YOLLAR.uygulama_islemi, request), (v) => typeof v.id === "string");
}

export async function readNetwork(): Promise<Ag> {
  return shaped(await getJson(YOLLAR.ag), (v) => "rx" in v && "tx" in v);
}

export async function readRepair(): Promise<Onarim> {
  return shaped(await getJson(YOLLAR.onarim), (v) => typeof v.baslatilabilir === "boolean");
}

export async function startRepair(): Promise<OnarimBasladi> {
  return shaped(await postJson(YOLLAR.onarim_baslat, { kip: "onar" }), (v) => typeof v.kip === "string");
}
