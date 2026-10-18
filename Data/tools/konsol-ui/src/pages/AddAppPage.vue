<!-- Uygulama ekle (K2; rebuild.md 4.2, 4.5; DD-279): a full-window page of its own (#/uygulama-ekle) in four steps,
     with its head (the way back to Uygulamalar and the steps) and its bar of actions in sight while the steps scroll.
     Kaynak — a file pasted, uploaded or dropped (read here, at most 256 KiB of UTF-8), an https address, an image name
     (a job that pulls it; its log shows here) or an existing standalone container (Uygulamalar.kaynaklar); each of
     the last three becomes a draft file first (POST …/uygulamalar/kaynak).
     Denetçi — on a wide screen the file beside the questions, on a phone one of the two: the file with its line
     numbers and the inspector's marks (it can be corrected here; the question in hand lights its line and a click on
     a marked line shows its question), the refusals that stop the flow with their lines, the notes, the
     application's name and the questions by service (QuestionList); the file and the answers are checked again with
     POST …/denetle as they change.
     Plan — POST …/kur with plan: every check an install makes before its first write and what it creates; a refusal
     names its question and leads back to it.
     Kurulum — POST …/kur, then the job's record read every second (GET …/islem): its log as it grows and its end. A
     failed install has been rolled back; the answers stay, and the way back leads to the question the job names (a
     direct start) or to the inspector. A finished install stays on its log until the operator moves on.
     Secret values live only in this page while it is open: never in the address, the browser's storage or a log;
     leaving forgets them. Leaving with something entered asks first, inside Konsol too; leaving while the job runs
     does not stop it (İşlemler follows it). -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, reactive, ref, watch } from "vue";
import { RouterLink, onBeforeRouteLeave, useRouter, type RouteLocationNormalized } from "vue-router";
import { Icon, type IconName } from "../components/icons";
import Field from "../components/ui/Field.vue";
import Modal from "../components/ui/Modal.vue";
import FileEditor from "./app/FileEditor.vue";
import JobLog from "./app/JobLog.vue";
import QuestionList from "./app/QuestionList.vue";
import {
  FILE_LIMIT,
  appNameProblem,
  formQuestions,
  installAnswers,
  lineMarks,
  localProblem,
  questionTitle,
  syncDrafts,
  textBytes,
  waiting,
  waitingCount,
  type AnswerState,
} from "./app/answers";
import { fetchDraft, inspectFile, installApp, planInstall, readJob } from "../api/konsol";
import { live, refreshApps } from "../live";
import { useLeaveGuard } from "../leave";
import { address } from "../links";
import { appRoute } from "../router";
import { usePageHead } from "../page";
import { servicesText } from "../apps";
import { clock } from "../format";
import type { Inceleme, IsSatiri, KaynakTuru, KonteynerIsi, KurIstegi, KurPlani, Soru } from "../api/sema";

const router = useRouter();
usePageHead(() => ({ title: "Uygulama ekle" }));

const SOURCES: readonly { id: KaynakTuru; icon: IconName; title: string; text: string; go: string; busy: string }[] = [
  { id: "dosya", icon: "file", title: "Dosya", text: "Compose ya da Kubernetes YAML: yapıştır, yükle ya da sürükle", go: "Denetle", busy: "Denetleniyor…" },
  { id: "adres", icon: "globe", title: "Adresten", text: "https ile bir Compose ya da Kubernetes dosyası", go: "İndir ve denetle", busy: "İndiriliyor…" },
  { id: "imaj", icon: "box", title: "İmaj adından", text: "Obhut taslak bir dosya üretir", go: "Taslak üret", busy: "Taslak üretiliyor…" },
  { id: "konteyner", icon: "server", title: "Var olan konteyner", text: "Elle başlatılmış bir konteyner yönetime alınır", go: "Dosyaya çevir", busy: "Çevriliyor…" },
];
const STEPS = ["Kaynak", "Denetçi", "Plan", "Kurulum"] as const;
const HTTPS = address("https", "", "");
const URL_HINT = address("https", "depo.example.org", "/compose.yaml");
/** What an install does, in its order (the worker's steps); the plan shows it before "Kur". */
const ORDER = [
  "Kayıt yazılır, ağ koruması uygulanır",
  "Klasörler oluşturulur",
  "İmajlar indirilir ve özetle sabitlenir",
  "Gizli değerler Podman secret olur",
  "Birimler yazılır ve başlatılır",
  "Hazır olması beklenir (sağlık denetimi)",
  "Adresler yayımlanır (yalnız Tailscale)",
] as const;
type Job = KonteynerIsi & { result: Record<string, unknown> | null; gunluk: IsSatiri[] };

// ---- the flow's state; everything is forgotten when the page goes
const step = ref<1 | 2 | 3 | 4>(1);
const source = ref<KaynakTuru | "">("");
const pasted = ref("");
const uploaded = ref("");
const url = ref("");
const image = ref("");
const container = ref("");
const sourceError = ref("");
const fetching = ref(false);
const draftLog = ref<IsSatiri[]>([]);
let draftTimer: number | undefined;

const text = ref("");
const kaynak = ref<KurIstegi["kaynak"]>({ tur: "dosya" });
const origin = ref("");
const inspection = ref<Inceleme | null>(null);
const state = reactive<AnswerState>({ name: "", drafts: {} });
const checkErrors = ref<Record<string, string>>({});
const sentIds = ref<Set<string>>(new Set());
const checking = ref(false);
const checkError = ref("");
/** Errors the plan found, each kept while its answer is what the plan saw. */
const planErrors = ref<Record<string, { text: string; seen: string }>>({});

