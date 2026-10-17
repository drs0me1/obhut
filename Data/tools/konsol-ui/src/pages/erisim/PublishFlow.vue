<!-- The Yayınla flow (DD-258 goal 2): one sheet, four decisions. Ne (a candidate from GET
     /api/konsol/yayinlar, or another port on this server), Kim (the Tailscale name; the internet name with who
     guards it), Ad (a container's tailnet name, the HTTPS name and the DNS record to create) and Plan
     (POST …/yayinlar/plan, or …/ayarlar/plan for a new manual address: the steps, the settings plan, warnings
     and what blocks it). A container is published from a port it already listens on at 127.0.0.1 (DD-271
     phase 3). "Uygula" sends the settings step's request to …/ayarlar/uygula (the certificate wait takes up to
     a minute). The shell holds it, so any page opens it with ?yayinla=<id>
     ("sec" chooses first, "yeni" is another port); closing removes the parameter. Both names off unpublishes. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue";
import { useRoute, useRouter } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import PlanReview from "../../components/ui/PlanReview.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Switch from "../../components/ui/Switch.vue";
import type { Tone } from "../../components/ui/types";
import { applySettings, planPublication, planSettings, readPublications } from "../../api/erisim";
import { CANDIDATE_KIND, LOCAL_RE, cleanHost, defaultLocal, hostProblem } from "../../access";
import { setPending, settingsChanged } from "../../live";
import { address } from "../../links";
import { updateQuery } from "../../query";
import type { AyarIstegi, AyarPlani, PlanUyarisi, YayinAdayi, YayinAdimi, YayinIstegi, YayinPlani, Yayinlar } from "../../api/sema";

const route = useRoute();
const router = useRouter();
const GUARD_APP = "Yalnız uygulamanın kendi girişi korur; Konsol bu adreste giriş denetlemez.";
const NAME_RE = /^[^\u0000-\u001f]{1,40}$/;

const param = computed(() => {
  const value = route.query.yayinla;
  const text = Array.isArray(value) ? value[0] : value;
  return typeof text === "string" ? text : "";
});
const open = computed(() => param.value !== "");

type Step = 1 | 2 | 3 | 4;
const STEPS: readonly { n: Step; label: string }[] = [
  { n: 1, label: "Ne" },
  { n: 2, label: "Kim" },
  { n: 3, label: "Ad" },
  { n: 4, label: "Plan" },
];
const step = ref<Step>(1);
const list = ref<Yayinlar | null>(null);
const listError = ref("");
const notice = ref("");
const choice = ref("");
const tried = ref(false);

// the decisions
const tail = ref(true);
const internet = ref(false);
const domain = ref("");
const name = ref("");
const local = ref("");
const manualPort = ref("");
const typed = ref(false);

// the plan and its run
const yplan = ref<YayinPlani | null>(null);
const splan = ref<AyarPlani | null>(null);
const planError = ref("");
const planning = ref(false);
type RunState = "bekliyor" | "suruyor" | "tamam" | "hata";
interface RunStep {
  title: string;
  detail: string;
  state: RunState;
  note: string;
}
const run = ref<{ steps: RunStep[]; done: boolean; error: string } | null>(null);
const applying = computed(() => run.value !== null && !run.value.done);
const elapsed = ref(0);
let clock: number | undefined;
let planSeq = 0;

function reset(): void {
  step.value = 1;
  list.value = null;
  listError.value = "";
  notice.value = "";
  choice.value = "";
  tried.value = false;
  typed.value = false;
  yplan.value = null;
  splan.value = null;
  planError.value = "";
  planning.value = false;
  run.value = null;
  planSeq += 1;
  clearInterval(clock);
}

async function loadList(): Promise<void> {
  try {
    list.value = await readPublications();
    listError.value = "";
  } catch (err) {
    listError.value = err instanceof Error ? err.message : String(err);
  }
}

