// The applications' reads and actions (DD-271): the list item, one application's detail, a service's log, the
// lifecycle actions and the removal (each a job), a job's result and the network card; Uygulama ekle's draft
// sources, the inspector's dry run, the install's plan and the install (a job); Tanım's plan, its apply (a job)
// and the refresh from an address source. Paths and shapes come from sema.ts (generated from
// panel/master_api.py); a reply without the expected shape is an error, so a page never shows half a value as if
// it were whole. Secret values travel only in these requests' bodies; no reply carries one.
import {
  YOLLAR,
  type Ag,
  type Denetim,
  type DenetimIstegi,
  type Inceleme,
  type KaldirIstegi,
  type KaynakIstegi,
  type KaynakYaniti,
  type KonteynerIsi,
  type KurIstegi,
  type KurPlani,
  type TanimIstegi,
  type TanimPlani,
  type Uygulama,
  type UygulamaAyrinti,
  type UygulamaGunlugu,
  type UygulamaIsi,
  type UygulamaIslemi,
  type UygulamaServisAyrintisi,
  type Yenileme,
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
    // Each port with its access row (rebuild phase 4: its id and the row, an address or a raw port).
    portlar: isList(s.portlar)
      ? s.portlar.filter((p) => isObject(p) && typeof p.port === "number" && isText(p.protokol) && isText(p.id) && isObject(p.erisim) && (p.erisim.tur === "adres" || p.erisim.tur === "ham"))
      : [],
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

/** The WAN rate and the busiest applications' rates (an item without a name or numbers is left out). */
export async function readNetwork(): Promise<Ag> {
  const v = shaped<Ag>(await getJson(YOLLAR.ag), (d) => "rx" in d && "tx" in d);
  const rate = (n: unknown) => typeof n === "number" && Number.isFinite(n);
  return { ...v, uygulamalar: isList(v.uygulamalar) ? v.uygulamalar.filter((a) => isObject(a) && isText(a.ad) && rate(a.indirme) && rate(a.yukleme)) : [] };
}

// ---- Uygulama ekle and Tanım (K2, K3)

/** An inspection with every list checked (an item without its line or text is left out). */
function cleanInspection(v: Inceleme): Inceleme {
  const line = (x: unknown) => isObject(x) && typeof x.line === "number";
  return {
    ...v,
    services: isList(v.services) ? v.services.filter((s) => isObject(s) && isText(s.name)) : [],
    variables: isList(v.variables) ? v.variables : [],
    refusals: isList(v.refusals) ? v.refusals.filter((r) => line(r) && isText(r.text)) : [],
    notes: isList(v.notes) ? v.notes.filter((r) => line(r) && isText(r.text)) : [],
    questions: isList(v.questions) ? v.questions.filter((q) => line(q) && isText(q.id) && isText(q.kind) && isText(q.title)) : [],
    marks: isList(v.marks) ? v.marks.filter((m) => line(m) && isText(m.kind) && isText(m.text)) : [],
  };
}

const isInspection = (v: unknown): v is Inceleme => isObject(v) && isList(v.questions) && isList(v.refusals) && isList(v.marks);
const errorsOf = (v: unknown): Record<string, string> | undefined =>
  isObject(v) ? Object.fromEntries(Object.entries(v).filter((e): e is [string, string] => isText(e[1]))) : undefined;

/** The inspector's dry run (POST …/uygulamalar/denetle): the inspection, and with answers either the errors by
    question or the definition. Nothing is written. */
export async function inspectFile(request: DenetimIstegi): Promise<Denetim> {
  const v = shaped<Denetim>(await postJson(YOLLAR.uygulama_denetle, request), (d) => isInspection(d.inceleme));
  return { ...v, inceleme: cleanInspection(v.inceleme), hatalar: errorsOf(v.hatalar) };
}

/** A draft file (POST …/uygulamalar/kaynak): an address or a container answers with the text at once; an image is
    a job whose result (readJob) is the draft. */
export async function fetchDraft(request: KaynakIstegi): Promise<KaynakYaniti> {
  return shaped(await postJson(YOLLAR.uygulama_kaynak, request), (v) => (isText(v.metin) && isObject(v.kaynak)) || (isText(v.is) && v.is !== ""));
}

/** The install's dry run (POST …/uygulamalar/kur with plan): every check before the first write and what it
    creates, or the errors by question or part. Nothing is written or pulled. */
export async function planInstall(request: KurIstegi): Promise<KurPlani> {
  const v = shaped<KurPlani>(await postJson(YOLLAR.uygulama_kur, { ...request, plan: true }), (d) => isInspection(d.inceleme));
  return { ...v, inceleme: cleanInspection(v.inceleme), hatalar: errorsOf(v.hatalar) };
}

/** The install (POST …/uygulamalar/kur): 202 with the job, followed in İşlemler. */
export async function installApp(request: KurIstegi): Promise<UygulamaIsi> {
  const body: KurIstegi = { metin: request.metin, yanitlar: request.yanitlar, kaynak: request.kaynak };
  return shaped(await postJson(YOLLAR.uygulama_kur, body), (v) => isText(v.is) && v.is !== "");
}

/** Tanım's plan (POST …/{app}/tanim with plan): the difference, or the errors by question. Nothing is written. */
export async function planDefinition(app: string, request: Omit<TanimIstegi, "plan">): Promise<TanimPlani> {
  const v = shaped<TanimPlani>(await postJson(appPath(YOLLAR.uygulama_tanim, app), { ...request, plan: true }), (d) => isInspection(d.inceleme));
  return { ...v, inceleme: cleanInspection(v.inceleme), hatalar: errorsOf(v.hatalar) };
}

/** Tanım applied (POST …/{app}/tanim without plan): the job, followed in İşlemler. */
export async function applyDefinition(app: string, request: Omit<TanimIstegi, "plan">): Promise<UygulamaIsi> {
  return shaped(await postJson(appPath(YOLLAR.uygulama_tanim, app), { ...request, plan: false }), (v) => isText(v.is) && v.is !== "");
}

/** An address source fetched again (POST …/{app}/yenile): its text, the stored answers (the ports' filled from
    their rows) and the questions they do not answer yet. Nothing is written. */
export async function refreshSource(app: string): Promise<Yenileme> {
  const v = shaped<Yenileme>(await postJson(appPath(YOLLAR.uygulama_yenile, app), {}), (d) => isText(d.metin) && isObject(d.yanitlar));
  return { ...v, yanitlar: { ...v.yanitlar, answers: isObject(v.yanitlar.answers) ? v.yanitlar.answers : {} }, yeni_sorular: isList(v.yeni_sorular) ? v.yeni_sorular.filter(isText) : [] };
}
