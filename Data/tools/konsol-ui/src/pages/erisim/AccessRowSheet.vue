<!-- One access row's sheet (rebuild phase 4; Erişim → Adresler, phase 5): what the row is (its service, where it
     listens on this server, its Caddy row) and the form, then the settings plan and its apply (SettingsPlanSheet's
     form step). Konsol's and Paylaşımlar' rows change through `web` (Konsol's Tailscale name always on; its internet
     name needs the typed word and an existing account, DD-195). An application's address row: its Tailscale name,
     its Tailscale port (off or a number) and its internet name; "Adresi kaldır" turns it into a closed raw port. A
     raw row: closed, Tailscale or internet with its host port (the container port by default); opening it to the
     internet needs the consent (A2: internet_onayi). "Adres aç" (a raw TCP row, another one chosen from the list)
     gives it a Tailscale name and optionally a Tailscale port and an internet name. A control of Adresler' table
     opens the sheet with its change made (`intent`): a closing goes straight to the plan, an opening that needs a
     value (a port, a name, the consent) shows the form with that field first. An opening waits for the 60 s
     confirmation in the pending banner; a closing commits at once (decision 1); the plan says which. -->
<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import Field from "../../components/ui/Field.vue";
import Switch from "../../components/ui/Switch.vue";
import SettingsPlanSheet from "./SettingsPlanSheet.vue";
import { SCOPE_CHOICES, cleanHost, hostProblem, nameProblem, portKey, portProblem, rowOwner } from "../../access";
import { filesRoute } from "../../sections";
import type { Adlar, AyarIstegi, AyarSonucu, ErisimSatiri, Hizmet } from "../../api/sema";

export type RowMode = "duzenle" | "adres-ac";
export type RowOutcome = "kaydedildi" | "kaldirildi" | "acildi";
type Scope = Extract<ErisimSatiri, { tur: "ham" }>["kapsam"];
/** A change made from Adresler' table, applied to the form when the sheet opens. */
export type RowIntent =
  | { kind: "tail"; on: boolean }
  | { kind: "ts-port"; on: boolean }
  | { kind: "internet"; on: boolean }
  | { kind: "kapsam"; kapsam: Scope }
  | { kind: "kaldir" };

const props = defineProps<{
  row: Hizmet | null;
  mode: RowMode;
  intent: RowIntent | null;
  /** Every access row (names and internet names must be unique among them). */
  rows: readonly Hizmet[];
  /** The raw TCP ports "Adres aç" may choose from. */
  candidates: readonly Hizmet[];
  names: Adlar | null;
  revision: string;
  domain: string;
  wan: string;
  tailscaleIp: string;
  locked: boolean;
}>();
const emit = defineEmits<{ close: []; applied: [result: AyarSonucu, outcome: RowOutcome]; mode: [mode: RowMode]; pick: [id: string] }>();

// ---- the form
const fTail = ref(true);
const fInternet = ref(false);
const fHost = ref("");
const fName = ref("");
const fTsOn = ref(false);
const fTsPort = ref("");
const fScope = ref<Scope>("kapali");
const fPort = ref("");
const fConsent = ref(false);
const typed = ref(false);
const tried = ref(false);
const request = ref<AyarIstegi | null>(null);
const removing = ref(false);
/** The field that takes the focus when the form opens. */
const focus = ref<"name" | "ts-port" | "host" | "consent" | "">("name");

const row = computed(() => props.row);
const key = computed(() => (row.value?.anahtar ? portKey(row.value.anahtar) : null));
const access = computed(() => row.value?.satir ?? null);
const web = computed(() => row.value?.web ?? null);
const isPanel = computed(() => row.value?.id === "panel");
const opening = computed(() => props.mode === "adres-ac" && access.value?.tur === "ham");
/** The form's kind: a fixed row (web), an application's address row, its raw row, or "Adres aç". */
const kind = computed<"web" | "adres" | "ham" | "adres-ac" | null>(() => {
  if (!row.value) return null;
  if (row.value.tur === "konsol" || row.value.tur === "paylasim") return web.value ? "web" : null;
  if (!access.value || !key.value) return null;
  if (opening.value) return key.value.protokol === "tcp" ? "adres-ac" : null;
  return access.value.tur;
});

