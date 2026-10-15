<!-- "Katalogdan" (phase 4a; App Store's install, DD-148, DD-210): a sheet over Uygulamalar, ?ekle=katalog.
     The packages not installed with their own words (konsol.json: icon, description, what installing does,
     facts); one of them opens with &paket=<id>. Kur sends POST /api/konsol/uygulamalar/islem {id:"paket:<id>",
     eylem:"kur"}, with the package's install form as `form` when it declares one (drawn from the declaration,
     PackageForm). The engine's job ("modul", the package id) is followed in the live jobs; when it ends the
     application's page opens. A refusal or a failed job is shown in the server's words and the form stays. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from "vue";
import { RouterLink, useRouter } from "vue-router";
import { Icon } from "../../components/icons";
import AppIcon from "../../components/AppIcon.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import PackageForm from "./PackageForm.vue";
import { formOf, textsOf } from "./form";
import { followJob, listedEnd } from "./follow";
import { message, useQueryText } from "./flows";
import { readPackages } from "../../api/uygulama";
import { startAppAction } from "../../api/konsol";
import { refreshApps } from "../../live";
import { appRoute } from "../../router";
import { updateQuery } from "../../query";
import type { Modul } from "../../api/sema";

const router = useRouter();
const flow = useQueryText("ekle");
const chosenId = useQueryText("paket");
const open = computed(() => flow.value === "katalog");

const packages = ref<Modul[] | null>(null);
const listError = ref("");
type Phase = "form" | "sending" | "running" | "failed";
const phase = ref<Phase>("form");
const error = ref("");
const step = ref("");
let following: { stop: () => void } | null = null;
let seq = 0;

async function load(): Promise<void> {
  const mine = ++seq;
  try {
    const list = await readPackages();
    if (mine !== seq) return;
    packages.value = list;
    listError.value = "";
  } catch (err) {
    if (mine === seq) listError.value = message(err);
  }
}

function stopFollowing(): void {
  following?.stop();
  following = null;
}

function resetInstall(): void {
  stopFollowing();
  phase.value = "form";
  error.value = "";
  step.value = "";
}

watch(
  open,
  (on) => {
    resetInstall();
    if (on) void load();
    else {
      seq += 1;
      packages.value = null;
      listError.value = "";
    }
  },
  { immediate: true },
);
watch(chosenId, () => resetInstall());
onBeforeUnmount(stopFollowing);

const catalogue = computed(() =>
  (packages.value ?? [])
    .filter((m) => !m.installed)
    .map((m) => {
      const t = textsOf(m.id, m.konsol);
      return { m, t, icon: { id: "paket:" + m.id, simge: t.icon || null, tur: "paket" as const } };
    }),
);
const chosen = computed(() => (packages.value ?? []).find((m) => m.id === chosenId.value) ?? null);
const texts = computed(() => (chosen.value ? textsOf(chosen.value.id, chosen.value.konsol) : null));
const form = computed(() => (chosen.value ? formOf(chosen.value.konsol) : null));
const tile = computed(() => (chosen.value ? { id: "paket:" + chosen.value.id, simge: texts.value?.icon || null, tur: "paket" as const } : null));

// A package already being installed (another tab, a reload during its install): follow that job.
watch(
  () => chosen.value?.busy,
  (busy) => {
    const m = chosen.value;
    if (busy && m && !m.installed && phase.value === "form") follow(m, null, m.progress?.text || "Kurulum sürüyor…");
  },
);

function follow(m: Modul, before: number | null, first: string): void {
  stopFollowing();
  phase.value = "running";
  step.value = first;
  const f = followJob("modul", m.id, before, (job) => {
    if (job.adim) step.value = job.adim;
  });
  following = f;
  f.done.then(
    async (job) => {
      if (following !== f) return;
      following = null;
      if (job.durum === "hata") {
        phase.value = "failed";
        error.value = job.adim ? `Kurulum başarısız: ${job.adim}` : "Kurulum başarısız oldu.";
        void load();
        return;
      }
      await refreshApps();
      void router.push(appRoute("paket:" + m.id));
    },
    (err) => {
      if (following !== f) return;
      following = null;
      phase.value = "failed";
      error.value = message(err);
    },
  );
}

async function install(values?: Record<string, string>): Promise<void> {
  const m = chosen.value;
  if (!m || phase.value === "sending" || phase.value === "running") return;
  phase.value = "sending";
  error.value = "";
  const before = listedEnd("modul", m.id);
  try {
    await startAppAction({ id: "paket:" + m.id, eylem: "kur", ...(values ? { form: values } : {}) });
  } catch (err) {
    phase.value = "form";
    error.value = message(err);
    return;
  }
  void refreshApps();
  follow(m, before, "Kurulum başladı…");
}

function choose(id: string): void {
  updateQuery(router, { paket: id });
}

function back(): void {
  if (phase.value === "sending") return;
  updateQuery(router, { paket: null });
}

function close(): void {
  if (phase.value === "sending") return;
  updateQuery(router, { ekle: null, paket: null });
}

