<!-- Uygulama ekle (K2; rebuild.md 4.2, 4.5), opened by #/uygulamalar?ekle=1, in three steps:
     Kaynak — a file pasted or uploaded (read here, at most 256 KiB of UTF-8), an https address, an image name (a
     job that pulls it; its progress shows here and in İşlemler) or an existing standalone container
     (Uygulamalar.kaynaklar); each of the last three becomes a draft file first (POST …/uygulamalar/kaynak).
     Denetçi — the file with its line numbers and the inspector's marks beside the lines (it can be corrected here),
     the refusals that stop the flow with their lines, the application's name and every question
     (QuestionList); the file and the answers are checked again with POST …/denetle as they change.
     Plan — POST …/kur with plan: every check an install makes before its first write and what it creates; a
     refusal names its question and leads back to it. Kur — POST …/kur, a job followed in İşlemler; when it ends
     the application's page opens. Secret values live only in this form while it is open: never in the address,
     the browser's storage or a log; closing the sheet forgets them. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, reactive, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { Icon, type IconName } from "../../components/icons";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import FileEditor from "./FileEditor.vue";
import QuestionList from "./QuestionList.vue";
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
  waitingCount,
  type AnswerState,
} from "./answers";
import { watchJob } from "./jobs";
import { fetchDraft, inspectFile, installApp, planInstall, readJob } from "../../api/konsol";
import { live, refreshApps } from "../../live";
import { useLeaveGuard } from "../../leave";
import { address } from "../../links";
import { appRoute } from "../../router";
import { servicesText } from "../../apps";
import type { Inceleme, KaynakTuru, KurIstegi, KurPlani } from "../../api/sema";

const props = defineProps<{ open: boolean }>();
const emit = defineEmits<{ close: [] }>();
const router = useRouter();

const SOURCES: readonly { id: KaynakTuru; icon: IconName; title: string; text: string; go: string; busy: string }[] = [
  { id: "dosya", icon: "file", title: "Dosya", text: "Compose ya da Kubernetes YAML yapıştır ya da yükle", go: "Denetle", busy: "Denetleniyor…" },
  { id: "adres", icon: "globe", title: "Adresten", text: "https ile bir Compose ya da Kubernetes dosyası", go: "İndir ve denetle", busy: "İndiriliyor…" },
  { id: "imaj", icon: "box", title: "İmaj adından", text: "Obhut taslak bir dosya üretir", go: "Taslak üret", busy: "Taslak üretiliyor…" },
  { id: "konteyner", icon: "server", title: "Var olan konteyner", text: "Elle başlatılmış bir konteyner yönetime alınır", go: "Dosyaya çevir", busy: "Çevriliyor…" },
];
const STEPS = ["Kaynak", "Denetçi", "Plan"] as const;
const HTTPS = address("https", "", "");
const URL_HINT = address("https", "depo.example.org", "/compose.yaml");

// ---- the flow's state; everything is forgotten when the sheet closes
const step = ref<1 | 2 | 3>(1);
const source = ref<KaynakTuru | "">("");
const pasted = ref("");
const uploaded = ref("");
const url = ref("");
const image = ref("");
const container = ref("");
const sourceError = ref("");
const fetching = ref(false);
const draftStep = ref("");
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
const installing = ref(false);
const installStep = ref("");
const installError = ref("");
const confirmClose = ref(false);
let stopJob: (() => void) | null = null;

const editor = ref<InstanceType<typeof FileEditor> | null>(null);
const body = ref<HTMLElement | null>(null);

const root = computed(() => live.kaynaklar?.root ?? "");
const domain = computed(() => live.erisim?.alan || live.kaynaklar?.domain || "");
const containers = computed(() => live.uygulamalar?.kaynaklar ?? []);
/** Tailscale names other rows hold (Konsol's and Paylaşımlar' are reserved anyway). */
const taken = computed(() => (live.erisim?.hizmetler ?? []).flatMap((h) => (h.satir?.tur === "adres" ? [h.satir.ad] : [])));
const chosen = computed(() => SOURCES.find((s) => s.id === source.value) ?? null);