const plan = ref<KurPlani | null>(null);
const planning = ref(false);
const planError = ref("");
const submitting = ref(false);
const installError = ref("");
const job = ref<Job | null>(null);
const jobName = ref("");
const jobReadError = ref("");
/** While the job runs its time is counted here (the browser's clock may differ from the server's). */
const now = ref(Date.now());
let sentAt = 0;
let jobId = "";
let jobTimer: number | undefined;

/** On a phone the inspector shows the questions or the file. */
const pane = ref<"sorular" | "dosya">("sorular");
const activeLine = ref<number | null>(null);
const leaveTo = ref<RouteLocationNormalized | null>(null);
let leaving = false;

const editor = ref<InstanceType<typeof FileEditor> | null>(null);
const page = ref<HTMLElement | null>(null);

const root = computed(() => live.kaynaklar?.root ?? "");
const domain = computed(() => live.erisim?.alan || live.kaynaklar?.domain || "");
const containers = computed(() => live.uygulamalar?.kaynaklar ?? []);
/** Tailscale names other rows hold (Konsol's and Paylaşımlar' are reserved anyway). */
const taken = computed(() => (live.erisim?.hizmetler ?? []).flatMap((h) => (h.satir?.tur === "adres" ? [h.satir.ad] : [])));
const chosen = computed(() => SOURCES.find((s) => s.id === source.value) ?? null);
const message = (err: unknown): string => (err instanceof Error ? err.message : String(err));

function stopTimers(): void {
  clearInterval(draftTimer);
  clearInterval(jobTimer);
  clearTimeout(checkTimer);
  draftTimer = jobTimer = checkTimer = undefined;
}

/** Back to an empty Kaynak (Başka uygulama ekle). */
function reset(): void {
  stopTimers();
  step.value = 1;
  source.value = "";
  pasted.value = uploaded.value = url.value = image.value = container.value = "";
  sourceError.value = "";
  fetching.value = false;
  draftLog.value = [];
  text.value = "";
  kaynak.value = { tur: "dosya" };
  origin.value = "";
  inspection.value = null;
  state.name = "";
  state.drafts = {};
  checkErrors.value = {};
  sentIds.value = new Set();
  checking.value = false;
  checkError.value = "";
  planErrors.value = {};
  plan.value = null;
  planning.value = false;
  planError.value = "";
  submitting.value = false;
  installError.value = "";
  job.value = null;
  jobName.value = "";
  jobReadError.value = "";
  jobId = "";
  pane.value = "sorular";
  activeLine.value = null;
  checkSeq += 1;
  planSeq += 1;
  void nextTick(() => page.value?.querySelector<HTMLElement>("h1")?.focus());
}
onBeforeUnmount(stopTimers);

// ---- leaving: asked while something is entered; a running or finished install has nothing to lose
const jobRunning = computed(() => step.value === 4 && (job.value === null || job.value.state === "running"));
const jobDone = computed(() => step.value === 4 && job.value?.state === "done");
const dirty = computed(() => Boolean(pasted.value.trim() || text.value.trim()) && !jobRunning.value && !jobDone.value);
useLeaveGuard(dirty);

onBeforeRouteLeave((to) => {
  if (leaving || !dirty.value) return true;
  leaveTo.value = to;
  return false;
});

function confirmLeave(): void {
  const to = leaveTo.value;
  leaveTo.value = null;
  if (!to) return;
  leaving = true;
  void router.push(to.fullPath);
}

function close(): void {
  void router.push("/uygulamalar");
}

// ---- Kaynak
const sourceReady = computed(() => {
  if (fetching.value) return false;
  if (source.value === "dosya") return pasted.value.trim() !== "";
  if (source.value === "adres") return url.value.trim() !== "";
  if (source.value === "imaj") return image.value.trim() !== "";
  if (source.value === "konteyner") return container.value !== "";
  return false;
});

const fileInput = ref<HTMLInputElement | null>(null);
const dropping = ref(false);

/** A file chosen or dropped from this device: read here (never uploaded as it is), at most 256 KiB, UTF-8 only. */
async function readFile(file: File): Promise<void> {
  sourceError.value = "";
  if (file.size > FILE_LIMIT) {
    sourceError.value = `${file.name} çok büyük (en çok ${FILE_LIMIT / 1024} KiB).`;
    return;
  }
  try {
    pasted.value = new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer());
    uploaded.value = file.name;
  } catch {
    sourceError.value = `${file.name} UTF-8 bir metin dosyası değil.`;
  }
}

function onUpload(event: Event): void {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (file) void readFile(file);
}

function onDrop(event: DragEvent): void {
  dropping.value = false;
  const file = event.dataTransfer?.files?.[0];
  if (file) void readFile(file);
}

function begin(textValue: string, from: KurIstegi["kaynak"], where: string): void {
  text.value = textValue;
  kaynak.value = from;
  origin.value = where;
  inspection.value = null;
  state.name = "";
  state.drafts = {};
  checkErrors.value = {};
  planErrors.value = {};
  pane.value = "sorular";
  step.value = 2;
  void check();
}