watch(
  param,
  async (value, before) => {
    if (!value) {
      reset();
      return;
    }
    if (before && before === value) return;
    reset();
    await loadList();
    if (param.value !== value) return;
    if (value === "sec") return;
    if (value === "yeni") {
      choice.value = "yeni";
      return;
    }
    const c = list.value?.adaylar.find((x) => x.id === value);
    if (c && c.kullanilabilir) {
      choice.value = c.id;
      step.value = 2;
    } else if (c) notice.value = `${c.ad} şu an yayımlanamaz: ${c.neden || "nedeni bilinmiyor"}`;
    else if (list.value) notice.value = "Bu uygulama yayımlanabilecekler arasında yok; listeden seçin.";
  },
  { immediate: true },
);
onBeforeUnmount(() => clearInterval(clock));

const candidate = computed<YayinAdayi | null>(() => list.value?.adaylar.find((c) => c.id === choice.value) ?? null);
const isNew = computed(() => choice.value === "yeni");
const isPanel = computed(() => candidate.value?.tur === "konsol");
const alan = computed(() => list.value?.alan ?? "");
/** A container without a publication gets its names here; so does another port. */
const needsNames = computed(() => isNew.value || Boolean(candidate.value && !candidate.value.servis));

// A new choice starts from its current state.
watch(choice, () => {
  const c = candidate.value;
  tried.value = false;
  typed.value = false;
  if (isNew.value || !c) {
    tail.value = true;
    internet.value = false;
    domain.value = "";
    name.value = "";
    local.value = "";
    return;
  }
  tail.value = c.servis ? c.tailscale || c.tur === "konsol" : true;
  internet.value = c.internet;
  domain.value = c.alan_adi;
  name.value = c.ad;
  local.value = c.yerel_ad ? (c.yerel_ad.split(".")[0] ?? "") : defaultLocal(c.ad);
});

const host = computed(() => cleanHost(domain.value));
const guard = computed(() => (isNew.value ? GUARD_APP : candidate.value?.giris ?? ""));
const internetBlock = computed(() => {
  if (isNew.value) return list.value?.wan_ipv4 ? "" : "Sunucunun internet IPv4 adresi kullanılamıyor; internet adı açılamaz.";
  return candidate.value?.internet_engel ?? "";
});
/** The internet name cannot be switched on now (switching it off stays possible). */
const internetLocked = computed(() => Boolean(internetBlock.value) && !internet.value);
const tailName = computed(() => (needsNames.value ? `${local.value.trim().toLowerCase() || "…"}.${alan.value}` : candidate.value?.yerel_ad ?? ""));
const konsolWord = computed(() => {
  const c = candidate.value;
  return Boolean(c?.onay_kelimesi && internet.value && (!c.internet || host.value !== c.alan_adi));
});
// This page came over Konsol's own internet name, which the change closes or renames.
const cutsThisPage = computed(() => {
  const c = candidate.value;
  return Boolean(isPanel.value && c?.internet && location.protocol === "https:" && (!internet.value || host.value !== c.alan_adi));
});

const portOf = (text: string) => (/^\d+$/.test(text.trim()) ? Number(text.trim()) : NaN);
const validPort = (text: string) => {
  const n = portOf(text);
  return n >= 1 && n <= 65535;
};

const errors = computed(() => {
  const out = { choice: "", port: "", name: "", local: "", domain: "" };
  if (!choice.value) out.choice = "Yayımlanacak olanı seçin.";
  if (isNew.value && !validPort(manualPort.value)) out.port = "Bu sunucuda dinleyen portu yazın (1–65535).";
  if (needsNames.value) {
    if (!NAME_RE.test(name.value.trim())) out.name = "Ad 1–40 karakter olmalı.";
    const l = local.value.trim().toLowerCase();
    if (!LOCAL_RE.test(l)) out.local = "Küçük harfle başlamalı; yalnız küçük harf, rakam ve tire (en çok 31).";
    else if (list.value?.adaylar.some((c) => c.id !== choice.value && c.yerel_ad === `${l}.${alan.value}`)) out.local = `${l}.${alan.value} adı zaten kullanılıyor.`;
  }
  if (internet.value) {
    out.domain = hostProblem(domain.value);
    if (!out.domain && list.value?.adaylar.some((c) => c.id !== choice.value && c.internet && c.alan_adi === host.value)) {
      out.domain = "Bu internet adı başka bir yayında kullanılıyor.";
    }
  }
  return out;
});
const stepValid = (n: Step) => {
  const e = errors.value;
  if (n === 1) return !e.choice && !e.port && (isNew.value || Boolean(candidate.value?.kullanilabilir));
  if (n === 3) return !e.name && !e.local && !e.domain;
  return true;
};

