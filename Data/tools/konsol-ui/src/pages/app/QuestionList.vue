<!-- The inspector's questions (rebuild.md 4.2; K2, K3, A1, A2, A4, A5), one card each with its line in the file,
     why it is asked and the inspector's guess. A TCP port: an address (its Caddy row, with a Tailscale name) or a
     raw port, nothing chosen (A1); a UDP port is a raw port, closed (A2). A variable: its value (the file's default
     filled in). A secret: a hidden value, "Göster", and "Rastgele üret" where the inspector allows it; on an edit a
     stored one reads "Kayıtlı" and is kept unless a new value is entered. A folder: the application's own or one
     under the server root, chosen with the folder picker, read-only or not. A start (A4): directly as its own user or
     as root, the inspector's suggestion marked and a word when the choice differs from it. On an edit a port that
     stays is not asked: its use is shown with a link to its row in Erişim → Adresler, its one home. Errors come
     from the server (by question id) or from the form's own first checks. -->
<script setup lang="ts">
import { computed, ref } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import StatusPill from "../../components/ui/StatusPill.vue";
import ShareFolderPicker from "../dosyalar/paylasim/ShareFolderPicker.vue";
import { accessRoute } from "../../sections";
import { SCOPE_TEXT } from "../../access";
import {
  canGenerate,
  formQuestions,
  guessText,
  isSecret,
  localProblem,
  mountSource,
  questionTitle,
  randomSecret,
  rootText,
  waiting,
  type AnswerState,
  type EditContext,
  type MountDraft,
  type PortDraft,
  type StartDraft,
  type ValueDraft,
} from "./answers";
import type { Inceleme, Soru, UygulamaPortu } from "../../api/sema";

const props = withDefaults(
  defineProps<{
    inspection: Inceleme;
    state: AnswerState;
    errors: Readonly<Record<string, string>>;
    /** Ids of questions whose server error is shown (an unanswered question's "Yanıt gerekli." is not). */
    shown: ReadonlySet<string>;
    edit?: EditContext | null;
    /** The server root (the Files account's area); folders under it are chosen with the picker. */
    root: string;
    domain: string;
    /** Tailscale names other rows hold. */
    taken?: readonly string[];
    /** Questions the source's new text asks for the first time (Kaynaktan yenile). */
    fresh?: readonly string[];
    /** The application's data folder when it is known (an edit). */
    dataFolder?: string;
    disabled?: boolean;
  }>(),
  { edit: null, taken: () => [], fresh: () => [], dataFolder: "", disabled: false },
);
const emit = defineEmits<{ line: [line: number] }>();

const questions = computed(() => formQuestions(props.inspection));

// Each draft by its kind (the template shows a question's controls only when its draft has that kind).
const P = (id: string): PortDraft => {
  const d = props.state.drafts[id];
  return d?.kind === "port" ? d : { kind: "port", use: "", name: "" };
};
const V = (id: string): ValueDraft => {
  const d = props.state.drafts[id];
  return d?.kind === "value" ? d : { kind: "value", value: "", keep: false };
};
const M = (id: string): MountDraft => {
  const d = props.state.drafts[id];
  return d?.kind === "mount" ? d : { kind: "mount", to: "app", path: "", readOnly: false };
};
const S = (id: string): StartDraft => {
  const d = props.state.drafts[id];
  return d?.kind === "start" ? d : { kind: "start", mode: "root" };
};
const reveal = ref<Record<string, boolean>>({});

const staying = (q: Soru): UygulamaPortu | null => (q.kind === "port" ? (props.edit?.staying.get(q.id) ?? null) : null);
const stored = (q: Soru) => Boolean(props.edit?.stored.has(q.id));
const problem = (q: Soru): string => {
  const own = localProblem(q, props.state.drafts[q.id], props.state.drafts, props.taken);
  if (own) return own;
  return props.shown.has(q.id) ? (props.errors[q.id] ?? "") : "";
};
const domId = (i: number) => `soru-${i}`;
const stayText = (p: UygulamaPortu): string => {
  const a = p.erisim;
  if (a.tur === "ham") return `Ham port · ${SCOPE_TEXT[a.kapsam]}${a.kapsam !== "kapali" ? ` · ${a.port}` : ""}`;
  const parts = [`Adres · ${a.ad}${props.domain ? "." + props.domain : ""}`];
  if (a.tailscale_portu !== null) parts.push(`Tailscale portu ${a.tailscale_portu}`);
  if (a.internet) parts.push(`İnternet adı ${a.internet}`);
  return parts.join(" · ");
};

function generate(id: string): void {
  const d = props.state.drafts[id];
  if (d?.kind !== "value") return;
  d.value = randomSecret();
  d.keep = false;
}

function renew(id: string, on: boolean): void {
  const d = props.state.drafts[id];
  if (d?.kind !== "value") return;
  d.keep = !on;
  d.value = "";
  reveal.value[id] = false;
}

function pickPort(id: string, use: "caddy" | "raw", suggest: string | null): void {
  const d = props.state.drafts[id];
  if (d?.kind !== "port") return;
  d.use = use;
  if (use === "caddy" && !d.name) d.name = suggest ?? "";
}
</script>