function reset(): void {
  clearInterval(draftTimer);
  stopJob?.();
  stopJob = null;
  step.value = 1;
  source.value = "";
  pasted.value = "";
  uploaded.value = "";
  url.value = "";
  image.value = "";
  container.value = "";
  sourceError.value = "";
  fetching.value = false;
  draftStep.value = "";
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
  installing.value = false;
  installStep.value = "";
  installError.value = "";
  confirmClose.value = false;
  checkSeq += 1;
  planSeq += 1;
  clearTimeout(checkTimer);
}

watch(() => props.open, () => reset());
onBeforeUnmount(reset);

const dirty = computed(() => props.open && Boolean(pasted.value.trim() || text.value.trim()) && !installing.value);
useLeaveGuard(dirty);

function close(): void {
  if (dirty.value && !confirmClose.value) {
    confirmClose.value = true;
    void nextTick(() => body.value?.querySelector<HTMLElement>("[data-testid=close-confirm] button")?.focus());
    return;
  }
  reset();
  emit("close");
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

/** A file chosen from this device: read here (never uploaded as it is), at most 256 KiB, UTF-8 only. */
async function readUpload(event: Event): Promise<void> {
  const input = event.target as HTMLInputElement;
  const file = input.files?.[0];
  input.value = "";
  if (!file) return;
  sourceError.value = "";
  if (file.size > FILE_LIMIT) {
    sourceError.value = `${file.name} çok büyük (en çok ${FILE_LIMIT / 1024} KiB).`;
    return;
  }
  try {
    const value = new TextDecoder("utf-8", { fatal: true }).decode(await file.arrayBuffer());
    pasted.value = value;
    uploaded.value = file.name;
  } catch {
    sourceError.value = `${file.name} UTF-8 bir metin dosyası değil.`;
  }
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
    sourceError.value = err instanceof Error ? err.message : String(err);
  }
}

const whereOf = (k: KurIstegi["kaynak"]): string =>
  k.tur === "adres" ? k.adres : k.tur === "imaj" ? `İmaj adından taslak · ${k.imaj}` : k.tur === "konteyner" ? `${k.konteyner} konteynerinden taslak` : "Yapıştırılan dosya";