const title = computed(() => {
  if (!chosenId.value) return "Katalogdan kur";
  if (!texts.value) return "Katalogdan kur";
  return form.value?.kurBaslik || `${texts.value.name} kurulsun mu?`;
});
const subtitle = computed(() => (chosenId.value ? form.value?.kurAlt || texts.value?.sub || "" : "App Store uygulamaları: sunucuda kurulur, Konsol'dan yönetilir."));
const installing = computed(() => phase.value === "running" || phase.value === "sending");
const goLabel = computed(() => (phase.value === "sending" ? "Gönderiliyor…" : phase.value === "running" ? "Kuruluyor…" : phase.value === "failed" ? "Yeniden dene" : "Kur ve başlat"));
</script>

<template>
  <Modal :open="open" variant="sheet" :title="title" :description="subtitle" @close="close">
    <p v-if="listError" class="form-error" role="alert">{{ listError }}</p>
    <p v-else-if="!packages" class="meter-note" role="status">Katalog okunuyor…</p>

    <!-- the list -->
    <template v-else-if="!chosenId">
      <ul v-if="catalogue.length" class="catalog-list" aria-label="Kurulabilir uygulamalar" data-testid="catalog-list">
        <li v-for="c in catalogue" :key="c.m.id" class="catalog-item" :data-paket="c.m.id">
          <AppIcon :app="c.icon" size="sm" />
          <span class="catalog-text">
            <strong>{{ c.t.name }}</strong>
            <span class="muted">{{ c.t.sub }}</span>
            <span v-if="c.m.busy" class="warn-text">Kuruluyor…</span>
          </span>
          <button type="button" class="btn btn-secondary btn-sm" :aria-label="`${c.t.name}: ayrıntı ve kurulum`" @click="choose(c.m.id)">Ayrıntı</button>
        </li>
      </ul>
      <EmptyState v-else title="Katalogdaki uygulamaların hepsi kurulu" text="Kurulu uygulamalar Uygulamalar listesinde." icon="apps" />
    </template>

    <!-- one package -->
    <EmptyState v-else-if="!chosen" title="Bu paket katalogda yok" icon="apps">
      <button type="button" class="btn btn-secondary" @click="back">Kataloğa dön</button>
    </EmptyState>
    <section v-else class="flow-step catalog-detail" :aria-label="texts?.name" :data-paket="chosen.id">
      <div class="catalog-head">
        <AppIcon v-if="tile" :app="tile" size="lg" />
        <div class="catalog-head-text">
          <strong class="catalog-name">{{ texts?.name }}</strong>
          <span v-if="texts?.sub" class="muted">{{ texts.sub }}</span>
        </div>
      </div>
      <p v-if="texts?.description" class="card-text" data-testid="catalog-desc">{{ texts.description }}</p>
      <ul v-if="texts?.will.length" class="modal-list" aria-label="Kurulum ne yapar" data-testid="catalog-will">
        <li v-for="(w, i) in texts.will" :key="i"><Icon :name="w.icon" :size="18" /><span>{{ w.text }}</span></li>
      </ul>
      <p v-if="texts?.facts.length" class="catalog-facts" data-testid="catalog-facts">
        <span v-for="(f, i) in texts.facts" :key="i" class="fact-chip">{{ f }}</span>
      </p>

      <div v-if="chosen.installed" class="notice notice-ok" role="status">
        <Icon name="check" class="notice-icon" />
        <div>
          <p class="notice-title">{{ texts?.name }} kurulu.</p>
          <RouterLink :to="appRoute('paket:' + chosen.id)" class="btn btn-secondary btn-sm fit">Uygulamanın sayfası</RouterLink>
        </div>
      </div>
      <template v-else>
        <div v-if="phase === 'running'" class="flow-run" role="status" data-testid="install-progress">
          <div class="flow-run-head">
            <strong>Kuruluyor</strong>
            <StatusPill tone="accent">Sürüyor…</StatusPill>
          </div>
          <p class="cell-note" data-testid="install-step">{{ step }}</p>
          <p class="meter-note">Pencereyi kapatabilirsiniz; kurulum sunucuda sürer ve İşlemler'de görünür. Bitince uygulamanın sayfası açılır.</p>
        </div>
        <!-- Kept while the job runs (hidden), so a failed install comes back with what was typed. -->
        <section v-if="form" v-show="phase !== 'running'" class="form-section" aria-label="Kurulum bilgileri">
          <PackageForm form-id="kur-formu" mode="kur" :form="form" :busy="installing" @submit="install" />
          <p v-if="form.kurNot" class="meter-note" data-testid="install-note">{{ form.kurNot }}</p>
        </section>
        <p v-else-if="phase !== 'running'" class="meter-note">Kurulum bilgi istemez; Kur ile hemen başlar.</p>
      </template>
      <p v-if="error" class="form-error" role="alert" data-testid="install-error">{{ error }}</p>
    </section>

    <template #actions>
      <template v-if="chosenId">
        <button type="button" class="btn btn-secondary" :disabled="phase === 'sending'" data-testid="catalog-back" @click="back">Kataloğa dön</button>
        <template v-if="chosen && !chosen.installed && phase !== 'running'">
          <button v-if="form" type="submit" form="kur-formu" class="btn btn-primary" :disabled="installing" data-testid="install-go">{{ goLabel }}</button>
          <button v-else type="button" class="btn btn-primary" :disabled="installing" data-testid="install-go" @click="install()">{{ goLabel }}</button>
        </template>
      </template>
      <button v-else type="button" class="btn btn-secondary" @click="close">Kapat</button>
    </template>
  </Modal>
</template>
