<!-- An application's page (DD-271, phase 3; #/uygulamalar/<ad>): its name, state and actions, its warnings,
     then Özet · Portlar · Depolama · Tanım · Günlük (?sekme=), all read-only. Data from GET
     /api/konsol/uygulamalar/{app}. Başlat, Durdur, Yeniden başlat and Güncelle (only those the backend's
     `eylemler` offers) go to POST …/{app}/islem with the revision; Kaldır to POST …/{app}/kaldir, keeping
     the data by default and deleting it only after the application's name is typed. Each answers with a job
     (202) that is followed through İşlemler: its end reads the page again, a failure says why, an image update
     says whether anything changed, and a finished removal leads back to the list. Durdur and Güncelle ask
     first; Kaldır opens a sheet. -->
<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { RouterLink, useRoute, useRouter } from "vue-router";
import { Icon, type IconName } from "../components/icons";
import AppIcon from "../components/AppIcon.vue";
import ConfirmWord from "../components/ui/ConfirmWord.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import Modal from "../components/ui/Modal.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import Tabs from "../components/ui/Tabs.vue";
import SummaryTab from "./app/SummaryTab.vue";
import PortsTab from "./app/PortsTab.vue";
import StorageTab from "./app/StorageTab.vue";
import DefinitionTab from "./app/DefinitionTab.vue";
import LogTab from "./app/LogTab.vue";
import { live, refreshApps } from "../live";
import { appLine, appState, type AppAction } from "../apps";
import { usePageHead } from "../page";
import { readApp, readJob, removeApp, startAppAction } from "../api/konsol";
import { ApiError } from "../api/http";
import type { KaldirIstegi, Uygulama, UygulamaAyrinti } from "../api/sema";

const TABS = [
  { id: "ozet", label: "Özet" },
  { id: "portlar", label: "Portlar" },
  { id: "depolama", label: "Depolama" },
  { id: "tanim", label: "Tanım" },
  { id: "gunluk", label: "Günlük" },
] as const;

const route = useRoute();
const router = useRouter();
const name = computed(() => (typeof route.params.ad === "string" ? route.params.ad : ""));

// ---- the application: GET …/uygulamalar/{app}, with the live list's item until it answers
const detail = ref<UygulamaAyrinti | null>(null);
const missing = ref("");
const loadError = ref("");
let seq = 0;

async function load(): Promise<void> {
  const mine = ++seq;
  try {
    const value = await readApp(name.value);
    if (mine !== seq) return;
    detail.value = value;
    missing.value = "";
    loadError.value = "";
  } catch (err) {
    if (mine !== seq) return;
    const message = err instanceof Error ? err.message : String(err);
    if (err instanceof ApiError && (err.status === 404 || err.status === 400)) {
      detail.value = null;
      missing.value = message;
    } else loadError.value = message;
  }
}

const listItem = computed(() => live.uygulamalar?.items.find((a) => a.ad === name.value) ?? null);
const app = computed<Uygulama | null>(() => (missing.value ? null : (detail.value?.uygulama ?? listItem.value)));
const state = computed(() => (app.value ? appState(app.value) : null));
const warnings = computed(() => detail.value?.uyarilar ?? []);

// The live list is read again when a job starts or ends and every minute: a change in this application there
// (started elsewhere, too) is a reason to read its detail again.
const signature = (a: Uygulama | null) => (a ? JSON.stringify([a.durum, a.eylemler, a.revizyon, a.guncelleme, a.is, a.servisler.map((s) => s.durum)]) : "");
watch(
  () => signature(listItem.value),
  (now, before) => {
    if (before && now && now !== before && now !== signature(detail.value?.uygulama ?? null)) void load();
  },
);

const description = computed(() => {
  const a = app.value;
  if (!a) return missing.value ? "" : "Okunuyor…";
  const parts = [appLine(a)];
  if (a.guncelleme === "guncel") parts.push("güncel");
  else if (a.guncelleme === "yeni") parts.push("yeni sürüm var");
  else if (a.guncelleme === "denetlenemedi") parts.push("sürüm denetlenemedi");
  return parts.join(" · ");
});

usePageHead(() => ({ title: name.value, parent: { label: "Uygulamalar", to: "/uygulamalar" } }));