<template>
  <div class="questions" data-testid="questions">
    <section
      v-for="(q, i) in questions"
      :id="domId(i)"
      :key="q.id"
      class="q-card"
      :class="{ 'q-need': waiting(q, state.drafts[q.id], edit), 'q-invalid': problem(q) }"
      :data-soru="q.id"
      :data-tur="q.kind"
      :aria-labelledby="domId(i) + '-baslik'"
      tabindex="-1"
    >
      <div class="q-head">
        <h3 :id="domId(i) + '-baslik'" class="q-title">{{ questionTitle(q) }}</h3>
        <span class="q-meta">
          <StatusPill v-if="fresh.includes(q.id)" tone="accent">Yeni</StatusPill>
          <button type="button" class="q-line" :aria-label="`Dosyada satır ${q.line}`" @click="emit('line', q.line)">Satır {{ q.line }}</button>
        </span>
      </div>

      <!-- a port that stays: its use is its row's, changed in Erişim → Adresler -->
      <template v-if="q.kind === 'port' && staying(q)">
        <p class="q-stay" data-testid="q-stay">
          <Icon name="lock" :size="14" /><span>{{ stayText(staying(q)!) }}</span>
        </p>
        <p class="q-why">Bu portun kullanımı Erişim'den değişir. <RouterLink :to="accessRoute('adresler', staying(q)!.id)" data-testid="q-stay-link">Erişim'de değiştir</RouterLink></p>
      </template>

      <!-- a port: an address or a raw port (A1: nothing chosen); UDP: a raw port only (A2) -->
      <template v-else-if="q.kind === 'port' && state.drafts[q.id]?.kind === 'port'">
        <p class="q-why">{{ q.why }}</p>
        <p class="q-guess" data-testid="q-guess">Denetçinin tahmini: {{ guessText(q) }}</p>
        <template v-if="q.choices.includes('caddy')">
          <fieldset class="choice-list q-choices">
            <legend class="sr-only">{{ questionTitle(q) }}</legend>
            <label class="choice-item" data-secim="caddy">
              <input type="radio" :name="q.id" value="caddy" :checked="P(q.id).use === 'caddy'" :disabled="disabled" @change="pickPort(q.id, 'caddy', q.suggest)" />
              <span class="choice-text"><span class="choice-head"><strong>Adres</strong></span><span class="choice-sub">Caddy satırı · Tailscale adıyla açılır</span></span>
            </label>
            <label class="choice-item" data-secim="raw">
              <input type="radio" :name="q.id" value="raw" :checked="P(q.id).use === 'raw'" :disabled="disabled" @change="pickPort(q.id, 'raw', null)" />
              <span class="choice-text"><span class="choice-head"><strong>Ham port</strong></span><span class="choice-sub">Kapalı gelir; Erişim'den açılır</span></span>
            </label>
          </fieldset>
          <div v-if="P(q.id).use === 'caddy'" class="field">
            <label :for="domId(i) + '-ad'" class="field-label">Tailscale adı</label>
            <div class="input-suffixed">
              <input
                :id="domId(i) + '-ad'"
                v-model="P(q.id).name"
                class="input mono"
                type="text"
                autocomplete="off"
                autocapitalize="off"
                spellcheck="false"
                :disabled="disabled"
                :aria-invalid="Boolean(problem(q)) || undefined"
                data-testid="q-name"
              />
              <span v-if="domain" class="input-suffix" aria-hidden="true">.{{ domain }}</span>
            </div>
            <p v-if="q.guess !== 'web'" class="field-help warn-text">Web arayüzü değilse adres çalışmaz; ham port daha uygun olabilir.</p>
          </div>
        </template>
        <p v-else class="q-stay"><Icon name="lock" :size="14" /><span>Ham port · kapalı gelir</span></p>
      </template>

      <!-- a secret (a secret-looking variable or an entry the inspector asks for) -->
      <template v-else-if="isSecret(q) && state.drafts[q.id]?.kind === 'value'">
        <p class="q-why">{{ q.why }}</p>
        <div v-if="stored(q) && V(q.id).keep" class="q-kept" data-testid="q-kept">
          <StatusPill tone="ok">Kayıtlı</StatusPill>
          <span class="meter-note">Değer sunucuda; değiştirmezseniz korunur.</span>
          <button type="button" class="btn btn-secondary btn-sm" :disabled="disabled" data-eylem="yenile" @click="renew(q.id, true)">Yeni değer gir</button>
        </div>
        <template v-else>
          <div class="q-secret">
            <label :for="domId(i) + '-deger'" class="sr-only">{{ questionTitle(q) }}</label>
            <input
              :id="domId(i) + '-deger'"
              v-model="V(q.id).value"
              class="input mono"
              :type="reveal[q.id] ? 'text' : 'password'"
              autocomplete="new-password"
              autocapitalize="off"
              spellcheck="false"
              :disabled="disabled"
              :aria-invalid="Boolean(problem(q)) || undefined"
              data-testid="q-secret"
            />
            <button type="button" class="icon-btn" :aria-label="reveal[q.id] ? 'Değeri gizle' : 'Değeri göster'" :aria-pressed="Boolean(reveal[q.id])" :disabled="disabled"
              @click="reveal[q.id] = !reveal[q.id]"><Icon name="eye" :size="18" /></button>
            <button v-if="canGenerate(q)" type="button" class="btn btn-secondary btn-sm" :disabled="disabled" data-eylem="uret" @click="generate(q.id)">Rastgele üret</button>
          </div>
          <p class="field-help">Podman secret olur; diske ve tarayıcıya açık yazılmaz.</p>
          <button v-if="stored(q)" type="button" class="btn btn-secondary btn-sm fit" :disabled="disabled" data-eylem="koru" @click="renew(q.id, false)">Kayıtlı değeri koru</button>
        </template>
      </template>

      <!-- a plain variable -->
      <template v-else-if="q.kind === 'var' && state.drafts[q.id]?.kind === 'value'">
        <p class="q-why">{{ q.why }}</p>
        <label :for="domId(i) + '-deger'" class="sr-only">{{ questionTitle(q) }}</label>
        <input
          :id="domId(i) + '-deger'"
          v-model="V(q.id).value"
          class="input mono"
          type="text"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          :disabled="disabled"
          :aria-invalid="Boolean(problem(q)) || undefined"
          data-testid="q-value"
        />
      </template>

      <!-- a folder (A5): the application's own or one under the server root -->
      <template v-else-if="q.kind === 'mount' && state.drafts[q.id]?.kind === 'mount'">
        <p class="q-why">Dosyada: <span class="mono">{{ mountSource(q) }}</span>. Başka bir sunucu yolu kullanılmaz.</p>
        <fieldset class="choice-list q-choices">
          <legend class="sr-only">{{ questionTitle(q) }}</legend>
          <label class="choice-item" data-secim="app">
            <input v-model="M(q.id).to" type="radio" :name="q.id" value="app" :disabled="disabled" />
            <span class="choice-text">
              <span class="choice-head"><strong>Uygulamanın klasörü</strong></span>
              <span class="choice-sub mono">{{ dataFolder ? `${dataFolder}/${q.folder}` : q.folder }}</span>
            </span>
          </label>
          <label class="choice-item" data-secim="srv">
            <input v-model="M(q.id).to" type="radio" :name="q.id" value="srv" :disabled="disabled || !root" />
            <span class="choice-text"><span class="choice-head"><strong>{{ root || "Sunucu" }} altından bir klasör</strong></span><span class="choice-sub">Dosyalar hesabıyla</span></span>
          </label>
        </fieldset>
        <template v-if="M(q.id).to === 'srv' && root">
          <ShareFolderPicker
            :id="domId(i) + '-klasor'"
            v-model="M(q.id).path"
            :root="root"
            :disabled="disabled"
            :invalid="Boolean(problem(q))"
            :pick-label="`${questionTitle(q)}: klasör seç`"
          />
          <label class="check-row">
            <input v-model="M(q.id).readOnly" type="checkbox" :disabled="disabled" data-testid="q-readonly" />
            <span>Salt okunur</span>
          </label>
        </template>
      </template>

      <!-- a start (A4) -->
      <template v-else-if="q.kind === 'start' && state.drafts[q.id]?.kind === 'start'">
        <p class="q-why">{{ q.why }}</p>
        <fieldset class="choice-list">
          <legend class="sr-only">{{ questionTitle(q) }}</legend>
          <label class="choice-item" data-secim="direct">
            <input v-model="S(q.id).mode" type="radio" :name="q.id" value="direct" :disabled="disabled" />
            <span class="choice-text">
              <span class="choice-head"><strong>Doğrudan · <span class="mono">{{ q.direct_user }}</span></strong><StatusPill v-if="q.suggest === 'direct'" tone="accent">Önerilen</StatusPill></span>
              <span class="choice-sub">Bütün yetkiler kapalı; yeni yetki kazanılamaz</span>
            </span>
          </label>
          <label class="choice-item" data-secim="root">
            <input v-model="S(q.id).mode" type="radio" :name="q.id" value="root" :disabled="disabled" />
            <span class="choice-text">
              <span class="choice-head"><strong>Root olarak</strong><StatusPill v-if="q.suggest === 'root'" tone="accent">Önerilen</StatusPill></span>
              <span class="choice-sub">{{ rootText(q) }}</span>
            </span>
          </label>
        </fieldset>
        <p v-if="S(q.id).mode !== q.suggest" class="field-help warn-text" data-testid="q-start-note">
          {{ S(q.id).mode === "direct" ? "Bu imaj doğrudan başlatılınca açılmayabilir; açılmazsa kurulum geri alınır." : "Dosya kullanıcıyı belirtiyor; root başlangıcı gereksiz yetki bırakır." }}
        </p>
      </template>

      <p v-if="problem(q)" class="field-error" data-testid="q-error">{{ problem(q) }}</p>
    </section>
  </div>
</template>