async function nextFromSource(): Promise<void> {
  if (!sourceReady.value) return;
  sourceError.value = "";
  if (source.value === "dosya") {
    if (textBytes(pasted.value) > FILE_LIMIT) {
      sourceError.value = `Dosya çok büyük (en çok ${FILE_LIMIT / 1024} KiB).`;
      return;
    }
    begin(pasted.value, { tur: "dosya" }, uploaded.value ? `${uploaded.value} (yüklenen dosya)` : "Yapıştırılan dosya");
    return;
  }
  if (source.value === "adres" && !url.value.trim().startsWith(HTTPS)) {
    sourceError.value = "Adres https ile başlamalı.";
    return;
  }
  fetching.value = true;
  try {
    const request =
      source.value === "adres" ? ({ tur: "adres", adres: url.value.trim() } as const)
      : source.value === "imaj" ? ({ tur: "imaj", imaj: image.value.trim() } as const)
      : ({ tur: "konteyner", konteyner: container.value } as const);
    const reply = await fetchDraft(request);
    if ("is" in reply) {
      followDraft(reply.is, request.tur === "imaj" ? request.imaj : "");
      return;
    }
    fetching.value = false;
    begin(reply.metin, reply.kaynak, whereOf(reply.kaynak));
  } catch (err) {
    fetching.value = false;
    sourceError.value = message(err);
  }
}

const whereOf = (k: KurIstegi["kaynak"]): string =>
  k.tur === "adres" ? k.adres : k.tur === "imaj" ? `İmaj adından taslak · ${k.imaj}` : k.tur === "konteyner" ? `${k.konteyner} konteynerinden taslak` : "Yapıştırılan dosya";

/** An image's draft is a job (it pulls the image): its log shows here until its result is the draft. */
function followDraft(id: string, ref: string): void {
  draftLog.value = [];
  const read = async () => {
    try {
      const j = await readJob(id);
      if (!fetching.value) return;
      draftLog.value = j.gunluk;
      if (j.state === "running") return;
      clearInterval(draftTimer);
      fetching.value = false;
      const result = j.result;
      if (j.state === "done" && result && typeof result.metin === "string" && typeof result.kaynak === "object" && result.kaynak) {
        const from = result.kaynak as KurIstegi["kaynak"];
        draftLog.value = [];
        begin(result.metin, from, whereOf(from.tur === "imaj" ? from : { tur: "imaj", imaj: ref }));
      } else sourceError.value = typeof j.error === "string" && j.error ? j.error : "Taslak üretilemedi.";
    } catch (err) {
      clearInterval(draftTimer);
      fetching.value = false;
      sourceError.value = message(err);
    }
  };
  clearInterval(draftTimer);
  draftTimer = window.setInterval(() => void read(), 1000);
  void read();
}

// ---- Denetçi: the file and the answers checked as they change
let checkSeq = 0;
let checkTimer: number | undefined;
const answers = computed(() => installAnswers(inspection.value, state, root.value));
const answerKey = (id: string): string => (id === "name" ? state.name.trim() : JSON.stringify(answers.value.answers[id] ?? null));

function schedule(delay: number): void {
  clearTimeout(checkTimer);
  checkTimer = window.setTimeout(() => void check(), delay);
}

async function check(): Promise<void> {
  clearTimeout(checkTimer);
  if (step.value !== 2) return;
  if (textBytes(text.value) > FILE_LIMIT) {
    checkError.value = `Dosya çok büyük (en çok ${FILE_LIMIT / 1024} KiB).`;
    return;
  }
  const mine = ++checkSeq;
  const first = inspection.value === null;
  const sent = first ? null : answers.value;
  const request = sent ? { metin: text.value, yanitlar: sent } : { metin: text.value };
  checking.value = true;
  try {
    const reply = await inspectFile(request);
    if (mine !== checkSeq) return;
    const before = new Set(formQuestions(inspection.value).map((q) => q.id));
    inspection.value = reply.inceleme;
    const suggest = reply.inceleme.questions.find((q) => q.kind === "name");
    if (!state.name && suggest?.kind === "name") state.name = suggest.suggest;
    syncDrafts(state, reply.inceleme, null, root.value);
    checkErrors.value = reply.hatalar ?? {};
    sentIds.value = new Set(sent ? ["name", ...Object.keys(sent.answers)] : []);
    checkError.value = "";
    const fresh = formQuestions(reply.inceleme).map((q) => q.id);
    // New questions (the first read, or a file that changed): check once more with their answers.
    if (first || fresh.length !== before.size || fresh.some((id) => !before.has(id))) schedule(0);
  } catch (err) {
    if (mine === checkSeq) checkError.value = message(err);
  } finally {
    if (mine === checkSeq) checking.value = false;
  }
}

watch(text, () => {
  if (step.value === 2) schedule(500);
});
watch(() => JSON.stringify(answers.value), () => {
  if (step.value === 2 && inspection.value) schedule(400);
});

const refusals = computed(() => inspection.value?.refusals ?? []);
const notes = computed(() => inspection.value?.notes ?? []);
const marks = computed(() => lineMarks(inspection.value));
const questions = computed(() => formQuestions(inspection.value));
const waitingN = computed(() => waitingCount(inspection.value, state, null));
const FORMATS: Record<string, string> = { compose: "Compose", kubernetes: "Kubernetes YAML" };
const formatText = computed(() => (inspection.value ? (inspection.value.format ? FORMATS[inspection.value.format] : "Tanınmadı") : "Okunuyor…"));
const answeredText = computed(() => {
  const total = questions.value.length;
  return total ? `${total - waitingN.value}/${total} yanıtlandı` : "Soru yok";
});