const sanitize = (text: string) => text.toLowerCase().replace(/[^a-z0-9-]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 63).replace(/-+$/, "");

/** The Tailscale name labels other rows and the local names hold (this row's own name is free). */
const takenNames = computed(() => {
  const id = row.value?.id;
  const out = new Set<string>();
  for (const h of props.rows) if (h.id !== id && h.satir?.tur === "adres") out.add(h.satir.ad);
  const suffix = "." + props.domain;
  for (const a of props.names?.adlar ?? []) if (a.satir !== id && a.ad.endsWith(suffix)) out.add(a.ad.slice(0, -suffix.length));
  for (const r of props.names?.kayitlar ?? []) if (r.name.endsWith(suffix)) out.add(r.name.slice(0, -suffix.length));
  return [...out];
});
/** The internet names other rows hold. */
const takenHosts = computed(() => {
  const id = row.value?.id;
  const out: string[] = [];
  for (const h of props.rows) {
    if (h.id === id) continue;
    if (h.web?.enabled && h.web.domain) out.push(h.web.domain);
    if (h.satir?.tur === "adres" && h.satir.internet) out.push(h.satir.internet);
  }
  return out;
});

function suggestName(h: Hizmet): string {
  for (const text of [h.uygulama ?? "", `${h.uygulama ?? ""}-${h.servis ?? ""}`]) {
    const label = sanitize(text);
    if (label && !nameProblem(label, takenNames.value)) return label;
  }
  return "";
}

function reset(): void {
  const h = row.value;
  tried.value = false;
  typed.value = false;
  request.value = null;
  removing.value = false;
  fConsent.value = false;
  focus.value = "name";
  if (!h) return;
  const port = key.value ? String(key.value.port) : "";
  if (web.value) {
    fTail.value = web.value.tail;
    fInternet.value = web.value.enabled;
    fHost.value = web.value.domain;
  }
  const a = access.value;
  if (a?.tur === "adres") {
    fName.value = a.ad;
    fTsOn.value = a.tailscale_portu !== null;
    fTsPort.value = String(a.tailscale_portu ?? port);
    fInternet.value = Boolean(a.internet);
    fHost.value = a.internet;
  } else if (a?.tur === "ham") {
    fScope.value = a.kapsam;
    fPort.value = String(a.port);
    fName.value = suggestName(h);
    fTsOn.value = false;
    fTsPort.value = port;
    fInternet.value = false;
    fHost.value = "";
  }
}

/** A change made from the table: closings and switches that need no value go to the plan at once. */
function applyIntent(intent: RowIntent | null): void {
  if (!intent || !row.value || kind.value === null) return;
  switch (intent.kind) {
    case "tail":
      fTail.value = intent.on;
      review();
      return;
    case "ts-port":
      fTsOn.value = intent.on;
      if (intent.on) focus.value = "ts-port";
      else review();
      return;
    case "internet":
      fInternet.value = intent.on;
      if (intent.on) focus.value = "host";
      else review();
      return;
    case "kapsam":
      fScope.value = intent.kapsam;
      if (consentNeeded.value) focus.value = "consent";
      else review();
      return;
    case "kaldir":
      removeAddress();
  }
}
// A new row, another mode or a change from the table starts from what the server holds (a refresh of the same
// row keeps the form).
watch(
  [() => row.value?.id ?? "", () => props.mode, () => props.intent],
  () => {
    reset();
    applyIntent(props.intent);
  },
  { immediate: true },
);

// ---- checks
const host = computed(() => cleanHost(fHost.value));
const label = computed(() => fName.value.trim().toLowerCase());
const hasAddress = computed(() => kind.value === "adres" || kind.value === "adres-ac");
const errors = computed(() => {
  const out = { name: "", tsPort: "", host: "", port: "", consent: "" };
  const k = kind.value;
  if (hasAddress.value) out.name = nameProblem(label.value, takenNames.value);
  if (hasAddress.value && fTsOn.value) out.tsPort = portProblem(fTsPort.value);
  if ((hasAddress.value || k === "web") && fInternet.value) {
    out.host = hostProblem(fHost.value);
    if (!out.host && takenHosts.value.includes(host.value)) out.host = "Bu internet adı başka bir satırda kullanılıyor.";
  }
  if (k === "ham") out.port = portProblem(fPort.value);
  if (k === "ham" && consentNeeded.value && !fConsent.value) out.consent = "Ham portu internete açmak için onay kutusunu işaretleyin.";
  return out;
});
const valid = computed(() => !Object.values(errors.value).some(Boolean));

