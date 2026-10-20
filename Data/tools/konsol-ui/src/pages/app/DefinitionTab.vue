<!-- An application's Tanım (K3; rebuild phase 5, the prototype): its settings' one home. Read: where its file came
     from and when it was read, the answers (a secret only "Kayıtlı"; a port's use is its access row's), its secrets by
     name, the units Obhut generated and the file with the inspector's marks beside its lines. "Tanımı düzenle" opens
     the file in the editor with the answers as questions: a stored secret is kept unless a new value is entered, a
     port that stays is not asked (its home is Erişim → Adresler), a new one is (A1). "Kaynaktan yenile" (an address
     source) fetches the file again: its text fills the editor and the questions it asks for the first time are
     marked. The file is inspected again as it changes (POST …/denetle, its text only). "Değişiklikleri incele" asks
     POST …/{app}/tanim with plan for the difference (units, environment, ports, folders, secrets, start modes,
     warnings; refusals go back to their questions); "Uygula" sends the same body without plan: a job followed in
     İşlemler, after which the tab shows the new definition. Secret values live only in the form while it is open. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, reactive, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import CopyButton from "../../components/ui/CopyButton.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import type { Tone } from "../../components/ui/types";
import FileEditor from "./FileEditor.vue";
import QuestionList from "./QuestionList.vue";
import {
  FILE_LIMIT,
  editAnswers,
  formQuestions,
  lineMarks,
  localProblem,
  portQuestion,
  questionTitle,
  stayingPorts,
  syncDrafts,
  textBytes,
  waitingCount,
  type AnswerState,
  type EditContext,
} from "./answers";
import { watchJob } from "./jobs";
import { FORMAT_TEXT, SOURCE_TEXT, startText } from "../../apps";
import { applyDefinition, inspectFile, planDefinition, refreshSource } from "../../api/konsol";
import { live, serverNow } from "../../live";
import { useLeaveGuard } from "../../leave";
import { SCOPE_TEXT } from "../../access";
import { dateTime, since } from "../../format";
import type { Inceleme, KayitliYanitlar, TanimFarki, TanimPlani, UygulamaAyrinti, Yanit, YanitSakli } from "../../api/sema";

const props = defineProps<{ detail: UygulamaAyrinti }>();
const emit = defineEmits<{ job: [id: string] }>();

const app = computed(() => props.detail.uygulama.ad);
const root = computed(() => live.kaynaklar?.root ?? "");
const domain = computed(() => live.erisim?.alan || live.kaynaklar?.domain || "");
const source = computed(() => props.detail.koken);

// ---- the file as it is, with its marks (the inspector's dry run of the stored text)
const viewInspection = ref<Inceleme | null>(null);
let viewSeq = 0;
async function inspectStored(): Promise<void> {
  const mine = ++viewSeq;
  try {
    const reply = await inspectFile({ metin: props.detail.metin });
    if (mine === viewSeq) viewInspection.value = reply.inceleme;
  } catch {
    if (mine === viewSeq) viewInspection.value = null; // the file still shows, without marks
  }
}
watch(() => props.detail.metin, () => void inspectStored(), { immediate: true });
const viewMarks = computed(() => lineMarks(viewInspection.value));

// ---- the answers in words
const portRows = computed(() =>
  props.detail.servisler.flatMap((s) =>
    s.portlar.map((p) => {
      const a = p.erisim;
      const value = a.tur === "adres" ? `Adres · ${a.ad}${domain.value ? "." + domain.value : ""}` : `Doğrudan port · ${SCOPE_TEXT[a.kapsam]}`;
      return { id: portQuestion(s.ad, p), label: `${p.port}/${p.protokol.toUpperCase()} · ${s.ad}`, value, mono: false, secret: false };
    }),
  ),
);

function labelOf(id: string, a: Yanit | YanitSakli): string {
  const [kind, ...rest] = id.split(":");
  const tail = rest.join(":");
  if (kind === "var") return "set" in a ? `Gizli değer \${${tail}}` : `Değişken \${${tail}}`;
  if (kind === "secret") return rest.length > 1 ? `Gizli değer ${rest.slice(1).join(":")} · ${rest[0]}` : `Gizli değer ${tail}`;
  if (kind === "mount") return `Klasör ${rest.slice(1).join(":")} · ${rest[0]}`;
  if (kind === "start") return `${tail} · nasıl başlasın?`;
  return id;
}