/** An image's draft is a job (it pulls the image): its step shows here until its result is the draft. */
function followDraft(id: string, ref: string): void {
  draftStep.value = "İmaj indiriliyor";
  const read = async () => {
    try {
      const job = await readJob(id);
      if (!props.open || !fetching.value) return;
      if (job.state === "running") {
        if (typeof job.step === "string" && job.step) draftStep.value = job.step;
        return;
      }
      clearInterval(draftTimer);
      fetching.value = false;
      draftStep.value = "";
      const result = job.result;
      if (job.state === "done" && result && typeof result.metin === "string" && typeof result.kaynak === "object" && result.kaynak) {
        const from = result.kaynak as KurIstegi["kaynak"];
        begin(result.metin, from, whereOf(from.tur === "imaj" ? from : { tur: "imaj", imaj: ref }));
      } else sourceError.value = typeof job.error === "string" && job.error ? job.error : "Taslak üretilemedi.";
    } catch (err) {
      clearInterval(draftTimer);
      fetching.value = false;
      draftStep.value = "";
      sourceError.value = err instanceof Error ? err.message : String(err);
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
    const now = formQuestions(reply.inceleme).map((q) => q.id);
    // New questions (the first read, or a file that changed): check once more with their answers.
    if (first || now.length !== before.size || now.some((id) => !before.has(id))) schedule(0);
  } catch (err) {
    if (mine === checkSeq) checkError.value = err instanceof Error ? err.message : String(err);
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
const waitingN = computed(() => waitingCount(inspection.value, state, null));
const FORMATS: Record<string, string> = { compose: "Compose", kubernetes: "Kubernetes YAML" };
const formatText = computed(() => (inspection.value ? (inspection.value.format ? FORMATS[inspection.value.format] : "Tanınmadı") : "Okunuyor…"));

/** Every error a question shows: the plan's (while its answer is unchanged), then the inspector's. */
const errors = computed<Record<string, string>>(() => {
  const out: Record<string, string> = { ...checkErrors.value };
  for (const [id, e] of Object.entries(planErrors.value)) if (answerKey(id) === e.seen) out[id] = e.text;
  return out;
});
const shown = computed(() => new Set([...sentIds.value, ...Object.keys(planErrors.value)]));
const nameError = computed(() => appNameProblem(state.name.trim()) || (shown.value.has("name") ? (errors.value.name ?? "") : ""));
const localErrors = computed(() => formQuestions(inspection.value).some((q) => localProblem(q, state.drafts[q.id], state.drafts, taken.value)));
const fileError = computed(() => (refusals.value.length ? "" : (checkErrors.value.dosya ?? "")));
const canPlan = computed(
  () => Boolean(inspection.value?.format) && !refusals.value.length && !waitingN.value && !nameError.value && !localErrors.value && !checking.value &&
    !Object.keys(errors.value).some((id) => shown.value.has(id)),
);
const footText = computed(() => {
  if (!inspection.value) return "Denetleniyor…";
  if (refusals.value.length) return `${refusals.value.length} satır kurulumu durduruyor`;
  if (waitingN.value) return `${waitingN.value} soru yanıt bekliyor`;
  if (checking.value) return "Denetleniyor…";
  return "Bütün sorular yanıtlandı";
});

function showLine(line: number): void {
  editor.value?.reveal(line);
}

// ---- Plan
let planSeq = 0;
const PARTS: Record<string, string> = { dosya: "Dosya", name: "Uygulama adı", podman: "Podman", portlar: "Portlar", kaynak: "Kaynak konteyner" };
const planProblems = computed(() =>
  Object.entries(plan.value?.hatalar ?? {}).map(([id, message]) => {
    const q = inspection.value?.questions.find((x) => x.id === id && x.kind !== "name");
    return { id, message, label: q ? questionTitle(q) : (PARTS[id] ?? id), question: Boolean(q) || id === "name" };
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
    for (const [id, message] of Object.entries(value.hatalar ?? {})) if (ids.has(id)) kept[id] = { text: message, seen: answerKey(id) };
    planErrors.value = kept;
  } catch (err) {
    if (mine === planSeq) planError.value = err instanceof Error ? err.message : String(err);
  } finally {
    if (mine === planSeq) planning.value = false;
  }
}

/** Back to the question a refusal names, its error beside it. */
async function toQuestion(id: string): Promise<void> {
  step.value = 2;
  await nextTick();
  const target = id === "name" ? body.value?.querySelector<HTMLElement>("#uygulama-adi") : body.value?.querySelector<HTMLElement>(`[data-soru="${CSS.escape(id)}"]`);
  target?.scrollIntoView({ block: "center" });
  (target?.matches("input") ? target : target?.querySelector<HTMLElement>("input:not([disabled]), .q-card button:not(.q-line):not([disabled])") ?? target)?.focus({ preventScroll: true });
}

function back(): void {
  if (installing.value) return;
  planSeq += 1;
  planning.value = false;
  if (step.value === 3) step.value = 2;
  else if (step.value === 2) {
    checkSeq += 1;
    clearTimeout(checkTimer);
    checking.value = false;
    step.value = 1;
  }
}

const ozet = computed(() => plan.value?.ozet ?? null);
const startLine = (s: NonNullable<typeof ozet.value>["servisler"][number]) => `${s.ad}: ${s.baslangic === "direct" ? `doğrudan ${s.kullanici ?? ""}`.trim() : "root olarak"}`;
type Line = { text: string; mono: boolean };
const plain = (text: string): Line => ({ text, mono: false });
const code = (text: string): Line => ({ text, mono: true });
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

async function install(): Promise<void> {
  if (!ozet.value || planProblems.value.length || installing.value) return;
  installing.value = true;
  installError.value = "";
  installStep.value = "Başlatılıyor";
  try {
    const job = await installApp({ metin: text.value, yanitlar: answers.value, kaynak: kaynak.value });
    void refreshApps();
    stopJob = watchJob(job.is, (j) => {
      stopJob = null;
      void refreshApps();
      if (j?.durum === "hata") {
        installing.value = false;
        installError.value = j.adim ? `Kurulum başarısız: ${j.adim}` : "Kurulum başarısız oldu.";
        return;
      }
      const name = job.ad;
      reset();
      emit("close");
      void router.push(appRoute(name));
    }, (j) => {
      if (j.adim) installStep.value = j.adim;
    });
  } catch (err) {
    installing.value = false;
    installError.value = err instanceof Error ? err.message : String(err);
  }
}
</script>

<template>
  <Modal :open="open" variant="sheet" title="Uygulama ekle" description="Kurulumu dosya anlatır; denetçi sorar, Obhut kendi birimlerini üretir." @close="close">
    <div ref="body" class="app-flow" data-testid="add-flow" :data-adim="step">
      <ol class="flow-steps" aria-label="Adımlar">
        <li v-for="(label, i) in STEPS" :key="label" :class="{ 'flow-step-on': step === i + 1, 'flow-step-done': step > i + 1 }" :aria-current="step === i + 1 ? 'step' : undefined">
          <span class="flow-step-num" aria-hidden="true"><Icon v-if="step > i + 1" name="check" :size="14" /><template v-else>{{ i + 1 }}</template></span>{{ label }}
        </li>
      </ol>

      <div v-if="confirmClose" class="notice notice-warning" role="alert" data-testid="close-confirm">
        <Icon name="alert" class="notice-icon" />
        <div class="flow-confirm">
          <span>Girdikleriniz silinir; uygulama kurulmaz.</span>
          <span class="flow-confirm-acts">
            <button type="button" class="btn btn-secondary btn-sm" @click="confirmClose = false">Devam et</button>
            <button type="button" class="btn btn-danger btn-sm" data-eylem="vazgec" @click="close">Vazgeç</button>
          </span>
        </div>
      </div>

      <!-- 1 · Kaynak -->
      <template v-if="step === 1">
        <fieldset class="src-cards">
          <legend class="sr-only">Kaynak</legend>
          <label v-for="s in SOURCES" :key="s.id" class="src-card" :data-kaynak="s.id">
            <input v-model="source" type="radio" name="uygulama-kaynak" :value="s.id" :disabled="fetching" />
            <span class="sev sev-accent" aria-hidden="true"><Icon :name="s.icon" :size="17" /></span>
            <span class="src-text"><strong>{{ s.title }}</strong><span>{{ s.text }}</span></span>
          </label>
        </fieldset>

        <template v-if="source === 'dosya'">
          <div class="field">
            <div class="flow-file-head">
              <label for="kurulum-dosyasi" class="field-label">Kurulum dosyası</label>
              <button type="button" class="btn btn-secondary btn-sm" data-eylem="yukle" @click="fileInput?.click()"><Icon name="upload" :size="16" />Dosya yükle</button>
              <input ref="fileInput" class="sr-only" type="file" accept=".yaml,.yml,.json,.txt,text/plain,application/yaml,text/yaml" tabindex="-1" aria-hidden="true"
                data-testid="file-input" @change="readUpload" />
            </div>
            <textarea id="kurulum-dosyasi" v-model="pasted" class="input flow-paste mono" rows="12" wrap="off" spellcheck="false" autocapitalize="off" autocomplete="off"
              aria-describedby="kurulum-dosyasi-ipucu" data-testid="paste"></textarea>
            <p id="kurulum-dosyasi-ipucu" class="field-help">
              <template v-if="uploaded">{{ uploaded }} okundu. </template>Bir Compose ya da Kubernetes dosyası; en çok {{ FILE_LIMIT / 1024 }} KiB.
            </p>
          </div>
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
          <p v-if="draftStep" class="notice flow-progress" role="status" data-testid="draft-progress">
            <Icon name="pulse" class="notice-icon" /><span>{{ draftStep }} · ilerlemesi İşlemler'de de görünür.</span>
          </p>
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
        <p v-if="sourceError" class="form-error" role="alert" data-testid="source-error">{{ sourceError }}</p>
      </template>

      <!-- 2 · Denetçi -->
      <template v-else-if="step === 2">
        <dl class="flow-boxes" data-testid="inspect-boxes">
          <div><dt>Biçim</dt><dd data-testid="format">{{ formatText }}</dd></div>
          <div><dt>Kaynak</dt><dd class="wrap">{{ origin }}</dd></div>
          <div><dt>Durduran</dt><dd data-testid="refusal-count">{{ inspection ? (refusals.length ? `${refusals.length} satır` : "Yok") : "…" }}</dd></div>
        </dl>
        <section v-if="refusals.length" class="notice notice-danger" aria-labelledby="durduran-baslik" data-testid="refusals">
          <Icon name="xcircle" class="notice-icon" />
          <div>
            <h3 id="durduran-baslik" class="notice-title">Bu satırlar kurulumu durduruyor</h3>
            <ul class="notice-list">
              <li v-for="(r, i) in refusals" :key="i" :data-satir="r.line">
                <button type="button" class="q-line" @click="showLine(r.line)">Satır {{ r.line }}</button> {{ r.text }}
              </li>
            </ul>
            <p class="meter-note">Dosyayı aşağıda düzeltin; denetçi yeniden okur.</p>
          </div>
        </section>
        <p v-if="fileError" class="form-error" role="alert">{{ fileError }}</p>
        <p v-if="checkError" class="form-error" role="alert" data-testid="check-error">{{ checkError }}</p>
        <div class="field">
          <span class="field-label" id="dosya-etiketi">Kurulum dosyası</span>
          <FileEditor ref="editor" v-model="text" :marks="marks" label="Kurulum dosyası" describedby="dosya-ipucu" :invalid="refusals.length > 0" />
          <p id="dosya-ipucu" class="field-help">Dosyayı burada düzeltebilirsiniz; denetçi her değişiklikte yeniden okur.</p>
        </div>
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
          <QuestionList :inspection="inspection" :state="state" :errors="errors" :shown="shown" :root="root" :domain="domain" :taken="taken" @line="showLine" />
        </template>
      </template>

      <!-- 3 · Plan -->
      <template v-else>
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
          <section v-if="ozet.uyarilar.length" class="notice notice-warning" aria-labelledby="kur-uyari" data-testid="plan-warnings">
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
            <span>İmajlar indirilip özetle sabitlenir; ilk başlatmada sağlık denetlenir, açılmazsa kurulum geri alınır. Adresler yalnız Tailscale'de açılır; internet adı ve ham portlar Erişim'den açılır.</span>
          </p>
        </template>
        <p v-if="installing" class="notice flow-progress" role="status" data-testid="install-progress">
          <Icon name="pulse" class="notice-icon" /><span>Kuruluyor · {{ installStep }} · ilerlemesi İşlemler'de de görünür.</span>
        </p>
        <p v-if="installError" class="form-error" role="alert" data-testid="install-error">{{ installError }}</p>
      </template>
    </div>

    <template #actions>
      <span class="flow-foot-text" role="status" data-testid="flow-status">{{ step === 2 ? footText : "" }}</span>
      <template v-if="step === 1">
        <button type="button" class="btn btn-secondary" @click="close">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="!sourceReady" data-eylem="ileri" @click="nextFromSource">{{ fetching ? chosen?.busy : (chosen?.go ?? "Devam") }}</button>
      </template>
      <template v-else-if="step === 2">
        <button type="button" class="btn btn-secondary" @click="back">Geri</button>
        <button type="button" class="btn btn-primary" :disabled="!canPlan" data-eylem="plan" @click="toPlan">Planı gör</button>
      </template>
      <template v-else>
        <button type="button" class="btn btn-secondary" :disabled="installing" @click="back">Geri</button>
        <button type="button" class="btn btn-primary" :disabled="!ozet || planProblems.length > 0 || installing || planning" data-eylem="kur" @click="install">
          {{ installing ? "Kuruluyor…" : "Kur" }}
        </button>
      </template>
    </template>
  </Modal>
</template>