// ---- actions
type Eylem = AppAction | "kaldir";
const can = (action: AppAction) => Boolean(app.value?.eylemler.includes(action));
// A job on the application holds every action back (the backend refuses a second one).
const canRemove = computed(() => Boolean(app.value && !app.value.is && app.value.durum !== "islemde"));

const acting = ref<Eylem | null>(null);
const actionError = ref("");
const actionNote = ref("");
const confirmAction = ref<"durdur" | "guncelle" | null>(null);
const removeOpen = ref(false);
const keepData = ref<KaldirIstegi["veri"]>("sakla");
const deleteTyped = ref(false);
const dialogOpen = computed(() => confirmAction.value !== null || removeOpen.value);

const DOING: Record<Eylem, string> = {
  baslat: "Başlatılıyor",
  durdur: "Durduruluyor",
  "yeniden-baslat": "Yeniden başlatılıyor",
  guncelle: "İmajlar denetleniyor",
  kaldir: "Kaldırılıyor",
};

// The job an action started ("uygulama", the job id in the reply); its end reads the application again.
const tracked = ref<{ id: string; eylem: Eylem; seen: boolean } | null>(null);

// An image update says how it went: nothing new, or new images (the job's result).
async function updateResult(id: string, who: string): Promise<void> {
  try {
    const job = await readJob(id);
    const changed = job.result?.changed;
    actionNote.value = changed === false ? `${who}: imajlar zaten güncel.` : changed === true ? `${who}: imajlar güncellendi.` : `${who}: güncelleme bitti.`;
  } catch {
    actionNote.value = `${who}: güncelleme bitti.`;
  }
}

watch(
  () => live.islemler,
  (jobs) => {
    const t = tracked.value;
    if (!t || !jobs) return;
    const job = jobs.find((j) => j.tur === "uygulama" && j.id === t.id);
    if (job?.durum === "calisiyor") {
      t.seen = true;
      return;
    }
    // Not listed yet: wait. Listed no more after it was seen running: it ended a while ago.
    if (!job && !t.seen) return;
    tracked.value = null;
    actionNote.value = "";
    if (job?.durum === "hata") actionError.value = job.adim ? `İşlem başarısız: ${job.adim}` : "İşlem başarısız oldu.";
    void refreshApps();
    if (job?.durum === "tamam" && t.eylem === "guncelle") void updateResult(t.id, name.value);
    // A removed application has no page any more: back to the list (the drawer keeps the finished job).
    if (job?.durum === "tamam" && t.eylem === "kaldir") {
      void router.replace("/uygulamalar");
      return;
    }
    void load();
  },
);

async function send(eylem: Eylem, start: (a: Uygulama) => Promise<{ is: string }>): Promise<boolean> {
  const a = app.value;
  if (!a || acting.value) return false;
  acting.value = eylem;
  actionError.value = "";
  actionNote.value = "";
  try {
    const started = await start(a);
    tracked.value = { id: started.is, eylem, seen: false };
    actionNote.value = `${DOING[eylem]}; ilerlemesi İşlemler'de görünür.`;
    void refreshApps();
    return true;
  } catch (err) {
    actionError.value = err instanceof Error ? err.message : String(err);
    return false;
  } finally {
    acting.value = null;
  }
}

const run = (eylem: AppAction) => send(eylem, (a) => startAppAction(a.ad, { eylem, revizyon: a.revizyon }));

function ask(action: "durdur" | "guncelle"): void {
  actionError.value = "";
  confirmAction.value = action;
}

async function confirm(): Promise<void> {
  const action = confirmAction.value;
  if (!action) return;
  if (await run(action)) confirmAction.value = null;
}

function askRemove(): void {
  actionError.value = "";
  keepData.value = "sakla";
  deleteTyped.value = false;
  removeOpen.value = true;
}

const removeReady = computed(() => keepData.value === "sakla" || deleteTyped.value);

async function confirmRemove(): Promise<void> {
  if (!removeReady.value) return;
  const veri = keepData.value;
  // The typed name is checked here; the request carries the application's own name.
  const ok = await send("kaldir", (a) => removeApp(a.ad, veri === "sil" ? { veri, onay: a.ad, revizyon: a.revizyon } : { veri, revizyon: a.revizyon }));
  if (ok) removeOpen.value = false;
}