/** Every error a question shows: the plan's (while its answer is unchanged), then the inspector's. */
const errors = computed<Record<string, string>>(() => {
  const out: Record<string, string> = { ...checkErrors.value };
  for (const [id, e] of Object.entries(planErrors.value)) if (answerKey(id) === e.seen) out[id] = e.text;
  return out;
});
const shown = computed(() => new Set([...sentIds.value, ...Object.keys(planErrors.value)]));
const nameError = computed(() => appNameProblem(state.name.trim()) || (shown.value.has("name") ? (errors.value.name ?? "") : ""));
const localErrors = computed(() => questions.value.some((q) => localProblem(q, state.drafts[q.id], state.drafts, taken.value)));
const fileError = computed(() => (refusals.value.length ? "" : (checkErrors.value.dosya ?? "")));
const canPlan = computed(
  () => Boolean(inspection.value?.format) && !refusals.value.length && !waitingN.value && !nameError.value && !localErrors.value && !checking.value &&
    !Object.keys(errors.value).some((id) => shown.value.has(id)),
);
const inspectText = computed(() => {
  if (!inspection.value) return "Denetleniyor…";
  if (refusals.value.length) return `${refusals.value.length} satır kurulumu durduruyor`;
  if (waitingN.value) return `${waitingN.value} soru yanıt bekliyor`;
  if (checking.value) return "Denetleniyor…";
  return "Bütün sorular yanıtlandı";
});

/** A line of the file: shown in the editor (on a phone the file comes into view first). */
async function showLine(line: number): Promise<void> {
  pane.value = "dosya";
  await nextTick();
  editor.value?.reveal(line);
}

/** The question in hand lights its line in the file, which scrolls to it. */
function onActive(q: Soru): void {
  activeLine.value = q.line;
  editor.value?.show(q.line);
}

/** A click on a marked line of the file shows its question beside it (wide screens; on a phone the file stays). */
function onPick(line: number): void {
  if (!window.matchMedia("(min-width: 901px)").matches) return;
  const q = questions.value.find((x) => x.line === line);
  if (!q) return;
  activeLine.value = line;
  page.value?.querySelector<HTMLElement>(`[data-soru="${CSS.escape(q.id)}"]`)?.scrollIntoView({ block: "nearest" });
}

/** Back to the question a refusal or a failed install names, its error beside it. */
async function toQuestion(id: string): Promise<void> {
  step.value = 2;
  pane.value = "sorular";
  await nextTick();
  const target = id === "name" ? page.value?.querySelector<HTMLElement>("#uygulama-adi") : page.value?.querySelector<HTMLElement>(`[data-soru="${CSS.escape(id)}"]`);
  target?.scrollIntoView({ block: "center" });
  (target?.matches("input") ? target : target?.querySelector<HTMLElement>("input:not([disabled]), .q-card button:not(.q-line):not([disabled])") ?? target)?.focus({ preventScroll: true });
}

function nextWaiting(): void {
  const q = questions.value.find((x) => waiting(x, state.drafts[x.id], null));
  if (q) void toQuestion(q.id);
  else if (nameError.value) void toQuestion("name");
}

function back(): void {
  if (submitting.value) return;
  planSeq += 1;
  planning.value = false;
  if (step.value >= 3) {
    step.value = 2;
    void check();
  } else if (step.value === 2) {
    checkSeq += 1;
    clearTimeout(checkTimer);
    checking.value = false;
    step.value = 1;
  }
}

// ---- Plan
let planSeq = 0;
const PARTS: Record<string, string> = { dosya: "Dosya", name: "Uygulama adı", podman: "Podman", portlar: "Portlar", kaynak: "Kaynak konteyner" };
const planProblems = computed(() =>
  Object.entries(plan.value?.hatalar ?? {}).map(([id, text]) => {
    const q = inspection.value?.questions.find((x) => x.id === id && x.kind !== "name");
    return { id, message: text, label: q ? questionTitle(q) : (PARTS[id] ?? id), question: Boolean(q) || id === "name" };
  }),
);

async function toPlan(): Promise<void> {
  if (!canPlan.value) return;
  step.value = 3;
  const mine = ++planSeq;
  plan.value = null;
  planError.value = "";
  installError.value = "";
  planning.value = true;
  try {
    const value = await planInstall({ metin: text.value, yanitlar: answers.value, kaynak: kaynak.value });
    if (mine !== planSeq) return;
    plan.value = value;
    // A question's refusal shows beside it (until its answer changes); a part's only here.
    const ids = new Set(["name", ...formQuestions(value.inceleme).map((q) => q.id)]);
    const kept: Record<string, { text: string; seen: string }> = {};
    for (const [id, text] of Object.entries(value.hatalar ?? {})) if (ids.has(id)) kept[id] = { text, seen: answerKey(id) };
    planErrors.value = kept;
  } catch (err) {
    if (mine === planSeq) planError.value = message(err);
  } finally {
    if (mine === planSeq) planning.value = false;
  }
}

const ozet = computed(() => plan.value?.ozet ?? null);
const startLine = (s: NonNullable<typeof ozet.value>["servisler"][number]) =>
  `${s.ad}: ${s.baslangic === "direct" ? `doğrudan ${s.kullanici ?? ""}`.trim() : "root olarak"}`;