/** The row as it would be saved (an application's), or null for a fixed row. */
const nextRow = computed<ErisimSatiri | null>(() => {
  if (hasAddress.value) {
    return { tur: "adres", ad: label.value, tailscale_portu: fTsOn.value ? Number(fTsPort.value.trim()) : null, internet: fInternet.value ? host.value : "" };
  }
  if (kind.value === "ham") return { tur: "ham", kapsam: fScope.value, port: Number(fPort.value.trim()) };
  return null;
});
/** A2: the raw port opens to the internet (newly, or on another port). */
const consentNeeded = computed(() => {
  const a = access.value;
  if (kind.value !== "ham" || fScope.value !== "internet" || a?.tur !== "ham") return false;
  return !(a.kapsam === "internet" && String(a.port) === fPort.value.trim());
});
/** Konsol's internet name opened or renamed: the typed word (DD-195). */
const konsolWord = computed(() => isPanel.value && fInternet.value && Boolean(web.value) && (!web.value?.enabled || host.value !== web.value?.domain));

const nextWeb = computed(() => {
  const w = web.value;
  if (kind.value !== "web" || !w) return null;
  return { tail: isPanel.value ? true : fTail.value, enabled: fInternet.value, domain: fInternet.value ? host.value : w.domain };
});
const changed = computed(() => {
  if (kind.value === "web") {
    const w = web.value, n = nextWeb.value;
    return Boolean(w && n && (w.tail !== n.tail || w.enabled !== n.enabled || (n.enabled && w.domain !== n.domain)));
  }
  return Boolean(nextRow.value && JSON.stringify(nextRow.value) !== JSON.stringify(access.value));
});

function erisimRequest(satir: ErisimSatiri, consent = false): AyarIstegi | null {
  const h = row.value;
  if (!h?.uygulama || !h.anahtar) return null;
  return { revision: props.revision, erisim: { uygulama: h.uygulama, anahtar: h.anahtar, satir, ...(consent ? { internet_onayi: true } : {}) } };
}

function build(): AyarIstegi | null {
  const h = row.value;
  if (!h) return null;
  if (kind.value === "web") {
    const n = nextWeb.value;
    if (!n || (h.id !== "panel" && h.id !== "paylasim")) return null;
    return { revision: props.revision, web: { service: h.id, ...n, ...(konsolWord.value ? { confirm: "onayla" } : {}) } };
  }
  return nextRow.value ? erisimRequest(nextRow.value, consentNeeded.value && fConsent.value) : null;
}

const canReview = computed(() => !props.locked && changed.value && (!konsolWord.value || typed.value) && (!tried.value || valid.value));

function review(): void {
  tried.value = true;
  if (props.locked || !changed.value || !valid.value || (konsolWord.value && !typed.value)) return;
  removing.value = false;
  request.value = build();
}

/** "Adresi kaldır": the address goes, the port becomes a closed raw port on its container port (a closing). */
function removeAddress(): void {
  if (props.locked || !key.value || access.value?.tur !== "adres") return;
  removing.value = true;
  request.value = erisimRequest({ tur: "ham", kapsam: "kapali", port: key.value.port });
}

function back(): void {
  request.value = null;
  removing.value = false;
}

function applied(result: AyarSonucu): void {
  emit("applied", result, removing.value ? "kaldirildi" : kind.value === "adres-ac" ? "acildi" : "kaydedildi");
}

