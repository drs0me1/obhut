<!-- An application's page (rebuild phase 5, the prototype; #/uygulamalar/<ad>): its name, state and the line of
     where its file came from; "Aç" (its first address, while it runs) and its actions; its definition's warnings,
     prominent; then Özet · Erişim · Depolama · Tanım · Günlük (?sekme=). Data from GET /api/konsol/uygulamalar/{app};
     the live rate from the list, read again every 10 s while the page is shown. Başlat, Durdur, Yeniden başlat and
     Güncelle (only those the backend's `eylemler` offers) go to POST …/{app}/islem with the revision; Kaldır to
     POST …/{app}/kaldir, deleting the data with it after the application's name is typed unless "Verileri sakla"
     is ticked (DD-281: its unused images and, with the data, its job records go too);
     Tanım's apply is POST …/{app}/tanim. Each answers with a job (202) followed through İşlemler: its end reads the
     page again, a failure says why, an image update says whether anything changed, a finished removal leads back
     to the list. Durdur and Güncelle ask first; Kaldır is a dialog. Tanım is kept while another tab is shown, so a
     change being written there survives a look at Erişim. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { RouterLink, useRoute, useRouter } from "vue-router";
import { Icon, type IconName } from "../components/icons";
import AppIcon from "../components/AppIcon.vue";
import ConfirmWord from "../components/ui/ConfirmWord.vue";
import EmptyState from "../components/ui/EmptyState.vue";
import Modal from "../components/ui/Modal.vue";
import StatusPill from "../components/ui/StatusPill.vue";
import Tabs from "../components/ui/Tabs.vue";
import SummaryTab from "./app/SummaryTab.vue";
import AccessTab from "./app/AccessTab.vue";
import StorageTab from "./app/StorageTab.vue";
import DefinitionTab from "./app/DefinitionTab.vue";
import LogTab from "./app/LogTab.vue";
import { watchJob } from "./app/jobs";
import { live, refreshApps } from "../live";
import { appLine, appState, openAddress, type AppAction } from "../apps";
import { usePageHead } from "../page";
import { useQueryParam } from "../query";
import { readApp, readJob, removeApp, startAppAction } from "../api/konsol";
import { ApiError } from "../api/http";
import type { Uygulama, UygulamaAyrinti } from "../api/sema";

const TABS = [
  { id: "ozet", label: "Özet" },
  { id: "erisim", label: "Erişim" },
  { id: "depolama", label: "Depolama" },
  { id: "tanim", label: "Tanım" },
  { id: "gunluk", label: "Günlük" },
] as const;

const route = useRoute();
const router = useRouter();
const name = computed(() => (typeof route.params.ad === "string" ? route.params.ad : ""));
const tab = useQueryParam<string>("sekme", TABS.map((t) => t.id), "ozet");

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
/** Every /srv warning settled by what the processes run as now: the card is a note, not a warning. */
const settled = computed(() => warnings.value.length > 0 && warnings.value.every((w) => w.cozuldu));
/** The live rate comes with the list, which is read more often than the detail. */
const rate = computed(() => listItem.value?.ag ?? detail.value?.uygulama.ag ?? null);
const opening = computed(() => (app.value ? openAddress(listItem.value ?? app.value) : ""));

// The live list is read again when a job starts or ends and every 10 s here: a change in this application there
// (started elsewhere, too) is a reason to read its detail again.
const signature = (a: Uygulama | null) => (a ? JSON.stringify([a.durum, a.eylemler, a.revizyon, a.guncelleme, a.is, a.uyari, a.servisler.map((s) => s.durum)]) : "");
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
  if (a.guncelleme === "yeni") parts.push("yeni imaj var");
  else if (a.guncelleme === "denetlenemedi") parts.push("güncelleme denetlenemedi");
  return parts.join(" · ");
});

usePageHead(() => ({ title: name.value, parent: { label: "Uygulamalar", to: "/uygulamalar" } }));

// ---- actions
type Eylem = AppAction | "kaldir" | "tanim";
const can = (action: AppAction) => Boolean(app.value?.eylemler.includes(action));
// A job on the application holds every action back (the backend refuses a second one).
const canRemove = computed(() => Boolean(app.value && !app.value.is && app.value.durum !== "islemde"));

const acting = ref<Eylem | null>(null);
const actionError = ref("");
const actionNote = ref("");
const confirmAction = ref<"durdur" | "guncelle" | null>(null);
const removeOpen = ref(false);
const keepData = ref(false);
const deleteTyped = ref(false);
const dialogOpen = computed(() => confirmAction.value !== null || removeOpen.value);