type Line = { text: string; mono: boolean };
const plain = (value: string): Line => ({ text: value, mono: false });
const code = (value: string): Line => ({ text: value, mono: true });
const orNone = (lines: Line[]): Line[] => (lines.length ? lines : [plain("yok")]);
const planBoxes = computed(() => {
  const o = ozet.value;
  if (!o) return [];
  const addresses = o.erisim.flatMap((r) => (r.satir.tur === "adres" ? [code(r.adres ?? `${r.satir.ad}.${domain.value}`)] : []));
  const raw = o.erisim.filter((r) => r.satir.tur === "ham").map((r) => plain(`${r.servis} · ${r.port}/${r.protokol.toUpperCase()} · kapalı`));
  const srv = o.servisler.flatMap((s) => s.baglamalar.filter((m) => m.tur === "srv" && m.yol).map((m) => code(`${m.yol}${m.salt_okunur ? " · salt okunur" : ""}`)));
  return [
    { key: "uygulama", title: "Uygulama", lines: [plain(`${o.ad} · ${servicesText(o.servisler.length)}`), ...(o.pod ? [code(`pod ${o.pod}`)] : []), code(o.ag)] },
    { key: "adresler", title: "Adresler", lines: orNone(addresses) },
    { key: "ham", title: "Ham portlar", lines: orNone(raw) },
    { key: "klasorler", title: "Klasörler", lines: orNone([...o.klasorler.map(code), ...srv]) },
    { key: "gizliler", title: "Gizli değerler", lines: o.gizliler.length ? [plain(`${o.gizliler.length} · Podman secret`), ...o.gizliler.map((g) => code(g.ad))] : orNone([]) },
    { key: "baslatma", title: "Başlatma", lines: o.servisler.map((s) => plain(startLine(s))) },
    { key: "imajlar", title: "İmajlar", lines: orNone(o.imajlar.map(code)) },
  ];
});

// ---- Kurulum: the job and its log, read every second until it ends
async function install(): Promise<void> {
  if (!ozet.value || planProblems.value.length || submitting.value || planning.value) return;
  submitting.value = true;
  installError.value = "";
  try {
    const reply = await installApp({ metin: text.value, yanitlar: answers.value, kaynak: kaynak.value });
    jobName.value = reply.ad;
    sentAt = Date.now();
    job.value = null;
    jobReadError.value = "";
    step.value = 4;
    followJob(reply.is);
    void refreshApps();
    void nextTick(() => page.value?.querySelector<HTMLElement>("[data-testid=install-status]")?.focus());
  } catch (err) {
    installError.value = message(err);
  } finally {
    submitting.value = false;
  }
}

function followJob(id: string): void {
  jobId = id;
  clearInterval(jobTimer);
  const read = async () => {
    now.value = Date.now();
    try {
      const value = await readJob(id);
      if (jobId !== id) return;
      job.value = value;
      jobReadError.value = "";
      if (value.state === "running") return;
      clearInterval(jobTimer);
      jobTimer = undefined;
      void refreshApps();
    } catch (err) {
      if (jobId === id) jobReadError.value = message(err);
    }
  };
  jobTimer = window.setInterval(() => void read(), 1000);
  void read();
}

const jobFailed = computed(() => step.value === 4 && job.value?.state === "failed");
const jobLines = computed(() => job.value?.gunluk ?? []);
const elapsed = computed(() => {
  const j = job.value;
  const ended = typeof j?.created_at === "number" && typeof j.finished_at === "number" ? j.finished_at - j.created_at : null;
  const s = Math.max(0, ended ?? Math.floor((now.value - sentAt) / 1000));
  return s < 60 ? `${s} sn` : `${Math.floor(s / 60)} dk ${s % 60} sn`;
});
/** The question a failed install names (a direct start that stopped at once), when this file still asks it. */
const blamed = computed(() => {
  const id = typeof job.value?.soru === "string" ? job.value.soru : "";
  return questions.value.find((q) => q.id === id) ?? null;
});
const retryText = computed(() => (blamed.value?.kind === "start" ? "Başlatma sorusuna dön" : blamed.value ? "Soruya dön" : "Denetçi'ye dön"));

function retry(): void {
  const named = blamed.value;
  plan.value = null;
  planErrors.value = {};
  job.value = null;
  jobId = "";
  if (named) void toQuestion(named.id);
  else {
    step.value = 2;
    void check();
  }
}

function openApp(): void {
  void router.push(appRoute(jobName.value));
}

const barText = computed(() => {
  if (step.value === 1) return `Compose ya da Kubernetes YAML · en çok ${FILE_LIMIT / 1024} KiB`;
  if (step.value === 2) return inspectText.value;
  if (step.value === 3) return planning.value ? "Plan hazırlanıyor…" : planProblems.value.length || planError.value ? "Kurulum yapılamaz" : ozet.value ? "Bütün denetimler geçti" : "";
  if (jobRunning.value) return "Ayrılırsanız kurulum sürer; İşlemler'den izlenir.";
  if (jobFailed.value) return "Yanıtlarınız duruyor; düzeltip yeniden kurabilirsiniz.";
  return "Tamamlandı";
});
</script>