function closeDialogs(): void {
  if (acting.value) return;
  confirmAction.value = null;
  removeOpen.value = false;
  actionError.value = "";
}

const confirmText = computed(() => {
  const a = app.value;
  if (!a || !confirmAction.value) return null;
  if (confirmAction.value === "durdur") {
    const items: [IconName, string][] = [["stop", "Servisler durur; sunucu yeniden başlasa da kapalı kalır."]];
    return { title: `${a.ad} durdurulsun mu?`, sub: "Kurulu kalır; istediğinizde başlatırsınız.", go: "Durdur", items };
  }
  const sub = a.guncelleme === "yeni" ? "Yeni sürüm yayınlanmış." : "Kendiliğinden güncelleme yoktur; yalnız siz onaylayınca.";
  const items: [IconName, string][] = [
    ["download", "Her servisin imaj etiketi yeniden çekilir ve özeti karşılaştırılır."],
    ["refresh", "Özet değişen servisler yeni imajla yeniden başlar; kısa bir kesinti olabilir."],
    ["shield", "Bir servis başlamazsa eski imajlara geri dönülür."],
    ["folder", "Veriler uygulamanın klasörlerinde kalır."],
  ];
  return { title: `${a.ad} güncellensin mi?`, sub, go: "Güncelle", items };
});

const REMOVE_ITEMS: readonly [IconName, string][] = [
  ["box", "Servisler durur; konteynerleri, birimleri, ağı ve gizli değerleri kaldırılır."],
  ["download", "İmajlar kalır; Gelişmiş → Podman'dan silinir."],
  ["folder", "Sunucu klasörlerine (/srv) dokunulmaz."],
];

// Another application (the palette, Back): start over with its own data.
watch(
  name,
  () => {
    detail.value = null;
    missing.value = "";
    loadError.value = "";
    tracked.value = null;
    actionError.value = "";
    actionNote.value = "";
    confirmAction.value = null;
    removeOpen.value = false;
    void load();
  },
  { immediate: true },
);
</script>