function valueOf(id: string, a: Yanit | YanitSakli): { value: string; mono: boolean; secret: boolean } {
  if ("set" in a) return { value: "Kayıtlı", mono: false, secret: true };
  if ("value" in a) return { value: a.value || "boş", mono: Boolean(a.value), secret: false };
  if ("mode" in a) {
    const service = props.detail.servisler.find((s) => s.ad === id.slice("start:".length));
    return { value: startText(a.mode, service?.kullanici ?? null), mono: false, secret: false };
  }
  if ("to" in a) return a.to === "srv" ? { value: `${a.path} · ${a.read_only ? "salt okunur" : "okuma-yazma"}`, mono: true, secret: false } : { value: "Uygulamanın klasörü", mono: false, secret: false };
  return { value: "use" in a ? (a.use === "raw" ? "Doğrudan port" : "Adres") : "", mono: false, secret: false };
}

const answerRows = computed(() => [
  ...portRows.value,
  ...Object.entries(props.detail.yanitlar.answers)
    .filter(([id]) => !id.startsWith("port:"))
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([id, a]) => ({ id, label: labelOf(id, a), ...valueOf(id, a) })),
]);

// ---- editing
const editing = ref(false);
const text = ref("");
const inspection = ref<Inceleme | null>(null);
const state = reactive<AnswerState>({ name: "", drafts: {} });
const stored = ref<KayitliYanitlar["answers"]>({});
const fresh = ref<string[]>([]);
const fromSource = ref(false);
const checking = ref(false);
const checkError = ref("");
const note = ref("");
const refreshing = ref(false);
const refreshError = ref("");
const editor = ref<InstanceType<typeof FileEditor> | null>(null);
const form = ref<HTMLElement | null>(null);
let checkSeq = 0;
let checkTimer: number | undefined;

const edit = computed<EditContext>(() => ({
  app: app.value,
  staying: stayingPorts(props.detail),
  stored: new Set(Object.entries(stored.value).filter(([, a]) => "set" in a).map(([id]) => id)),
}));
const taken = computed(() =>
  (live.erisim?.hizmetler ?? []).flatMap((h) => (h.satir?.tur === "adres" ? [h.satir.ad] : [])),
);

const dirty = computed(() => editing.value && (text.value !== props.detail.metin || fromSource.value || formQuestions(inspection.value).some((q) => {
  const d = state.drafts[q.id];
  return d?.kind === "value" && (d.value !== "" || (!d.keep && edit.value.stored.has(q.id)));
})));
useLeaveGuard(dirty);

function startEdit(textValue: string, answers: KayitliYanitlar["answers"], newIds: string[], refreshed: boolean): void {
  text.value = textValue;
  stored.value = answers;
  fresh.value = newIds;
  fromSource.value = refreshed;
  inspection.value = null;
  state.name = app.value;
  state.drafts = {};
  planErrors.value = {};
  checkError.value = "";
  note.value = "";
  editing.value = true;
  void check();
  void nextTick(() => form.value?.querySelector<HTMLElement>("textarea")?.focus({ preventScroll: true }));
}

function stopEdit(): void {
  editing.value = false;
  text.value = "";
  inspection.value = null;
  state.drafts = {};
  stored.value = {};
  fresh.value = [];
  fromSource.value = false;
  planErrors.value = {};
  checkSeq += 1;
  clearTimeout(checkTimer);
  checking.value = false;
}

async function refresh(): Promise<void> {
  refreshing.value = true;
  refreshError.value = "";
  note.value = "";
  try {
    const value = await refreshSource(app.value);
    if (value.metin === props.detail.metin && !value.yeni_sorular.length) {
      note.value = "Kaynakta değişiklik yok; dosya son okumadan beri aynı.";
      return;
    }
    startEdit(value.metin, value.yanitlar.answers, value.yeni_sorular, true);
  } catch (err) {
    refreshError.value = err instanceof Error ? err.message : String(err);
  } finally {
    refreshing.value = false;
  }
}

function schedule(delay: number): void {
  clearTimeout(checkTimer);
  checkTimer = window.setTimeout(() => void check(), delay);
}

/** The file inspected again (its text only): the marks, the refusals and the questions; the answers are checked by
    the plan. */