function go(n: Step): void {
  if (applying.value) return;
  if (n > step.value) {
    tried.value = true;
    for (let s = step.value; s < n; s++) {
      if (!stepValid(s as Step)) {
        step.value = s as Step;
        return;
      }
    }
  }
  tried.value = false;
  step.value = n;
  run.value = null;
  if (n === 4) void makePlan();
}

// ---- the plan
function request(): YayinIstegi | null {
  const c = candidate.value;
  if (!c || !list.value) return null;
  const r: YayinIstegi = { hedef: c.id, revizyon: list.value.revizyon, tailscale: tail.value, internet: internet.value, alan_adi: internet.value ? host.value : c.alan_adi };
  if (!c.servis) {
    if (name.value.trim() !== c.ad) r.ad = name.value.trim();
    const l = local.value.trim().toLowerCase();
    if (l !== defaultLocal(c.ad)) r.yerel = l;
  }
  if (konsolWord.value && typed.value) r.onay = "onayla";
  return r;
}

function manualRequest(): AyarIstegi | null {
  if (!list.value) return null;
  const l = local.value.trim().toLowerCase();
  return {
    revision: list.value.revizyon,
    web: { service: "elle-" + l, tail: tail.value, enabled: internet.value, domain: internet.value ? host.value : "", elle: { name: name.value.trim(), local: l, upstream: "127.0.0.1:" + portOf(manualPort.value) } },
  };
}

async function makePlan(): Promise<void> {
  if (konsolWord.value && !typed.value) return;
  const mine = ++planSeq;
  planning.value = true;
  planError.value = "";
  yplan.value = null;
  splan.value = null;
  try {
    if (isNew.value) {
      const body = manualRequest();
      if (body) {
        const value = await planSettings(body);
        if (mine === planSeq) splan.value = value;
      }
    } else {
      const body = request();
      if (body) {
        const value = await planPublication(body);
        if (mine === planSeq) yplan.value = value;
      }
    }
  } catch (err) {
    if (mine === planSeq) planError.value = err instanceof Error ? err.message : String(err);
  } finally {
    if (mine === planSeq) planning.value = false;
  }
}
watch(typed, (on) => {
  if (on && step.value === 4) void makePlan();
  if (!on) {
    yplan.value = null;
    planSeq += 1;
    planning.value = false;
  }
});

const steps = computed<YayinAdimi[]>(() => {
  if (yplan.value) return yplan.value.adimlar;
  const body = manualRequest();
  if (isNew.value && splan.value && body) {
    const l = local.value.trim().toLowerCase();
    return [{ tur: "ayar", baslik: "Ad ve erişim", aciklama: `${l}.${alan.value} → 127.0.0.1:${portOf(manualPort.value)}; Tailscale adı ${tail.value ? "açık" : "kapalı"}; internet adı ${internet.value ? host.value : "kapalı"}.`, istek: body }];
  }
  return [];
});
const settingsPlan = computed(() => yplan.value?.plan ?? splan.value);
const engel = computed(() => yplan.value?.engel ?? "");
const dnsRecord = computed(() => yplan.value?.dns ?? (isNew.value && internet.value && splan.value ? { ad: host.value, tur: "A", deger: list.value?.wan_ipv4 ?? "" } : null));
const planWarnings = computed<PlanUyarisi[]>(() => yplan.value?.uyarilar ?? (isNew.value && internet.value && splan.value ? [{ seviye: "warn", metin: GUARD_APP }] : []));
const applicable = computed(() =>
  !planning.value && !planError.value && Boolean(settingsPlan.value?.uygulanabilir) && !engel.value && steps.value.length > 0 && (!konsolWord.value || typed.value));