<template>
  <div class="page-body app-page">
    <header class="app-head" :data-uygulama="name">
      <div class="app-head-main">
        <AppIcon v-if="app" :app="app" size="lg" />
        <div class="app-head-text">
          <div class="app-title">
            <h1 tabindex="-1">{{ name }}</h1>
            <StatusPill v-if="state" :tone="state.tone" :dot="app?.durum === 'calisiyor'" data-testid="app-state">{{ state.text }}</StatusPill>
          </div>
          <p class="page-desc" data-testid="app-desc">{{ description }}</p>
        </div>
      </div>
      <div v-if="app" class="app-actions" data-testid="app-actions">
        <button v-if="can('yeniden-baslat')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="yeniden-baslat" @click="run('yeniden-baslat')">
          <Icon name="refresh" :size="16" />{{ acting === "yeniden-baslat" ? "Başlatılıyor…" : "Yeniden başlat" }}
        </button>
        <button v-if="can('durdur')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="durdur" @click="ask('durdur')">
          <Icon name="stop" :size="16" />Durdur
        </button>
        <button v-if="can('baslat')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="baslat" @click="run('baslat')">
          <Icon name="play" :size="16" />{{ acting === "baslat" ? "Başlatılıyor…" : "Başlat" }}
        </button>
        <button v-if="can('guncelle')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="guncelle" @click="ask('guncelle')">
          <Icon name="update" :size="16" />Güncelle
        </button>
        <button v-if="canRemove" type="button" class="btn btn-danger-quiet" :disabled="acting !== null" data-eylem="kaldir" @click="askRemove">
          <Icon name="trash" :size="16" />Kaldır…
        </button>
      </div>
    </header>

    <section v-if="warnings.length" class="notice notice-warning" aria-labelledby="uyg-uyari-baslik" data-testid="app-warnings">
      <Icon name="alert" class="notice-icon" />
      <div>
        <h2 id="uyg-uyari-baslik" class="notice-title">{{ warnings.length === 1 ? "Bir uyarı" : `${warnings.length} uyarı` }}</h2>
        <ul class="notice-list">
          <li v-for="(w, i) in warnings" :key="i" :data-servis="w.servis"><strong v-if="w.servis">{{ w.servis }}:</strong> {{ w.metin }}</li>
        </ul>
      </div>
    </section>

    <p v-if="actionError && !dialogOpen" class="notice notice-danger" role="alert" data-testid="action-error">{{ actionError }}</p>
    <p class="action-note" role="status" data-testid="action-note">{{ actionNote }}</p>
    <p v-if="loadError" class="notice notice-warning" role="alert" data-testid="load-error">{{ loadError }}</p>

    <section v-if="missing" class="card" aria-label="Uygulama bulunamadı">
      <EmptyState title="Bu uygulama yok" :text="missing" icon="apps">
        <RouterLink to="/uygulamalar" class="btn btn-secondary">Uygulamalar'a dön</RouterLink>
      </EmptyState>
    </section>

    <Tabs v-else-if="app" :tabs="TABS" :label="`${app.ad} bölümleri`" param="sekme">
      <template #default="{ active }">
        <p v-if="!detail" class="meter-note" role="status">Okunuyor…</p>
        <SummaryTab v-else-if="active === 'ozet'" :app="app" :detail="detail" />
        <PortsTab v-else-if="active === 'portlar'" :detail="detail" />
        <StorageTab v-else-if="active === 'depolama'" :detail="detail" />
        <DefinitionTab v-else-if="active === 'tanim'" :detail="detail" />
        <LogTab v-else-if="active === 'gunluk'" :app="app.ad" :services="detail.servisler.map((s) => s.ad)" />
      </template>
    </Tabs>

    <Modal :open="confirmAction !== null" :title="confirmText?.title ?? ''" :description="confirmText?.sub" @close="closeDialogs">
      <ul v-if="confirmText" class="modal-list">
        <li v-for="(item, i) in confirmText.items" :key="i"><Icon :name="item[0]" :size="18" /><span>{{ item[1] }}</span></li>
      </ul>
      <p v-if="actionError" class="form-error" role="alert" data-testid="dialog-error">{{ actionError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" data-autofocus :disabled="acting !== null" @click="closeDialogs">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="acting !== null" data-onay="evet" @click="confirm">
          {{ acting ? "Gönderiliyor…" : confirmText?.go }}
        </button>
      </template>
    </Modal>

    <Modal
      :open="removeOpen"
      variant="sheet"
      :title="app ? `${app.ad} kaldırılsın mı?` : ''"
      description="Uygulama kaldırılır; verileri siz seçmedikçe kalır."
      @close="closeDialogs"
    >
      <ul class="modal-list">
        <li v-for="(item, i) in REMOVE_ITEMS" :key="i"><Icon :name="item[0]" :size="18" /><span>{{ item[1] }}</span></li>
      </ul>
      <fieldset class="choice-list" data-testid="remove-data">
        <legend class="field-label">Veriler</legend>
        <label class="choice-item" data-veri="sakla">
          <input v-model="keepData" type="radio" name="uygulama-veri" value="sakla" data-autofocus />
          <span class="choice-text">
            <span class="choice-head"><strong>Verileri sakla</strong></span>
            <span class="choice-sub">Uygulamanın klasörü <span class="mono">{{ detail?.veri ?? "" }}</span> olduğu gibi kalır.</span>
          </span>
        </label>
        <label class="choice-item" data-veri="sil">
          <input v-model="keepData" type="radio" name="uygulama-veri" value="sil" />
          <span class="choice-text">
            <span class="choice-head"><strong>Verileri sil</strong></span>
            <span class="choice-sub">Uygulamanın klasörü kalıcı olarak silinir; geri alınamaz.</span>
          </span>
        </label>
      </fieldset>
      <ConfirmWord v-if="app && keepData === 'sil'" v-model:confirmed="deleteTyped" :word="app.ad" />
      <p v-if="actionError" class="form-error" role="alert" data-testid="dialog-error">{{ actionError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="acting !== null" @click="closeDialogs">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!removeReady || acting !== null" data-onay="kaldir" @click="confirmRemove">
          {{ acting === "kaldir" ? "Gönderiliyor…" : keepData === "sil" ? "Kaldır ve verileri sil" : "Kaldır" }}
        </button>
      </template>
    </Modal>
  </div>
</template>