// ---- words
const title = computed(() => {
  const h = row.value;
  if (!h) return "";
  return kind.value === "adres-ac" ? `${h.ad} · Adres aç` : h.ad;
});
const description = computed(() => {
  const h = row.value;
  if (!h) return "";
  if (h.tur === "konsol") return "Konsol · Adres";
  if (h.tur === "paylasim") return "Paylaşımlar · WebDAV adresi";
  return h.aciklama;
});
const proto = computed(() => (key.value?.protokol ?? "tcp").toUpperCase());
const containerPort = computed(() => key.value?.port ?? 0);
const fixedName = computed(() => `${isPanel.value ? "panel" : "paylas"}.${props.domain}`);
/** What the row is: its service, where it listens on this server and its Caddy row. */
const facts = computed(() => {
  const h = row.value;
  if (!h) return [];
  const out: { dt: string; dd: string; mono?: boolean }[] = [];
  if (h.tur === "uygulama" && key.value) {
    out.push({ dt: "Hizmet", dd: `${rowOwner(h)} · ${h.servis ?? ""} · ${key.value.port}/${proto.value}` });
    const local = h.yerel.adresler[0];
    if (access.value?.tur === "adres" && local) out.push({ dt: "Yalnız bu sunucu", dd: `${local} → ${key.value.port}`, mono: true });
    if (access.value?.tur === "adres") out.push({ dt: "Caddy satırı", dd: `${access.value.ad}.${props.domain}`, mono: true });
  } else if (web.value) {
    out.push({ dt: "Hizmet", dd: h.aciklama || h.ad });
    if (isPanel.value) out.push({ dt: "Yalnız bu sunucu", dd: "Konsol soketi" });
    out.push({ dt: "Caddy satırı", dd: fixedName.value, mono: true });
  }
  return out;
});
/** The internet cell's problem (a name whose certificate is not ready, an unencrypted connection). */
const internetProblem = computed(() => {
  const c = row.value?.internet;
  if (!c) return "";
  if (c.durum === "hata") return [c.adresler[0], c.not].filter(Boolean).join(": ");
  return c.uyari;
});
const dnsLine = (name: string) =>
  `Alan adı sağlayıcınızda bir A kaydı gerekir: ${name || "ad"} → ${props.wan || "sunucunun internet IPv4 adresi"}, proxy kapalı (DNS only), AAAA kaydı yok.`;
const scopeHint = computed(() => {
  const port = /^\d+$/.test(fPort.value.trim()) ? fPort.value.trim() : "…";
  switch (fScope.value) {
    case "tailscale":
      return `Tailscale cihazlarınız ${props.tailscaleIp || "sunucunun Tailscale adresi"}:${port} ile ulaşır.`;
    case "internet":
      return `İnternetteki herkes ${props.wan || "sunucunun internet adresi"}:${port} ile ulaşır; arada Caddy ve HTTPS yok.`;
    default:
      return "Hiçbir ağdan ulaşılmaz; port numarası açılınca kullanılır.";
  }
});
const auto = (field: typeof focus.value) => (focus.value === field ? "" : undefined);
const open = computed(() => row.value !== null && kind.value !== null);
const formId = "erisim-satiri";
</script>