// ---- applying the steps in order (each a settings change)
const RUN_TONE: Record<RunState, Tone> = { bekliyor: "neutral", suruyor: "accent", tamam: "ok", hata: "danger" };
const RUN_TEXT: Record<RunState, string> = { bekliyor: "Bekliyor", suruyor: "Sürüyor…", tamam: "Tamam", hata: "Başarısız" };

async function apply(): Promise<void> {
  if (!applicable.value || applying.value) return;
  const todo = steps.value.map((s) => ({ ...s, istek: JSON.parse(JSON.stringify(s.istek)) as Record<string, unknown> }));
  run.value = { steps: todo.map((s) => ({ title: s.baslik, detail: s.aciklama, state: "bekliyor", note: "" })), done: false, error: "" };
  const current = run.value;
  for (const [i, s] of todo.entries()) {
    const view = current.steps[i] as RunStep;
    view.state = "suruyor";
    try {
      elapsed.value = 0;
      clearInterval(clock);
      clock = window.setInterval(() => (elapsed.value += 1), 1000);
      view.note = internet.value ? "Ad açılıyor; internet adı için sertifika bekleniyor (en çok 1 dakika)…" : "Uygulanıyor…";
      const result = await applySettings(s.istek as AyarIstegi);
      if (result.pending) setPending(result.pending);
      clearInterval(clock);
      view.state = "tamam";
      view.note = "";
    } catch (err) {
      clearInterval(clock);
      const message = err instanceof Error ? err.message : String(err);
      view.state = "hata";
      view.note = message;
      current.error = message;
      current.done = true;
      settingsChanged();
      return;
    }
  }
  current.done = true;
  settingsChanged();
}

const success = computed(() => Boolean(run.value?.done && !run.value.error));
// The run's end (its result or its error) is at the bottom of a long plan: bring it into view.
const outcome = ref<HTMLElement | null>(null);
watch(
  () => run.value?.done,
  (done) => {
    if (done) void nextTick(() => outcome.value?.scrollIntoView({ block: "nearest" }));
  },
);
const resultLinks = computed(() => {
  const out: { href: string; text: string }[] = [];
  if (tail.value && tailName.value && !tailName.value.startsWith("…")) out.push({ href: address("http", tailName.value), text: tailName.value });
  if (internet.value && host.value) out.push({ href: address("https", host.value), text: host.value });
  return out;
});

function close(): void {
  if (applying.value) return;
  updateQuery(router, { yayinla: null });
}

function back(): void {
  if (step.value > 1) go((step.value - 1) as Step);
  else close();
}

const primary = computed<{ label: string; disabled: boolean; run: () => void }>(() => {
  if (success.value) return { label: "Kapat", disabled: false, run: close };
  if (step.value < 4) return { label: "İleri", disabled: !list.value, run: () => go((step.value + 1) as Step) };
  if (run.value?.done) return { label: "Yeniden denetle", disabled: false, run: () => go(4) };
  return { label: applying.value ? "Uygulanıyor…" : "Uygula", disabled: !applicable.value || applying.value, run: () => void apply() };
});

const stateLine = (c: YayinAdayi) =>
  c.servis ? `Tailscale ${c.tailscale ? "açık" : "kapalı"} · İnternet ${c.internet && c.alan_adi ? c.alan_adi : "kapalı"}` : "Henüz yayımlanmadı";
const title = computed(() => (candidate.value ? `${candidate.value.ad} · Yayınla` : isNew.value ? "Başka bir port · Yayınla" : "Yayınla"));
const LEVEL_ICON: Record<PlanUyarisi["seviye"], "info" | "alert" | "xcircle"> = { info: "info", warn: "alert", bad: "xcircle" };
</script>