async function check(): Promise<void> {
  clearTimeout(checkTimer);
  if (!editing.value) return;
  if (textBytes(text.value) > FILE_LIMIT) {
    checkError.value = `Dosya çok büyük (en çok ${FILE_LIMIT / 1024} KiB).`;
    return;
  }
  const mine = ++checkSeq;
  checking.value = true;
  try {
    const reply = await inspectFile({ metin: text.value });
    if (mine !== checkSeq) return;
    inspection.value = reply.inceleme;
    syncDrafts(state, reply.inceleme, stored.value, root.value);
    checkError.value = "";
  } catch (err) {
    if (mine === checkSeq) checkError.value = err instanceof Error ? err.message : String(err);
  } finally {
    if (mine === checkSeq) checking.value = false;
  }
}
watch(text, () => {
  if (editing.value && inspection.value) schedule(500);
});

const refusals = computed(() => inspection.value?.refusals ?? []);
const notes = computed(() => inspection.value?.notes ?? []);
const marks = computed(() => lineMarks(inspection.value));
const waitingN = computed(() => waitingCount(inspection.value, state, edit.value));
const answers = computed(() => editAnswers(inspection.value, state, root.value, edit.value));
const answerKey = (id: string): string => JSON.stringify(answers.value.answers[id] ?? null);

// ---- the plan
const planErrors = ref<Record<string, { text: string; seen: string }>>({});
const errors = computed<Record<string, string>>(() => {
  const out: Record<string, string> = {};
  for (const [id, e] of Object.entries(planErrors.value)) if (answerKey(id) === e.seen) out[id] = e.text;
  return out;
});
const shown = computed(() => new Set(Object.keys(planErrors.value)));
const localErrors = computed(() => formQuestions(inspection.value).some((q) => localProblem(q, state.drafts[q.id], state.drafts, taken.value)));
const canReview = computed(() => Boolean(inspection.value?.format) && !refusals.value.length && !waitingN.value && !localErrors.value && !checking.value && !planning.value);
const footText = computed(() => {
  if (!inspection.value) return "Denetleniyor…";
  if (refusals.value.length) return `${refusals.value.length} satır değişikliği durduruyor`;
  if (waitingN.value) return `${waitingN.value} soru yanıt bekliyor`;
  return checking.value ? "Denetleniyor…" : "Bütün sorular yanıtlandı";
});

const plan = ref<TanimPlani | null>(null);
const planOpen = ref(false);
const planning = ref(false);
const planError = ref("");
const applying = ref(false);
const applyError = ref("");
let stopJob: (() => void) | null = null;

const PARTS: Record<string, string> = { dosya: "Dosya", name: "Uygulama adı", podman: "Podman", portlar: "Portlar" };
const planProblems = computed(() =>
  Object.entries(plan.value?.hatalar ?? {}).map(([id, message]) => {
    const q = inspection.value?.questions.find((x) => x.id === id && x.kind !== "name");
    return { id, message, label: q ? questionTitle(q) : (PARTS[id] ?? id), question: Boolean(q) };
  }),
);

const request = () => ({ metin: text.value, yanitlar: answers.value, revizyon: props.detail.uygulama.revizyon });

async function review(): Promise<void> {
  if (!canReview.value) return;
  planning.value = true;
  planError.value = "";
  applyError.value = "";
  plan.value = null;
  try {
    const value = await planDefinition(app.value, request());
    plan.value = value;
    // A question's refusal shows beside it (until its answer changes); a part's only in the list.
    const ids = new Set(formQuestions(value.inceleme).map((q) => q.id));
    const kept: Record<string, { text: string; seen: string }> = {};
    for (const [id, message] of Object.entries(value.hatalar ?? {})) if (ids.has(id)) kept[id] = { text: message, seen: answerKey(id) };
    planErrors.value = kept;
    if (value.fark) planOpen.value = true;
    else if (value.inceleme.refusals.length) inspection.value = value.inceleme;
  } catch (err) {
    planError.value = err instanceof Error ? err.message : String(err);
  } finally {
    planning.value = false;
  }
}

async function toQuestion(id: string): Promise<void> {
  await nextTick();
  const target = form.value?.querySelector<HTMLElement>(`[data-soru="${CSS.escape(id)}"]`);
  target?.scrollIntoView({ block: "center" });
  (target?.querySelector<HTMLElement>("input:not([disabled]), .q-card button:not(.q-line):not([disabled])") ?? target)?.focus({ preventScroll: true });
}