<template>
  <SettingsPlanSheet
    :open="open"
    :title="title"
    :description="description"
    :request="request"
    :apply-label="removing ? 'Adresi kaldır' : 'Uygula'"
    :danger="removing"
    :can-review="canReview"
    :form="formId"
    @close="emit('close')"
    @back="back"
    @applied="applied"
  >
    <template #form>
      <form :id="formId" class="form-stack" novalidate data-testid="row-form" @submit.prevent="review">
        <p v-if="locked" class="notice" role="note" data-testid="row-locked">
          <Icon name="clock" class="notice-icon" />
          <span>Bekleyen bir ayar değişikliği var; onaylanana ya da geri alınana kadar yeni değişiklik uygulanamaz.</span>
        </p>
        <dl v-if="facts.length && kind !== 'adres-ac'" class="facts" data-testid="row-facts">
          <template v-for="f in facts" :key="f.dt">
            <dt>{{ f.dt }}</dt>
            <dd :class="{ mono: f.mono }">{{ f.dd }}</dd>
          </template>
        </dl>
        <p v-if="internetProblem && kind !== 'ham'" class="notice notice-warning" role="note" data-testid="row-problem">
          <Icon name="alert" class="notice-icon" /><span>{{ internetProblem }}</span>
        </p>

        <!-- Konsol and Paylaşımlar -->
        <template v-if="kind === 'web'">
          <div class="row-part">
            <Switch v-model="fTail" label="Tailscale adı" :disabled="isPanel" data-testid="row-tail" />
            <p class="meter-note"><span class="mono">{{ fixedName }}</span><template v-if="isPanel"> · Konsol'un Tailscale adı hep açıktır.</template></p>
          </div>
          <div class="row-part">
            <Switch v-model="fInternet" label="İnternet adı" data-testid="row-internet" />
            <template v-if="fInternet">
              <Field v-slot="{ id, describedby, invalid }" label="İnternet adı" hint="Tam alan adı; HTTPS ile paylaşılan 443 portunda açılır." :error="tried ? errors.host : ''">
                <input :id="id" v-model="fHost" class="input" type="text" maxlength="253" autocapitalize="none" autocomplete="off" spellcheck="false"
                  :placeholder="(isPanel ? 'konsol' : 'paylas') + '.example.org'" :aria-describedby="describedby" :aria-invalid="invalid || undefined"
                  :data-autofocus="auto('host')" data-testid="row-host" />
              </Field>
              <p class="meter-note" data-testid="row-dns">{{ dnsLine(host) }}</p>
            </template>
          </div>
          <div v-if="konsolWord" class="notice notice-warning row-word" data-testid="konsol-word">
            <Icon name="alert" class="notice-icon" />
            <div class="form-stack">
              <p><strong>https://{{ host || "…" }}</strong> adresinde Konsol'un giriş sayfası internete açılır. Konsol hesabıyla giren herkes sunucuyu yönetebilir.</p>
              <ul class="notice-list">
                <li>Uzun ve başka yerde kullanmadığınız bir Konsol parolası kullanın; hesap yoksa önce Sistem → Hesap'ta oluşturun.</li>
                <li>İnternetten çok sayıda hatalı giriş olursa internet girişi 15 dakika kapanır; Tailscale girişi etkilenmez.</li>
              </ul>
              <ConfirmWord v-model:confirmed="typed" />
            </div>
          </div>
          <RouterLink v-if="!isPanel" :to="filesRoute('paylasimlar')" class="section-link fit" data-testid="row-shares">Klasör izinleri ve süreler: Dosyalar → Paylaşımlar</RouterLink>
        </template>

        <!-- an application's address row, or "Adres aç" for a raw TCP port -->
        <template v-else-if="kind === 'adres' || kind === 'adres-ac'">
          <Field v-if="kind === 'adres-ac' && candidates.length > 1" v-slot="{ id }" label="Ne açılacak?">
            <select :id="id" class="input" :value="row?.id" data-testid="row-pick" @change="emit('pick', ($event.target as HTMLSelectElement).value)">
              <option v-for="c in candidates" :key="c.id" :value="c.id">{{ c.ad }} · {{ portKey(c.anahtar ?? "")?.port }}/TCP</option>
            </select>
          </Field>
          <Field v-slot="{ id, describedby, invalid }" label="Tailscale adı" :suffix="'.' + domain"
            :hint="kind === 'adres' ? 'Adı değiştirmek eski adı kapatır; yer imlerini güncelleyin.' : ''" :error="tried ? errors.name : ''">
            <input :id="id" v-model="fName" class="input" type="text" maxlength="63" autocapitalize="none" autocomplete="off" spellcheck="false"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" :data-autofocus="auto('name')" data-testid="row-name" />
          </Field>
          <div class="row-part">
            <Switch v-model="fTsOn" label="Tailscale portu" data-testid="row-ts-port-switch" />
            <p class="meter-note">Adı çözemeyen cihazlar için Tailscale adresinde bir port da açılır ({{ tailscaleIp || "Tailscale IP" }}:port); Caddy üzerinden.</p>
            <Field v-if="fTsOn" v-slot="{ id, describedby, invalid }" label="Port" :error="tried ? errors.tsPort : ''">
              <input :id="id" v-model="fTsPort" class="input row-port" type="text" inputmode="numeric" maxlength="5" autocomplete="off"
                :aria-describedby="describedby" :aria-invalid="invalid || undefined" :data-autofocus="auto('ts-port')" data-testid="row-ts-port" />
            </Field>
          </div>
          <div class="row-part">
            <Switch v-model="fInternet" label="İnternet adı" data-testid="row-internet" />
            <template v-if="fInternet">
              <Field v-slot="{ id, describedby, invalid }" label="İnternet adı" hint="Tam alan adı; HTTPS ile paylaşılan 443 portunda açılır. Giriş uygulamanın kendisindedir." :error="tried ? errors.host : ''">
                <input :id="id" v-model="fHost" class="input" type="text" maxlength="253" autocapitalize="none" autocomplete="off" spellcheck="false"
                  :placeholder="(label || 'uygulama') + '.example.org'" :aria-describedby="describedby" :aria-invalid="invalid || undefined"
                  :data-autofocus="auto('host')" data-testid="row-host" />
              </Field>
              <p class="meter-note" data-testid="row-dns">{{ dnsLine(host) }}</p>
            </template>
          </div>
          <ul v-if="kind === 'adres-ac'" class="modal-list">
            <li><Icon name="tailnet" :size="18" /><span>Tailscale cihazlarınız <span class="mono">{{ label || "…" }}.{{ domain }}</span> adıyla açar; Caddy adı konteynere bağlar.</span></li>
            <li><Icon name="lock" :size="18" /><span>Konteyner yalnız bu sunucuda (127.0.0.1) bir porta yayımlanır; ham port kapanır.</span></li>
            <li><Icon name="refresh" :size="18" /><span>Servis yeniden başlar; birkaç saniye yanıt vermez.</span></li>
          </ul>
          <div v-else class="danger-zone">
            <p class="meter-note">Adresi kaldırınca Tailscale adı, Tailscale portu ve internet adı kapanır; port kapalı bir ham port olur ve servis yeniden başlar.</p>
            <button type="button" class="btn btn-danger-quiet btn-sm fit" :disabled="locked" data-testid="row-remove" @click="removeAddress">
              <Icon name="trash" :size="16" />Adresi kaldır
            </button>
          </div>
        </template>

        <!-- an application's raw row -->
        <template v-else-if="kind === 'ham'">
          <Field label="Kim ulaşır" group>
            <div class="choice-list" role="presentation">
              <label v-for="s in SCOPE_CHOICES" :key="s.id" class="choice-item" :data-kapsam="s.id">
                <input v-model="fScope" type="radio" name="ham-kapsam" :value="s.id" />
                <span class="choice-text"><span class="choice-head"><strong>{{ s.text }}</strong></span></span>
              </label>
            </div>
          </Field>
          <p class="meter-note" data-testid="row-scope-hint">{{ scopeHint }}</p>
          <Field v-slot="{ id, describedby, invalid }" label="Ham port" :hint="`Sunucuda açılacak ${proto} portu; varsayılan konteyner portu (${containerPort}).`" :error="tried ? errors.port : ''">
            <input :id="id" v-model="fPort" class="input row-port" type="text" inputmode="numeric" maxlength="5" autocomplete="off"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-testid="row-port" />
          </Field>
          <p v-if="fScope !== 'kapali'" class="meter-note">Ham port güvenlik duvarının kurallarından geçmez; ona kimin ulaşacağını yalnız bu satır belirler.</p>
          <div v-if="consentNeeded" class="notice notice-warning row-word" data-testid="row-consent">
            <Icon name="alert" class="notice-icon" />
            <div class="form-stack">
              <p>Ham port internete doğrudan açılır: arada Caddy, HTTPS ve Konsol girişi olmaz; şifreleme ve giriş uygulamanın kendisindedir.</p>
              <label class="check-row"><input v-model="fConsent" type="checkbox" :data-autofocus="auto('consent')" data-testid="row-consent-box" /><span>Anladım; bu portu internete açın.</span></label>
              <p v-if="tried && errors.consent" class="field-error">{{ errors.consent }}</p>
            </div>
          </div>
          <div v-if="key?.protokol === 'tcp'" class="row-part">
            <p class="meter-note">Bu porta bir Tailscale adı verilebilir: Caddy adı konteynere bağlar, ham port kapanır.</p>
            <button type="button" class="btn btn-secondary btn-sm fit" :disabled="locked" data-testid="row-open-address" @click="emit('mode', 'adres-ac')">
              <Icon name="plus" :size="16" />Adres aç
            </button>
          </div>
          <p v-else class="meter-note">UDP portu yalnız ham port olabilir; adres açılamaz.</p>
        </template>
      </form>
    </template>
  </SettingsPlanSheet>
</template>