const DOING: Record<Eylem, string> = {
  baslat: "Başlatılıyor",
  durdur: "Durduruluyor",
  "yeniden-baslat": "Yeniden başlatılıyor",
  guncelle: "İmajlar denetleniyor",
  kaldir: "Kaldırılıyor",
  tanim: "Tanım uygulanıyor",
};

let stopJob: (() => void) | null = null;

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

/** Follows an application job until it ends: the page is read again, a failure says why. */
function track(id: string, eylem: Eylem): void {
  stopJob?.();
  actionNote.value = `${DOING[eylem]}; ilerlemesi İşlemler'de görünür.`;
  void refreshApps();
  stopJob = watchJob(id, (job) => {
    stopJob = null;
    actionNote.value = "";
    void refreshApps();
    if (job?.durum === "hata") actionError.value = job.adim ? `İşlem başarısız: ${job.adim}` : "İşlem başarısız oldu.";
    if (job?.durum === "tamam" && eylem === "guncelle") void updateResult(id, name.value);
    if (job?.durum === "tamam" && eylem === "tanim") actionNote.value = `${name.value}: tanım uygulandı.`;
    // A removed application has no page any more: back to the list (the drawer keeps the finished job).
    if (job?.durum === "tamam" && eylem === "kaldir") {
      void router.replace("/uygulamalar");
      return;
    }
    void load();
  });
}

async function send(eylem: Eylem, start: (a: Uygulama) => Promise<{ is: string }>): Promise<boolean> {
  const a = app.value;
  if (!a || acting.value) return false;
  acting.value = eylem;
  actionError.value = "";
  actionNote.value = "";
  try {
    const started = await start(a);
    track(started.is, eylem);
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
  keepData.value = false;
  deleteTyped.value = false;
  removeOpen.value = true;
}

const removeReady = computed(() => keepData.value || deleteTyped.value);

async function confirmRemove(): Promise<void> {
  if (!removeReady.value) return;
  const keep = keepData.value;
  // The typed name is checked here; the request carries the application's own name.
  const ok = await send("kaldir", (a) => removeApp(a.ad, keep ? { veri: "sakla", revizyon: a.revizyon } : { veri: "sil", onay: a.ad, revizyon: a.revizyon }));
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
  const sub = a.guncelleme === "yeni" ? "Yeni imaj yayımlanmış." : "Kendiliğinden güncelleme yoktur; yalnız siz onaylayınca.";
  const items: [IconName, string][] = [
    ["download", "Her servisin imaj etiketi yeniden çekilir ve özeti karşılaştırılır."],
    ["refresh", "Özet değişen servisler yeni imajla yeniden başlar; kısa bir kesinti olabilir."],
    ["shield", "Bir servis başlamazsa eski imajlara geri dönülür."],
    ["folder", "Veriler uygulamanın klasörlerinde kalır."],
  ];
  return { title: `${a.ad} güncellensin mi?`, sub, go: "Güncelle", items };
});

// Tanım is mounted when first shown and kept while another tab is shown.
const definitionShown = ref(false);
watch(tab, (t) => {
  if (t === "tanim") definitionShown.value = true;
}, { immediate: true });

function definitionJob(id: string): void {
  actionError.value = "";
  track(id, "tanim");
}

// Another application (the palette, Back): start over with its own data.
watch(
  name,
  () => {
    detail.value = null;
    missing.value = "";
    loadError.value = "";
    stopJob?.();
    stopJob = null;
    actionError.value = "";
    actionNote.value = "";
    confirmAction.value = null;
    removeOpen.value = false;
    definitionShown.value = tab.value === "tanim";
    void load();
  },
  { immediate: true },
);