async function apply(): Promise<void> {
  if (!plan.value?.fark || applying.value) return;
  applying.value = true;
  applyError.value = "";
  try {
    const job = await applyDefinition(app.value, request());
    planOpen.value = false;
    // The page says that it runs and how it ended (AppPage follows the same job).
    emit("job", job.is);
    stopJob = watchJob(job.is, (j) => {
      stopJob = null;
      applying.value = false;
      if (j?.durum === "hata") applyError.value = j.adim ? `Tanım uygulanamadı: ${j.adim}` : "Tanım uygulanamadı.";
      else stopEdit();
    });
  } catch (err) {
    applying.value = false;
    applyError.value = err instanceof Error ? err.message : String(err);
  }
}

// ---- the difference in words
const CHANGE: Record<string, { text: string; tone: Tone }> = {
  eklenir: { text: "Eklenir", tone: "ok" },
  kaldirilir: { text: "Kaldırılır", tone: "danger" },
  degisir: { text: "Değişir", tone: "accent" },
  kalir: { text: "Kalır", tone: "neutral" },
};
const keyText = (key: string): string => {
  const m = /^(.+):(\d+)\/(tcp|udp)$/.exec(key);
  return m ? `${m[2]}/${(m[3] as string).toUpperCase()} · ${m[1]}` : key;
};
const START: Record<"direct" | "root", string> = { direct: "doğrudan", root: "root olarak" };
const fark = computed<TanimFarki | null>(() => plan.value?.fark ?? null);
const portChanges = computed(() => (fark.value?.portlar ?? []).filter((p) => p.degisim !== "kalir"));
const portsKept = computed(() => (fark.value?.portlar ?? []).filter((p) => p.degisim === "kalir").length);
const secretRows = computed(() => {
  const g = fark.value?.gizliler;
  if (!g) return [];
  return [
    ...g.yeni.map((ad) => ({ ad, text: "Eklenir", tone: "ok" as Tone })),
    ...g.yenilenen.map((ad) => ({ ad, text: "Yenilenir", tone: "accent" as Tone })),
    ...g.korunan.map((ad) => ({ ad, text: "Korunur", tone: "neutral" as Tone })),
    ...g.kaldirilan.map((ad) => ({ ad, text: "Kaldırılır", tone: "danger" as Tone })),
  ];
});
const nothing = computed(() => {
  const f = fark.value;
  if (!f) return false;
  return !f.birimler.length && !f.ortam.length && !portChanges.value.length && !f.klasorler.eklenen.length && !f.klasorler.birakilan.length &&
    !f.gizliler.yeni.length && !f.gizliler.yenilenen.length && !f.gizliler.kaldirilan.length && !f.baslangic.length;
});

function closePlan(): void {
  if (applying.value) return;
  planOpen.value = false;
}

onBeforeUnmount(() => {
  stopJob?.();
  clearTimeout(checkTimer);
  viewSeq += 1;
  checkSeq += 1;
});
</script>

