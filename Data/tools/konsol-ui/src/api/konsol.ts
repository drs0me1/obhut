// The applications' reads and actions (DD-271, phase 3): the list item, one application's detail, a
// service's log, the lifecycle actions and the removal (each a job), a job's result, the network card and
// repair. Paths and shapes come from sema.ts (generated from panel/master_api.py); a reply without the
// expected shape is an error, so a page never shows half a value as if it were whole.
import {
  YOLLAR,
  type Ag,
  type KaldirIstegi,
  type KonteynerIsi,
  type Onarim,
  type OnarimBasladi,
  type Uygulama,
  type UygulamaAyrinti,
  type UygulamaGunlugu,
  type UygulamaIsi,
  type UygulamaIslemi,
  type UygulamaServisAyrintisi,
} from "./sema";
import { ApiError, getJson, postJson } from "./http";

export const isObject = (v: unknown): v is Record<string, unknown> => typeof v === "object" && v !== null && !Array.isArray(v);
export const isText = (v: unknown): v is string => typeof v === "string";
const isList = Array.isArray;

/** An application the pages can show; one without the expected shape is left out (or refused). */
export function isApp(v: unknown): v is Uygulama {
  return (
    isObject(v) && isText(v.ad) && isText(v.durum) && isText(v.bicim) && isList(v.servisler) && isObject(v.kaynak) &&
    isText(v.guncelleme) && isList(v.eylemler) && isText(v.revizyon) && isText(v.koken) && typeof v.uyari === "number" &&
    typeof v.durduruldu === "boolean"
  );
}

/** The item with its services each checked (one without a name or state is left out). */
export function cleanApp(app: Uygulama): Uygulama {
  return { ...app, servisler: app.servisler.filter((s) => isObject(s) && isText(s.ad) && isText(s.durum)), eylemler: app.eylemler.filter(isText) };
}

/** The reply as T when it passes `test`; otherwise an error, so a page never shows half a value as whole. */
export function shaped<T>(data: unknown, test: (v: Record<string, unknown>) => boolean): T {
  if (!isObject(data) || !test(data)) throw new ApiError(0, "Sunucunun yanıtı beklenen biçimde değil.");
  return data as T;
}

const query = (path: string, params: Record<string, string>) => `${path}?${new URLSearchParams(params).toString()}`;
/** A route of one application ({app} in the route table). */
const appPath = (path: string, app: string) => path.replace("{app}", encodeURIComponent(app));

function cleanService(s: UygulamaServisAyrintisi): UygulamaServisAyrintisi {
  return {
    ...s,
    portlar: isList(s.portlar) ? s.portlar.filter((p) => isObject(p) && typeof p.port === "number" && isText(p.protokol) && isText(p.kullanim)) : [],
    baglamalar: isList(s.baglamalar) ? s.baglamalar.filter((m) => isObject(m) && isText(m.hedef) && isText(m.tur)) : [],
    gizliler: isList(s.gizliler) ? s.gizliler.filter(isText) : [],
  };
}

export async function readApp(app: string): Promise<UygulamaAyrinti> {
  const v = shaped<UygulamaAyrinti>(await getJson(appPath(YOLLAR.uygulama, app)), (d) =>
    isApp(d.uygulama) && isList(d.servisler) && isList(d.uyarilar) && isObject(d.koken) && isText(d.metin) && isObject(d.yanitlar));
  return {
    ...v,
    uygulama: cleanApp(v.uygulama),
    servisler: v.servisler.filter((s) => isObject(s) && isText(s.ad) && isText(s.durum)).map(cleanService),
    gizliler: isList(v.gizliler) ? v.gizliler.filter((g) => isObject(g) && isText(g.ad)) : [],
    uyarilar: v.uyarilar.filter((u) => isObject(u) && isText(u.metin)),
    yanitlar: { ...v.yanitlar, answers: isObject(v.yanitlar.answers) ? v.yanitlar.answers : {} },
    birimler: isList(v.birimler) ? v.birimler.filter(isText) : [],
  };
}

export async function readAppLog(app: string, servis: string, lines = 200): Promise<UygulamaGunlugu> {
  return shaped(await getJson(query(appPath(YOLLAR.uygulama_gunlugu, app), { servis, satir: String(lines) })), (v) => isList(v.satirlar));
}

/** Başlat, durdur, yeniden başlat, güncelle: 202 with the job, followed in İşlemler. */
export async function startAppAction(app: string, request: UygulamaIslemi): Promise<UygulamaIsi> {
  return shaped(await postJson(appPath(YOLLAR.uygulama_islemi, app), request), (v) => isText(v.is) && v.is !== "");
}

/** Kaldır, keeping or deleting the data (deleting carries the typed name): 202 with the job. */
export async function removeApp(app: string, request: KaldirIstegi): Promise<UygulamaIsi> {
  return shaped(await postJson(appPath(YOLLAR.uygulama_kaldir, app), request), (v) => isText(v.is) && v.is !== "");
}

/** A finished job's record (GET …/konteynerler/islem?id=): its result, such as whether an image update changed anything. */
export async function readJob(id: string): Promise<KonteynerIsi & { result: Record<string, unknown> | null }> {
  const v = shaped<KonteynerIsi>(await getJson(query(YOLLAR.konteyner_isi, { id })), (d) => isText(d.id) && isText(d.state));
  return { ...v, result: isObject(v.result) ? v.result : null };
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