let timer: number | undefined;
onMounted(() => {
  timer = window.setInterval(() => {
    if (!document.hidden) void refreshApps();
  }, 10000);
});
onBeforeUnmount(() => {
  clearInterval(timer);
  stopJob?.();
});
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
    </header>
    <div v-if="app" class="app-actions" data-testid="app-actions">
      <a v-if="opening" :href="opening" class="btn btn-primary" target="_blank" rel="noopener noreferrer" :aria-label="`${app.ad} uygulamasını aç`" data-eylem="ac">
        Aç<Icon name="open" :size="15" />
      </a>
      <button v-if="can('yeniden-baslat')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="yeniden-baslat" @click="run('yeniden-baslat')">
        <Icon name="refresh" :size="16" />{{ acting === "yeniden-baslat" ? "Başlatılıyor…" : "Yeniden başlat" }}
      </button>
      <button v-if="can('durdur')" type="button" class="btn btn-secondary" :disabled="acting !== null" data-eylem="durdur" @click="ask('durdur')">
        <Icon name="stop" :size="16" />Durdur
      </button>
      <button v-if="can('baslat')" type="button" class="btn" :class="can('durdur') ? 'btn-secondary' : 'btn-primary'" :disabled="acting !== null" data-eylem="baslat" @click="run('baslat')">
        <Icon name="play" :size="16" />{{ acting === "baslat" ? "Başlatılıyor…" : "Başlat" }}
      </button>
      <button v-if="canRemove" type="button" class="btn btn-danger-quiet" :disabled="acting !== null" data-eylem="kaldir" @click="askRemove">
        <Icon name="trash" :size="16" />Kaldır…
      </button>
    </div>

    <section v-if="warnings.length" class="notice" :class="settled ? 'notice-ok' : 'notice-warning'" aria-labelledby="uyg-uyari-baslik"
      data-testid="app-warnings" :data-durum="settled ? 'cozuldu' : 'uyari'">
      <Icon :name="settled ? 'check' : 'alert'" class="notice-icon" />
      <div>
        <h2 id="uyg-uyari-baslik" class="notice-title">
          {{ settled ? (warnings.length === 1 ? "Bir uyarı, şu an sorun değil" : `${warnings.length} uyarı, şu an sorun değil`) : warnings.length === 1 ? "Bir uyarı" : `${warnings.length} uyarı` }}
        </h2>
        <ul class="notice-list">
          <li v-for="(w, i) in warnings" :key="i" :data-servis="w.servis">
            <strong v-if="w.servis">{{ w.servis }}:</strong> {{ w.metin }}
            <span v-if="w.simdi" class="warning-now" :class="w.cozuldu ? 'ok-text' : 'warn-text'" data-testid="warning-now">{{ w.simdi }}</span>
          </li>
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
        <template v-else>
          <SummaryTab v-if="active === 'ozet'" :app="app" :detail="detail" :rate="rate" :can-update="can('guncelle') && acting === null" @update="ask('guncelle')" />
          <AccessTab v-else-if="active === 'erisim'" :detail="detail" />
          <StorageTab v-else-if="active === 'depolama'" :detail="detail" />
          <LogTab v-else-if="active === 'gunluk'" :app="app.ad" :services="detail.servisler.map((s) => s.ad)" />
          <div v-if="definitionShown" class="tab-keep" :hidden="active !== 'tanim'">
            <DefinitionTab :detail="detail" @job="definitionJob" />
          </div>
        </template>
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

    <Modal :open="removeOpen" :title="app ? `${app.ad} kaldırılsın mı?` : ''" @close="closeDialogs">
      <p data-testid="remove-text">
        {{ app?.ad }} durdurulur; birimleri, ağı, gizli değerleri, adresleri, yerel adları, doğrudan portları, verileri ve iş kayıtları kaldırılır.
        İmajlarını başka bir uygulama ya da konteyner kullanmıyorsa onlar da silinir.
      </p>
      <label class="check-row remove-keep" data-testid="remove-keep">
        <input v-model="keepData" type="checkbox" />
        <span>Verileri sakla <span class="mono muted wrap">{{ detail?.veri ?? "" }}</span></span>
      </label>
      <p class="notice" role="note"><Icon name="info" class="notice-icon" /><span>Sunucu klasörlerine (/srv) hiçbir durumda dokunulmaz.</span></p>
      <p v-if="keepData" class="meter-note">Klasör kalır; aynı adla yeniden eklenince geri bağlanır. İstemezseniz Podman'da kullanılmayanlar arasından kaldırılır.</p>
      <template v-else-if="app">
        <p class="meter-note">Veriler geri alınamaz biçimde silinir; onaylamak için uygulamanın adını yazın.</p>
        <ConfirmWord v-model:confirmed="deleteTyped" :word="app.ad" />
      </template>
      <p v-if="actionError" class="form-error" role="alert" data-testid="dialog-error">{{ actionError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="acting !== null" @click="closeDialogs">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!removeReady || acting !== null" data-onay="kaldir" @click="confirmRemove">
          {{ acting === "kaldir" ? "Gönderiliyor…" : keepData ? "Kaldır" : "Kaldır ve verileri sil" }}
        </button>
      </template>
    </Modal>
  </div>
</template>