<template>
  <div class="definition-tab">
    <p class="sr-only" role="status">{{ note }}</p>
    <p v-if="note" class="action-note" aria-hidden="true" data-testid="definition-note">{{ note }}</p>
    <p v-if="refreshError" class="notice notice-danger" role="alert" data-testid="refresh-error">{{ refreshError }}</p>

    <!-- read -->
    <div v-if="!editing" class="tab-grid tab-grid-wide definition-view">
      <section class="card" aria-labelledby="kaynak-baslik" data-testid="source">
        <div class="card-head">
          <h2 id="kaynak-baslik" class="card-title">Kaynak</h2>
          <div class="card-actions">
            <button v-if="source.tur === 'adres'" type="button" class="btn btn-secondary btn-sm" :disabled="refreshing" data-eylem="kaynaktan-yenile" @click="refresh">
              <Icon name="refresh" :size="16" />{{ refreshing ? "İndiriliyor…" : "Kaynaktan yenile" }}
            </button>
            <button type="button" class="btn btn-primary btn-sm" data-eylem="duzenle" @click="startEdit(detail.metin, detail.yanitlar.answers, [], false)">
              <Icon name="pencil" :size="16" />Tanımı düzenle
            </button>
          </div>
        </div>
        <dl class="facts">
          <dt>Biçim</dt>
          <dd>{{ FORMAT_TEXT[detail.uygulama.bicim] ?? detail.uygulama.bicim }}</dd>
          <dt>Kaynak</dt>
          <dd data-testid="source-kind">{{ SOURCE_TEXT[source.tur] ?? source.tur }}</dd>
          <template v-if="source.adres || source.imaj">
            <dt>{{ source.adres ? "Adres" : "İmaj" }}</dt>
            <dd class="mono wrap" data-testid="source-where">{{ source.adres ?? source.imaj }}</dd>
          </template>
          <dt>Son okuma</dt>
          <dd data-testid="source-read">{{ dateTime(source.alindi) }} · {{ since(source.alindi, serverNow()) }}</dd>
          <dt>SHA-256</dt>
          <dd class="mono wrap" data-testid="source-sha">{{ source.sha256 }}</dd>
        </dl>
        <h3 class="sub-title">Yanıtlar</h3>
        <dl v-if="answerRows.length" class="facts answer-facts" data-testid="answers">
          <template v-for="a in answerRows" :key="a.id">
            <dt>{{ a.label }}</dt>
            <dd :class="{ mono: a.mono, wrap: true }" :data-yanit="a.id">
              <StatusPill v-if="a.secret" tone="ok">{{ a.value }}</StatusPill><template v-else>{{ a.value }}</template>
            </dd>
          </template>
        </dl>
        <p v-else class="meter-note">Yanıt yok.</p>
        <p v-if="portRows.length" class="meter-note">Portların kullanımı Erişim → Adresler'de değişir.</p>
        <h3 class="sub-title">Gizli değerler</h3>
        <ul v-if="detail.gizliler.length" class="mount-list" data-testid="secrets">
          <li v-for="g in detail.gizliler" :key="g.ad" class="mount" :data-gizli="g.ad">
            <span class="mono">{{ g.ad }}</span>
            <span class="mount-meta">{{ g.servisler.join(", ") }}</span>
          </li>
        </ul>
        <p v-else class="meter-note" data-testid="secrets">Gizli değer yok.</p>
        <p class="meter-note secret-note"><Icon name="lock" :size="14" />Değerler sunucuda Podman secret olarak durur; tarayıcıya gönderilmez.</p>
        <h3 class="sub-title">Üretilen birimler</h3>
        <ul class="unit-chips" data-testid="units">
          <li v-for="u in detail.birimler" :key="u" class="mono">{{ u }}</li>
        </ul>
      </section>

      <section class="card" aria-labelledby="dosya-baslik" data-testid="file">
        <div class="card-head">
          <h2 id="dosya-baslik" class="card-title">Kurulum dosyası</h2>
          <div class="card-actions">
            <StatusPill tone="neutral">{{ FORMAT_TEXT[detail.uygulama.bicim] ?? detail.uygulama.bicim }}</StatusPill>
            <CopyButton :text="detail.metin" label="Dosya" />
          </div>
        </div>
        <FileEditor :model-value="detail.metin" :marks="viewMarks" readonly label="Kurulum dosyası" :max-rows="30" />
      </section>
    </div>

    <!-- edit -->
    <div v-else ref="form" class="definition-edit" data-testid="definition-edit">
      <p class="notice" role="note">
        <Icon name="info" class="notice-icon" />
        <span>Değişiklik denetçiden geçer; fark plan olarak gösterilir, onaylayınca uygulama yeniden başlar. Portların kullanımı Erişim → Adresler'de değişir.</span>
      </p>
      <p v-if="fromSource" class="notice notice-ok" role="note" data-testid="refreshed">
        <Icon name="refresh" class="notice-icon" />
        <span>Kaynaktan yeni metin alındı: <span class="mono wrap">{{ source.adres }}</span>.
          {{ fresh.length ? `${fresh.length} yeni soru var; işaretli.` : "Yeni soru yok." }}</span>
      </p>
      <section v-if="refusals.length" class="notice notice-danger" aria-labelledby="tanim-durduran" data-testid="refusals">
        <Icon name="xcircle" class="notice-icon" />
        <div>
          <h3 id="tanim-durduran" class="notice-title">Bu satırlar değişikliği durduruyor</h3>
          <ul class="notice-list">
            <li v-for="(r, i) in refusals" :key="i" :data-satir="r.line"><button type="button" class="q-line" @click="editor?.reveal(r.line)">Satır {{ r.line }}</button> {{ r.text }}</li>
          </ul>
        </div>
      </section>
      <p v-if="checkError" class="form-error" role="alert" data-testid="check-error">{{ checkError }}</p>
      <section class="card" aria-labelledby="tanim-dosya" data-testid="edit-file">
        <h2 id="tanim-dosya" class="card-title">Kurulum dosyası</h2>
        <FileEditor ref="editor" v-model="text" :marks="marks" label="Kurulum dosyası" :invalid="refusals.length > 0" />
        <ul v-if="notes.length" class="notice-list" data-testid="notes">
          <li v-for="(n, i) in notes" :key="i" :data-satir="n.line"><button type="button" class="q-line" @click="editor?.reveal(n.line)">Satır {{ n.line }}</button> {{ n.text }}</li>
        </ul>
      </section>
      <section v-if="inspection?.format && !refusals.length" class="card" aria-labelledby="tanim-yanit" data-testid="edit-answers">
        <h2 id="tanim-yanit" class="card-title">Yanıtlar</h2>
        <QuestionList
          :inspection="inspection"
          :state="state"
          :errors="errors"
          :shown="shown"
          :edit="edit"
          :root="root"
          :domain="domain"
          :taken="taken"
          :fresh="fresh"
          :data-folder="detail.veri"
          :disabled="applying"
          @line="(n) => editor?.reveal(n)"
        />
      </section>
      <section v-if="planProblems.length" class="notice notice-danger" aria-labelledby="tanim-engel" data-testid="plan-problems">
        <Icon name="xcircle" class="notice-icon" />
        <div>
          <h3 id="tanim-engel" class="notice-title">Değişiklik bu yüzden uygulanamaz</h3>
          <ul class="flow-problems">
            <li v-for="p in planProblems" :key="p.id" :data-hata="p.id">
              <span><strong>{{ p.label }}:</strong> {{ p.message }}</span>
              <button v-if="p.question" type="button" class="btn btn-secondary btn-sm" data-eylem="soruya-git" @click="toQuestion(p.id)">Soruya git</button>
            </li>
          </ul>
        </div>
      </section>
      <p v-if="planError" class="form-error" role="alert" data-testid="plan-error">{{ planError }}</p>
      <p v-if="applyError" class="form-error" role="alert" data-testid="apply-error">{{ applyError }}</p>
      <div class="edit-bar">
        <span class="flow-foot-text" role="status" data-testid="edit-status">{{ footText }}</span>
        <button type="button" class="btn btn-secondary" :disabled="applying" data-eylem="vazgec" @click="stopEdit">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="!canReview || applying" data-eylem="incele" @click="review">
          {{ planning ? "İnceleniyor…" : applying ? "Uygulanıyor…" : "Değişiklikleri incele" }}
        </button>
      </div>
    </div>

    <Modal :open="planOpen" variant="sheet" :title="`${app} · Tanım değişikliği`" description="Plan: uygulanınca olacaklar. Onaylamadan sunucuda hiçbir şey değişmez." @close="closePlan">
      <div v-if="fark" class="diff" data-testid="diff">
        <p v-if="nothing" class="notice" role="note" data-testid="diff-none"><Icon name="check" class="notice-icon" /><span>Tanımda değişiklik yok.</span></p>
        <section v-if="fark.birimler.length" class="plan-group" aria-label="Birimler" data-fark="birimler">
          <h3 class="plan-title">Birimler</h3>
          <ul class="plan-items">
            <li v-for="u in fark.birimler" :key="u.ad" class="plan-item"><div class="plan-item-head"><StatusPill :tone="CHANGE[u.degisim]?.tone ?? 'neutral'">{{ CHANGE[u.degisim]?.text ?? u.degisim }}</StatusPill><strong class="plan-object mono">{{ u.ad }}</strong></div></li>
          </ul>
        </section>
        <section v-if="fark.ortam.length" class="plan-group" aria-label="Ortam" data-fark="ortam">
          <h3 class="plan-title">Ortam değişkenleri</h3>
          <ul class="plan-items">
            <li v-for="s in fark.ortam" :key="s" class="plan-item"><div class="plan-item-head"><StatusPill tone="accent">Değişir</StatusPill><strong class="plan-object">{{ s }}</strong></div></li>
          </ul>
        </section>
        <section v-if="fark.portlar.length" class="plan-group" aria-label="Portlar" data-fark="portlar">
          <h3 class="plan-title">Portlar</h3>
          <ul v-if="portChanges.length" class="plan-items">
            <li v-for="p in portChanges" :key="p.anahtar" class="plan-item">
              <div class="plan-item-head"><StatusPill :tone="CHANGE[p.degisim]?.tone ?? 'neutral'">{{ CHANGE[p.degisim]?.text ?? p.degisim }}</StatusPill><strong class="plan-object">{{ keyText(p.anahtar) }}</strong></div>
              <p v-if="p.yerel_port" class="plan-change mono">Yalnız bu sunucu · 127.0.0.1:{{ p.yerel_port }}</p>
            </li>
          </ul>
          <p v-if="portsKept" class="meter-note">{{ portsKept }} port aynı kalır; kullanımları Erişim'dedir.</p>
        </section>
        <section v-if="fark.klasorler.eklenen.length || fark.klasorler.birakilan.length" class="plan-group" aria-label="Klasörler" data-fark="klasorler">
          <h3 class="plan-title">Klasörler</h3>
          <ul class="plan-items">
            <li v-for="k in fark.klasorler.eklenen" :key="'e' + k" class="plan-item"><div class="plan-item-head"><StatusPill tone="ok">Eklenir</StatusPill><strong class="plan-object mono wrap">{{ k }}</strong></div></li>
            <li v-for="k in fark.klasorler.birakilan" :key="'b' + k" class="plan-item">
              <div class="plan-item-head"><StatusPill tone="neutral">Bırakılır</StatusPill><strong class="plan-object mono wrap">{{ k }}</strong></div>
              <p class="plan-change">Diskte kalır.</p>
            </li>
          </ul>
        </section>
        <section v-if="secretRows.length" class="plan-group" aria-label="Gizli değerler" data-fark="gizliler">
          <h3 class="plan-title">Gizli değerler</h3>
          <ul class="plan-items">
            <li v-for="g in secretRows" :key="g.text + g.ad" class="plan-item"><div class="plan-item-head"><StatusPill :tone="g.tone">{{ g.text }}</StatusPill><strong class="plan-object mono">{{ g.ad }}</strong></div></li>
          </ul>
        </section>
        <section v-if="fark.baslangic.length" class="plan-group" aria-label="Başlatma" data-fark="baslangic">
          <h3 class="plan-title">Başlatma</h3>
          <ul class="plan-items">
            <li v-for="b in fark.baslangic" :key="b.servis" class="plan-item">
              <div class="plan-item-head"><StatusPill tone="accent">Değişir</StatusPill><strong class="plan-object">{{ b.servis }}</strong></div>
              <p class="plan-change">
                <template v-if="b.once"><span class="plan-before">{{ START[b.once] }}</span><span class="plan-arrow" aria-hidden="true">→</span></template><span>{{ START[b.sonra] }}</span>
              </p>
            </li>
          </ul>
        </section>
        <ul v-if="fark.uyarilar.length" class="plan-warnings" aria-label="Uyarılar" data-testid="diff-warnings">
          <li v-for="(w, i) in fark.uyarilar" :key="i" class="plan-warning" data-seviye="warn"><Icon name="alert" :size="18" /><span><strong v-if="w.servis">{{ w.servis }}:</strong> {{ w.metin }}</span></li>
        </ul>
        <p class="plan-window" data-testid="diff-restart">
          <Icon :name="fark.yeniden_baslar ? 'refresh' : 'check'" :size="18" />
          <span>{{ fark.yeniden_baslar ? "Uygulama yeniden başlar; açılmazsa önceki tanıma dönülür." : "Yeniden başlatma gerekmez." }}</span>
        </p>
      </div>
      <p v-if="applyError" class="form-error" role="alert">{{ applyError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="applying" @click="closePlan">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="applying || nothing" data-eylem="uygula" @click="apply">{{ applying ? "Gönderiliyor…" : "Uygula" }}</button>
      </template>
    </Modal>
  </div>
</template>