<template>
  <Modal :open="open" variant="sheet" :title="title" description="Neyin, kimlere, hangi adla açılacağı; önce plan, sonra uygulama." @close="close">
    <ol class="stepper" aria-label="Adımlar">
      <li v-for="s in STEPS" :key="s.n" :aria-current="step === s.n ? 'step' : undefined" :class="{ done: s.n < step }">
        <span class="stepper-n" aria-hidden="true">{{ s.n }}</span>{{ s.label }}
      </li>
    </ol>
    <p v-if="listError" class="form-error" role="alert">{{ listError }}</p>
    <p v-if="notice" class="notice notice-warning" role="note" data-testid="flow-notice"><Icon name="alert" class="notice-icon" /><span>{{ notice }}</span></p>

    <!-- 1 · Ne -->
    <section v-if="step === 1" class="flow-step" aria-label="Ne yayımlanacak" data-adim="ne">
      <p v-if="!list && !listError" class="meter-note">Okunuyor…</p>
      <fieldset v-if="list" class="choice-list">
        <legend class="field-label">Ne yayımlanacak?</legend>
        <label v-for="c in list.adaylar" :key="c.id" class="choice-item" :class="{ 'choice-off': !c.kullanilabilir }" :data-aday="c.id">
          <input v-model="choice" type="radio" name="yayin-ne" :value="c.id" :disabled="!c.kullanilabilir" />
          <span class="choice-text">
            <span class="choice-head"><strong>{{ c.ad }}</strong><span class="muted">{{ CANDIDATE_KIND[c.tur] }}</span></span>
            <span class="choice-sub">{{ stateLine(c) }}</span>
            <span v-if="!c.kullanilabilir && c.neden" class="choice-sub warn-text">{{ c.neden }}</span>
          </span>
        </label>
        <label class="choice-item" data-aday="yeni">
          <input v-model="choice" type="radio" name="yayin-ne" value="yeni" />
          <span class="choice-text">
            <span class="choice-head"><strong>Sunucudaki başka bir port</strong></span>
            <span class="choice-sub">Bu sunucuda 127.0.0.1 üzerinde dinleyen bir uygulamaya ad verin.</span>
          </span>
        </label>
      </fieldset>
      <Field v-if="isNew" v-slot="{ id, describedby, invalid }" label="Port (127.0.0.1)" hint="Uygulamanın bu sunucuda yalnız 127.0.0.1 üzerinde dinlediği port." :error="tried ? errors.port : ''">
        <input :id="id" v-model="manualPort" class="input" type="text" inputmode="numeric" maxlength="5" autocomplete="off" placeholder="8080"
          :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-testid="manual-port" />
      </Field>
      <p v-if="tried && errors.choice" class="form-error" role="alert">{{ errors.choice }}</p>
    </section>

    <!-- 2 · Kim -->
    <section v-else-if="step === 2" class="flow-step" aria-label="Kim erişebilir" data-adim="kim">
      <div class="flow-choice">
        <Switch v-model="tail" label="Tailscale adı" :disabled="isPanel" data-testid="tail-switch" />
        <p class="meter-note"><span class="mono">{{ tailName }}</span> · Tailscale'deki cihazlarınız bu adla açar.</p>
        <p v-if="isPanel" class="meter-note">Konsol'un Tailscale adı hep açıktır.</p>
      </div>
      <div class="flow-choice">
        <Switch v-model="internet" label="İnternet adı (HTTPS)" :disabled="internetLocked" :describedby="internetLocked ? 'yayin-engel' : undefined" data-testid="internet-switch" />
        <p class="meter-note">İnternetteki herkes bu adı açabilir; bağlantı HTTPS ile şifrelenir.</p>
        <p class="guard-line" data-testid="flow-guard"><Icon name="lock" :size="16" /><span>{{ guard }}</span></p>
        <p v-if="internetBlock" id="yayin-engel" class="warn-text" data-testid="internet-block">{{ internetBlock }}</p>
      </div>
      <p v-if="!tail && !internet" class="notice" role="note" data-testid="unpublish"><Icon name="info" class="notice-icon" /><span>İki ad da kapalı: yayın kaldırılır; uygulama çalışmaya devam eder.</span></p>
    </section>

    <!-- 3 · Ad -->
    <section v-else-if="step === 3" class="flow-step" aria-label="Adlar" data-adim="ad">
      <template v-if="needsNames">
        <Field v-slot="{ id, describedby, invalid }" label="Görünen ad" :error="tried ? errors.name : ''">
          <input :id="id" v-model="name" class="input" type="text" maxlength="40" autocomplete="off" placeholder="Notlar"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-testid="flow-name" />
        </Field>
        <Field v-slot="{ id, describedby, invalid }" label="Tailscale adı" :suffix="'.' + alan" hint="Sonradan değişmez; değiştirmek için kaldırıp yeniden ekleyin." :error="tried ? errors.local : ''">
          <input :id="id" v-model="local" class="input" type="text" maxlength="31" autocapitalize="none" autocomplete="off" spellcheck="false"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-testid="flow-local" />
        </Field>
      </template>
      <dl v-else class="facts">
        <dt>Tailscale adı</dt>
        <dd class="mono">{{ tailName }}</dd>
      </dl>
      <template v-if="internet">
        <Field v-slot="{ id, describedby, invalid }" label="İnternet adı" hint="Tam alan adı; URL, IP, port ya da yol yok." :error="tried ? errors.domain : ''">
          <input :id="id" v-model="domain" class="input" type="text" maxlength="253" autocapitalize="none" autocomplete="off" spellcheck="false"
            :placeholder="(tailName.split('.')[0] || 'uygulama') + '.example.org'" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-testid="flow-domain" />
        </Field>
        <div class="dns-record" data-testid="flow-dns">
          <p class="meter-note">Alan adı sağlayıcınızda şu kaydı oluşturun (proxy kapalı, DNS only; AAAA kaydı yok):</p>
          <dl class="facts mono">
            <dt>Ad</dt>
            <dd>{{ host || "…" }}</dd>
            <dt>Tür</dt>
            <dd>A</dd>
            <dt>Değer</dt>
            <dd>{{ list?.wan_ipv4 || "sunucunun internet IPv4 adresi" }}</dd>
          </dl>
        </div>
      </template>
      <p v-else class="meter-note">İnternet adı kapalı.</p>
    </section>

    <!-- 4 · Plan -->
    <section v-else class="flow-step" aria-label="Plan" data-adim="plan">
      <dl class="facts">
        <dt>Ne</dt>
        <dd>{{ isNew ? `${name.trim() || "…"} · 127.0.0.1:${manualPort}` : candidate?.ad }}</dd>
        <dt>Tailscale</dt>
        <dd><span class="mono">{{ tailName }}</span> · {{ tail ? "açık" : "kapalı" }}</dd>
        <dt>İnternet</dt>
        <dd><span v-if="internet" class="mono">{{ host }}</span><span v-else>kapalı</span></dd>
      </dl>
      <p v-if="cutsThisPage" class="notice notice-warning" role="note">
        <Icon name="alert" class="notice-icon" />
        <span>Bu sayfayı Konsol'un internet adresinden açtınız; uygulayınca bu bağlantı kesilir. Konsol Tailscale adresinden açık kalır.</span>
      </p>
      <div v-if="konsolWord" class="notice notice-warning konsol-word" data-testid="konsol-word">
        <Icon name="alert" class="notice-icon" />
        <div class="form-stack">
          <p><strong>https://{{ host }}</strong> adresinde Konsol'un giriş sayfası internete açılır. Konsol hesabıyla giren herkes sunucuyu yönetebilir: güvenlik duvarı, dosyalar, paylaşımlar ve uygulamalar.</p>
          <ul class="notice-list">
            <li>Uzun ve başka yerde kullanmadığınız bir Konsol parolası kullanın.</li>
            <li>İnternetten çok sayıda hatalı giriş olursa internet girişi 15 dakika kapanır; Tailscale girişi etkilenmez.</li>
            <li>Güvenlik duvarı ve alan adı değişiklikleri yalnız Tailscale'den onaylanır.</li>
          </ul>
          <ConfirmWord v-model:confirmed="typed" />
        </div>
      </div>
      <p v-if="konsolWord && !typed" class="meter-note">Plan, onay sözcüğü yazılınca hazırlanır.</p>
      <p v-else-if="planning" class="meter-note" role="status">Plan hazırlanıyor…</p>
      <div v-else-if="planError" class="plan-error">
        <p class="form-error" role="alert" data-testid="flow-plan-error">{{ planError }}</p>
        <button type="button" class="btn btn-secondary btn-sm fit" :disabled="applying" @click="makePlan">Yeniden denetle</button>
      </div>
      <template v-else-if="steps.length">
        <section class="plan-group" aria-label="Adımlar">
          <h3 class="plan-title">Adımlar</h3>
          <ol class="flow-steps" data-testid="flow-steps">
            <li v-for="(s, i) in steps" :key="i" class="flow-run" :data-tur="s.tur">
              <div class="flow-run-head">
                <strong>{{ i + 1 }}. {{ s.baslik }}</strong>
                <StatusPill v-if="run?.steps[i]" :tone="RUN_TONE[run.steps[i]!.state]" data-testid="run-state">{{ RUN_TEXT[run.steps[i]!.state] }}</StatusPill>
              </div>
              <p class="meter-note">{{ s.aciklama }}</p>
              <p v-if="run?.steps[i]?.note" class="cell-note" :class="{ 'warn-text': run.steps[i]!.state === 'hata' }">
                {{ run.steps[i]!.note }}<template v-if="run.steps[i]!.state === 'suruyor'"> {{ elapsed }} sn</template>
              </p>
            </li>
          </ol>
        </section>
        <div v-if="engel" class="notice notice-danger engel" role="alert" data-testid="flow-engel">
          <Icon name="xcircle" class="notice-icon" />
          <div class="form-stack">
            <p>{{ engel }}</p>
            <button type="button" class="btn btn-secondary btn-sm fit" :disabled="applying" data-testid="recheck" @click="makePlan">Yeniden denetle</button>
          </div>
        </div>
        <div v-if="dnsRecord" class="dns-record" data-testid="plan-dns">
          <p class="meter-note">Gereken DNS kaydı (alan adı sağlayıcınızda; proxy kapalı):</p>
          <p class="mono">{{ dnsRecord.ad }} · {{ dnsRecord.tur }} · {{ dnsRecord.deger || "sunucunun internet IPv4 adresi" }}</p>
        </div>
        <ul v-if="planWarnings.length" class="plan-warnings" aria-label="Uyarılar">
          <li v-for="(u, i) in planWarnings" :key="i" class="plan-warning" :data-seviye="u.seviye"><Icon :name="LEVEL_ICON[u.seviye] ?? 'info'" :size="18" /><span>{{ u.metin }}</span></li>
        </ul>
        <PlanReview v-if="settingsPlan" :plan="settingsPlan" />
      </template>
      <div ref="outcome" class="flow-outcome">
      <p v-if="run?.error" class="form-error" role="alert" data-testid="flow-error">{{ run.error }}</p>
      <div v-if="success" class="notice notice-ok" role="status" data-testid="flow-done">
        <Icon name="check" class="notice-icon" />
        <div>
          <p class="notice-title">{{ !tail && !internet ? "Yayın kaldırıldı." : "Yayın kaydedildi." }}</p>
          <ul v-if="resultLinks.length" class="notice-list">
            <li v-for="l in resultLinks" :key="l.href"><a :href="l.href" target="_blank" rel="noopener noreferrer">{{ l.text }}</a></li>
          </ul>
        </div>
      </div>
      </div>
    </section>

    <!-- Two buttons whose words follow the step, so the focused one stays in place from step to step. -->
    <template #actions>
      <button v-if="!success" type="button" class="btn btn-secondary" :disabled="applying" data-testid="flow-back" @click="back">{{ step > 1 ? "Geri" : "Vazgeç" }}</button>
      <button type="button" class="btn btn-primary" :disabled="primary.disabled" data-testid="flow-go" @click="primary.run">{{ primary.label }}</button>
    </template>
  </Modal>
</template>