<template>
  <div ref="page" class="add-page" data-testid="add-flow" :data-adim="step">
    <header class="add-head">
      <RouterLink to="/uygulamalar" class="add-back" data-eylem="geri-don"><Icon name="chevron" class="flip" :size="16" />Uygulamalar</RouterLink>
      <h1 tabindex="-1">Uygulama ekle</h1>
      <ol class="flow-steps add-steps" aria-label="Adımlar">
        <li v-for="(label, i) in STEPS" :key="label" :class="{ 'flow-step-on': step === i + 1, 'flow-step-done': step > i + 1 || (i === 3 && jobDone) }"
          :aria-current="step === i + 1 ? 'step' : undefined">
          <span class="flow-step-num" aria-hidden="true"><Icon v-if="step > i + 1 || (i === 3 && jobDone)" name="check" :size="14" /><template v-else>{{ i + 1 }}</template></span>{{ label }}
        </li>
      </ol>
      <button type="button" class="icon-btn add-close" aria-label="Kapat" data-eylem="kapat" @click="close"><Icon name="close" /></button>
    </header>

    <!-- 1 · Kaynak -->
    <div v-if="step === 1" class="add-body add-body-1">
      <fieldset class="src-cards add-sources">
        <legend class="add-pane-title">Kaynak</legend>
        <label v-for="s in SOURCES" :key="s.id" class="src-card" :data-kaynak="s.id">
          <input v-model="source" type="radio" name="uygulama-kaynak" :value="s.id" :disabled="fetching" />
          <span class="sev sev-accent" aria-hidden="true"><Icon :name="s.icon" :size="17" /></span>
          <span class="src-text"><strong>{{ s.title }}</strong><span>{{ s.text }}</span></span>
        </label>
      </fieldset>

      <section class="add-pane" aria-label="Kaynağın ayrıntısı">
        <template v-if="source === 'dosya'">
          <div class="flow-file-head">
            <span class="field-label" id="kurulum-dosyasi-etiket">Kurulum dosyası</span>
            <button type="button" class="btn btn-secondary btn-sm" data-eylem="yukle" @click="fileInput?.click()"><Icon name="upload" :size="16" />Dosya yükle</button>
            <input ref="fileInput" class="sr-only" type="file" accept=".yaml,.yml,.json,.txt,text/plain,application/yaml,text/yaml" tabindex="-1" aria-hidden="true"
              data-testid="file-input" @change="onUpload" />
          </div>
          <div class="add-fill add-drop" :class="{ 'add-drop-on': dropping }" data-testid="paste" @dragover.prevent="dropping = true" @dragleave="dropping = false" @drop.prevent="onDrop">
            <FileEditor v-model="pasted" label="Kurulum dosyası" describedby="kurulum-dosyasi-ipucu" :max-rows="40" />
          </div>
          <p id="kurulum-dosyasi-ipucu" class="field-help">
            <template v-if="uploaded">{{ uploaded }} okundu. </template>Bir Compose ya da Kubernetes dosyası yapıştırın, yükleyin ya da buraya bırakın; en çok {{ FILE_LIMIT / 1024 }} KiB.
          </p>
        </template>
        <Field v-else-if="source === 'adres'" v-slot="{ id, describedby }" label="Dosyanın adresi (https)" hint="Obhut dosyayı indirir ve adresi saklar; sonra “Kaynaktan yenile” ile yeni sürümünü alırsınız.">
          <input :id="id" v-model="url" class="input mono" type="url" inputmode="url" autocomplete="off" spellcheck="false" :placeholder="URL_HINT" :aria-describedby="describedby"
            :disabled="fetching" data-testid="src-url" @keydown.enter.prevent="nextFromSource" />
        </Field>
        <template v-else-if="source === 'imaj'">
          <Field v-slot="{ id, describedby }" label="İmaj" hint="İmaj indirilir; kendi bildirdiği portlar ve klasörlerden taslak bir Compose dosyası üretilir.">
            <input :id="id" v-model="image" class="input mono" type="text" autocomplete="off" autocapitalize="off" spellcheck="false" placeholder="registry.example/uygulama:1.0"
              :aria-describedby="describedby" :disabled="fetching" data-testid="src-image" @keydown.enter.prevent="nextFromSource" />
          </Field>
          <JobLog v-if="fetching || draftLog.length" :lines="draftLog" label="Taslak günlüğü" data-testid="draft-progress" />
        </template>
        <template v-else-if="source === 'konteyner'">
          <fieldset v-if="containers.length" class="choice-list" data-testid="src-containers">
            <legend class="field-label">Konteyner</legend>
            <label v-for="c in containers" :key="c.ad" class="choice-item" :data-konteyner="c.ad">
              <input v-model="container" type="radio" name="uygulama-konteyner" :value="c.ad" :disabled="fetching" />
              <span class="choice-text">
                <span class="choice-head"><strong>{{ c.ad }}</strong><span class="muted">{{ c.durum }}</span></span>
                <span class="choice-sub mono">{{ c.imaj }}</span>
              </span>
            </label>
          </fieldset>
          <p v-else class="meter-note" data-testid="src-containers-empty">Elle başlatılmış, Obhut'un yönetmediği bir konteyner yok.</p>
          <p class="meter-note">Taslak bir Compose dosyasına çevrilir. Kurulum bitince eski konteyner kaldırılır; adlı birimlerindeki veri uygulamanın klasörüne kopyalanır, birimlerin kendisine dokunulmaz.</p>
        </template>
        <p v-else class="add-hint">Uygulamanın nereden geldiğini seçin. Kurulumu dosya anlatır; denetçi yalnız dosyanın bilemediğini sorar, Obhut kendi birimlerini üretir.</p>
        <p v-if="sourceError" class="form-error" role="alert" data-testid="source-error">{{ sourceError }}</p>
      </section>
    </div>

    <!-- 2 · Denetçi -->
    <div v-else-if="step === 2" class="add-body add-body-2 add-split" :data-bolme="pane">
      <div class="add-switch filters" role="group" aria-label="Gösterilen">
        <button type="button" class="filter-chip" :aria-pressed="pane === 'sorular'" data-bolme-sec="sorular" @click="pane = 'sorular'">Sorular</button>
        <button type="button" class="filter-chip" :aria-pressed="pane === 'dosya'" data-bolme-sec="dosya" @click="pane = 'dosya'">Dosya</button>
      </div>
      <section class="add-pane add-file" aria-labelledby="dosya-baslik">
        <div class="add-pane-head">
          <h2 id="dosya-baslik" class="add-pane-title">Kurulum dosyası</h2>
          <span class="meter-note"><span data-testid="format">{{ formatText }}</span> · <span class="wrap">{{ origin }}</span></span>
        </div>
        <div class="add-fill">
          <FileEditor ref="editor" v-model="text" :marks="marks" :current="activeLine" label="Kurulum dosyası" describedby="dosya-ipucu" :invalid="refusals.length > 0"
            :max-rows="40" @pick="onPick" />
        </div>
        <p id="dosya-ipucu" class="field-help">Dosyayı burada düzeltebilirsiniz; denetçi her değişiklikte yeniden okur.</p>
      </section>
      <section class="add-pane add-questions" aria-labelledby="sorular-baslik">
        <div class="add-pane-head">
          <h2 id="sorular-baslik" class="add-pane-title">Sorular</h2>
          <span class="meter-note" data-testid="answered">{{ inspection?.format && !refusals.length ? answeredText : "" }}</span>
          <button v-if="inspection?.format && !refusals.length && (waitingN || nameError)" type="button" class="btn btn-secondary btn-sm" data-eylem="bekleyene-git" @click="nextWaiting">
            Bekleyene git
          </button>
        </div>
        <section v-if="refusals.length" class="notice notice-danger" aria-labelledby="durduran-baslik" data-testid="refusals">
          <Icon name="xcircle" class="notice-icon" />
          <div>
            <h3 id="durduran-baslik" class="notice-title">Bu satırlar kurulumu durduruyor</h3>
            <ul class="notice-list">
              <li v-for="(r, i) in refusals" :key="i" :data-satir="r.line">
                <button type="button" class="q-line" @click="showLine(r.line)">Satır {{ r.line }}</button> {{ r.text }}
              </li>
            </ul>
            <p class="meter-note">Dosyayı düzeltin; denetçi yeniden okur.</p>
          </div>
        </section>
        <p v-if="fileError" class="form-error" role="alert">{{ fileError }}</p>
        <p v-if="checkError" class="form-error" role="alert" data-testid="check-error">{{ checkError }}</p>
        <section v-if="notes.length" class="flow-notes" aria-labelledby="notlar-baslik" data-testid="notes">
          <h3 id="notlar-baslik" class="q-title">Notlar</h3>
          <ul class="notice-list">
            <li v-for="(n, i) in notes" :key="i" :data-satir="n.line"><button type="button" class="q-line" @click="showLine(n.line)">Satır {{ n.line }}</button> {{ n.text }}</li>
          </ul>
        </section>
        <template v-if="inspection?.format && !refusals.length">
          <div class="field" :class="{ 'field-invalid': nameError }">
            <label for="uygulama-adi" class="field-label">Uygulama adı</label>
            <input id="uygulama-adi" v-model="state.name" class="input mono" type="text" autocomplete="off" autocapitalize="off" spellcheck="false"
              :aria-invalid="Boolean(nameError) || undefined" aria-describedby="uygulama-adi-ipucu" data-testid="app-name" />
            <p v-if="nameError" class="field-error" data-testid="name-error">{{ nameError }}</p>
            <p id="uygulama-adi-ipucu" class="field-help">Birimlerin, ağın ve veri klasörünün adı olur.</p>
          </div>
          <QuestionList :inspection="inspection" :state="state" :errors="errors" :shown="shown" :root="root" :domain="domain" :taken="taken" grouped
            @line="showLine" @active="onActive" />
        </template>
        <p v-else-if="!inspection" class="meter-note" role="status">Denetleniyor…</p>
      </section>
    </div>

    <!-- 3 · Plan -->
    <div v-else-if="step === 3" class="add-body add-body-3">
      <section class="add-pane" aria-labelledby="plan-baslik">
        <h2 id="plan-baslik" class="add-pane-title">Kurulum ne oluşturur</h2>
        <p v-if="planning" class="meter-note" role="status">Plan hazırlanıyor; kurulumun bütün denetimleri yapılıyor…</p>
        <p v-if="planError" class="form-error" role="alert" data-testid="plan-error">{{ planError }}</p>
        <section v-if="planProblems.length" class="notice notice-danger" aria-labelledby="engel-baslik" data-testid="plan-problems">
          <Icon name="xcircle" class="notice-icon" />
          <div>
            <h3 id="engel-baslik" class="notice-title">Kurulum bu yüzden yapılamaz</h3>
            <ul class="flow-problems">
              <li v-for="p in planProblems" :key="p.id" :data-hata="p.id">
                <span><strong>{{ p.label }}:</strong> {{ p.message }}</span>
                <button v-if="p.question" type="button" class="btn btn-secondary btn-sm" data-eylem="soruya-git" @click="toQuestion(p.id)">Soruya git</button>
              </li>
            </ul>
          </div>
        </section>
        <template v-if="ozet && !planProblems.length">
          <dl class="flow-boxes" data-testid="plan-boxes">
            <div v-for="b in planBoxes" :key="b.key" :data-kutu="b.key">
              <dt>{{ b.title }}</dt>
              <dd v-for="(l, i) in b.lines" :key="i" class="wrap" :class="{ mono: l.mono }">{{ l.text }}</dd>
            </div>
          </dl>
          <div class="field">
            <span class="field-label">Üretilecek birimler</span>
            <ul class="unit-chips" data-testid="plan-units">
              <li v-for="u in ozet.birimler" :key="u" class="mono">{{ u }}</li>
            </ul>
          </div>
        </template>
        <p v-if="installError" class="form-error" role="alert" data-testid="install-error">{{ installError }}</p>
      </section>
      <aside class="add-pane add-side" aria-labelledby="sira-baslik">
        <h2 id="sira-baslik" class="add-pane-title">Kurulum sırası</h2>
        <ol class="add-order">
          <li v-for="o in ORDER" :key="o">{{ o }}</li>
        </ol>
        <p class="meter-note">Bir adım başarısız olursa yapılan her şey geri alınır; ne olduğu Kurulum adımındaki günlükte görünür.</p>
        <section v-if="ozet && ozet.uyarilar.length && !planProblems.length" class="notice notice-warning" aria-labelledby="kur-uyari" data-testid="plan-warnings">
          <Icon name="alert" class="notice-icon" />
          <div>
            <h3 id="kur-uyari" class="notice-title">{{ ozet.uyarilar.length === 1 ? "Bir uyarı" : `${ozet.uyarilar.length} uyarı` }}</h3>
            <ul class="notice-list">
              <li v-for="(w, i) in ozet.uyarilar" :key="i"><strong v-if="w.servis">{{ w.servis }}:</strong> {{ w.metin }}</li>
            </ul>
          </div>
        </section>
        <p class="notice" role="note">
          <Icon name="info" class="notice-icon" />
          <span>Adresler yalnız Tailscale'de açılır; internet adı ve ham portlar Erişim'den açılır.</span>
        </p>
      </aside>
    </div>

    <!-- 4 · Kurulum -->
    <div v-else class="add-body add-body-4">
      <section class="add-pane add-result" aria-labelledby="sonuc-baslik">
        <h2 id="sonuc-baslik" class="add-pane-title">{{ jobName }}</h2>
        <div v-if="jobRunning" class="notice flow-progress" role="status" tabindex="-1" data-testid="install-status" data-durum="calisiyor">
          <Icon name="pulse" class="notice-icon" />
          <div>
            <p class="notice-title">Kuruluyor</p>
            <p class="notice-list">{{ job?.step || "Başlatılıyor" }}</p>
          </div>
        </div>
        <div v-else-if="jobDone" class="notice notice-ok" role="status" tabindex="-1" data-testid="install-status" data-durum="tamam">
          <Icon name="check" class="notice-icon" />
          <div>
            <p class="notice-title">{{ jobName }} kuruldu</p>
            <p class="notice-list">Adresleri yalnız Tailscale'de açık. İnternet adı ve ham portlar kapalı; Erişim'den açılır.</p>
          </div>
        </div>
        <div v-else class="notice notice-danger" role="alert" tabindex="-1" data-testid="install-status" data-durum="hata">
          <Icon name="xcircle" class="notice-icon" />
          <div>
            <p class="notice-title">Kurulum yapılamadı</p>
            <p class="notice-list wrap" data-testid="install-error">{{ job?.error || "Kurulum başarısız oldu." }}</p>
            <p v-if="blamed" class="notice-list" data-testid="install-blame">İlgili soru: <strong>{{ questionTitle(blamed) }}</strong></p>
          </div>
        </div>
        <dl class="facts">
          <dt>Uygulama</dt><dd class="mono">{{ jobName }}</dd>
          <dt>Başladı</dt><dd>{{ typeof job?.created_at === "number" ? clock(job.created_at) : "…" }}</dd>
          <dt>Süre</dt><dd data-testid="install-elapsed">{{ elapsed || "…" }}</dd>
        </dl>
        <p v-if="jobReadError" class="form-error" role="alert">{{ jobReadError }}</p>
      </section>
      <section class="add-pane add-log" aria-labelledby="gunluk-baslik">
        <h2 id="gunluk-baslik" class="add-pane-title">Günlük</h2>
        <JobLog :lines="jobLines" label="Kurulum günlüğü" />
      </section>
    </div>

    <footer class="add-bar">
      <span class="flow-foot-text" role="status" data-testid="flow-status">{{ barText }}</span>
      <template v-if="step === 1">
        <button type="button" class="btn btn-secondary" @click="close">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="!sourceReady" data-eylem="ileri" @click="nextFromSource">{{ fetching ? chosen?.busy : (chosen?.go ?? "Devam") }}</button>
      </template>
      <template v-else-if="step === 2">
        <button type="button" class="btn btn-secondary" @click="back">Geri</button>
        <button type="button" class="btn btn-primary" :disabled="!canPlan" data-eylem="plan" @click="toPlan">Planı gör</button>
      </template>
      <template v-else-if="step === 3">
        <button type="button" class="btn btn-secondary" :disabled="submitting" @click="back">Geri</button>
        <button type="button" class="btn btn-primary" :disabled="!ozet || planProblems.length > 0 || submitting || planning" data-eylem="kur" @click="install">
          {{ submitting ? "Başlatılıyor…" : "Kur" }}
        </button>
      </template>
      <template v-else-if="jobRunning">
        <button type="button" class="btn btn-secondary" data-eylem="kapat" @click="close">Uygulamalar'a dön</button>
      </template>
      <template v-else-if="jobDone">
        <button type="button" class="btn btn-secondary" data-eylem="yeni" @click="reset">Başka uygulama ekle</button>
        <button type="button" class="btn btn-primary" data-eylem="uygulamaya-git" @click="openApp">Uygulamaya git</button>
      </template>
      <template v-else>
        <button type="button" class="btn btn-secondary" data-eylem="kapat" @click="close">Kapat</button>
        <button type="button" class="btn btn-primary" data-eylem="yeniden" @click="retry">{{ retryText }}</button>
      </template>
    </footer>

    <Modal :open="leaveTo !== null" title="Uygulama ekleme bırakılsın mı?" @close="leaveTo = null">
      <p data-testid="close-confirm">Girdikleriniz silinir; uygulama kurulmaz.</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus @click="leaveTo = null">Devam et</button>
        <button type="button" class="btn btn-danger" data-eylem="vazgec" @click="confirmLeave">Bırak</button>
      </template>
    </Modal>
  </div>
</template>
