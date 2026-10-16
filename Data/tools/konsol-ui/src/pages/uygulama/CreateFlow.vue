<!-- "Bir imajdan" (phase 4a; the Podman page's "Yeni konteyner", DD-211): a sheet over Uygulamalar,
     ?ekle=imaj, in three steps. Tanım: every field of the definition editor (ContainerFields; the networks
     and volumes from GET /api/konsol/konteynerler/liste, whose names are taken). Gözden geçir: what will be
     created and what that does, internet ports called out, "Oluşturunca başlat". Oluştur: POST
     …/konteynerler/islem {action:"create", config, start}, the job followed in the live jobs; when it is
     done the new application's page opens. A refusal stays on the review in the server's words; a failed
     job offers the way back to the definition, which keeps the draft. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { Icon } from "../../components/icons";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import ContainerFields from "./ContainerFields.vue";
import ChangeReview from "./ChangeReview.vue";
import { changes, configOut, consequences, emptyDraft, networkChoices, problems, type Draft } from "./container";
import { followJob } from "./follow";
import { message, useQueryText } from "./flows";
import { readInventory, startContainerAction, type Inventory } from "../../api/podman";
import { refreshApps } from "../../live";
import { appRoute } from "../../router";
import { updateQuery } from "../../query";
import { useLeaveGuard } from "../../leave";

const router = useRouter();
const flow = useQueryText("ekle");
const open = computed(() => flow.value === "imaj");

type Step = 1 | 2 | 3;
const STEPS: readonly { n: Step; label: string }[] = [
  { n: 1, label: "Tanım" },
  { n: 2, label: "Gözden geçir" },
  { n: 3, label: "Oluştur" },
];
const step = ref<Step>(1);
const inventory = ref<Inventory | null>(null);
const inventoryError = ref("");
const draft = ref<Draft>(emptyDraft());
const tried = ref(false);
const start = ref(true);
const sending = ref(false);
const sendError = ref("");
const run = ref<{ state: "running" | "failed"; step: string; error: string } | null>(null);
const body = ref<HTMLElement | null>(null);
let following: { stop: () => void } | null = null;
let seq = 0;

async function load(): Promise<void> {
  const mine = ++seq;
  try {
    const value = await readInventory();
    if (mine !== seq) return;
    inventory.value = value;
    inventoryError.value = "";
  } catch (err) {
    if (mine === seq) inventoryError.value = message(err);
  }
}

function reset(): void {
  following?.stop();
  following = null;
  step.value = 1;
  draft.value = emptyDraft();
  tried.value = false;
  start.value = true;
  sending.value = false;
  sendError.value = "";
  run.value = null;
}

watch(
  open,
  (on) => {
    reset();
    if (on) void load();
    else {
      seq += 1;
      inventory.value = null;
      inventoryError.value = "";
    }
  },
  { immediate: true },
);
onBeforeUnmount(() => following?.stop());

const networks = computed(() => networkChoices(inventory.value));
const taken = computed(() => new Set((inventory.value?.containers ?? []).map((c) => c.name)));
const volumes = computed(() => (inventory.value?.volumes ?? []).map((v) => v.name));
const runtimeDown = computed(() => (inventory.value && !inventory.value.runtime.ok ? inventory.value.runtime.error || "Podman yanıt vermiyor." : ""));
const errors = computed(() => problems(draft.value, { create: true, editable: () => true, taken: taken.value, networks: networks.value,
  volumes: inventory.value ? new Set(volumes.value) : null }));
const config = computed(() => configOut(draft.value, null));
const list = computed(() => changes(null, config.value));
const effects = computed(() => consequences("create", false, list.value, config.value));
const publicPorts = computed(() => config.value.ports.filter((p) => p.scope === "public"));
const pristine = JSON.stringify(emptyDraft(), (k, v) => (k === "key" ? undefined : v));
const dirty = computed(() => open.value && run.value?.state !== "running" && JSON.stringify(draft.value, (k, v) => (k === "key" ? undefined : v)) !== pristine);
useLeaveGuard(dirty);

async function next(): Promise<void> {
  if (Object.keys(errors.value).length) {
    tried.value = true;
    await nextTick();
    body.value?.closest(".modal")?.querySelector<HTMLElement>('[aria-invalid="true"], .field-error')?.scrollIntoView({ block: "center" });
    body.value?.closest(".modal")?.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus();
    return;
  }
  sendError.value = "";
  step.value = 2;
  await nextTick();
  body.value?.closest(".modal")?.querySelector<HTMLElement>('[data-testid="review-title"]')?.focus();
}

async function create(): Promise<void> {
  if (sending.value || run.value?.state === "running") return;
  const cfg = config.value;
  sending.value = true;
  sendError.value = "";
  let id = "";
  try {
    id = (await startContainerAction({ action: "create", config: cfg, start: start.value })).id;
  } catch (err) {
    sendError.value = message(err);
    sending.value = false;
    return;
  }
  sending.value = false;
  step.value = 3;
  run.value = { state: "running", step: "İmaj çekiliyor…", error: "" };
  const current = run.value;
  void refreshApps();
  const f = followJob("konteyner", id, (job) => {
    if (job.adim) current.step = job.adim;
  });
  following = f;
  try {
    const job = await f.done;
    following = null;
    if (job.durum === "hata") {
      current.state = "failed";
      current.error = job.adim ? `Oluşturulamadı: ${job.adim}` : "Oluşturulamadı.";
      return;
    }
  } catch (err) {
    following = null;
    current.state = "failed";
    current.error = message(err);
    return;
  }
  await refreshApps();
  void router.push(appRoute("konteyner:" + cfg.name));
}

function back(): void {
  if (sending.value || run.value?.state === "running") return;
  if (step.value === 1) close();
  else {
    run.value = null;
    step.value = 1;
  }
}

function close(): void {
  if (sending.value) return;
  following?.stop();
  following = null;
  updateQuery(router, { ekle: null });
}

const primary = computed<{ label: string; disabled: boolean; go: () => void }>(() => {
  if (step.value === 1) return { label: "Gözden geçir", disabled: !inventory.value || Boolean(runtimeDown.value), go: () => void next() };
  if (step.value === 2) return { label: sending.value ? "Gönderiliyor…" : start.value ? "Oluştur ve başlat" : "Oluştur", disabled: sending.value, go: () => void create() };
  if (run.value?.state === "failed") return { label: "Tanıma dön", disabled: false, go: back };
  return { label: "Oluşturuluyor…", disabled: true, go: () => undefined };
});
</script>

<template>
  <Modal :open="open" variant="sheet" title="Bir imajdan konteyner" description="Konsol tanımı saklar ve konteyneri systemd ile çalıştırır." @close="close">
    <div ref="body" class="flow-step uyg-wide" data-testid="create-flow">
      <ol class="stepper" aria-label="Adımlar">
        <li v-for="s in STEPS" :key="s.n" :aria-current="step === s.n ? 'step' : undefined" :class="{ done: s.n < step }">
          <span class="stepper-n" aria-hidden="true">{{ s.n }}</span>{{ s.label }}
        </li>
      </ol>
      <p v-if="inventoryError" class="form-error" role="alert">{{ inventoryError }}</p>
      <p v-else-if="!inventory" class="meter-note" role="status">Podman okunuyor…</p>
      <p v-else-if="runtimeDown" class="notice notice-warning" role="alert"><Icon name="alert" class="notice-icon" /><span>{{ runtimeDown }}</span></p>

      <ContainerFields
        v-if="step === 1"
        :draft="draft"
        create
        :networks="networks"
        :volumes="volumes"
        :errors="errors"
        :show="tried"
      />
      <template v-else-if="step === 2">
        <ChangeReview :changes="list" :consequences="effects" create />
        <div v-if="publicPorts.length" class="notice notice-danger" role="note" data-testid="public-ports">
          <Icon name="alert" class="notice-icon" />
          <div>
            <p class="notice-title">İnternete açık port: {{ publicPorts.map((p) => `${p.host_port}/${p.protocol}`).join(", ") }}</p>
            <p>İnternetteki herkes bu porta bağlanabilir; erişimi yalnız uygulamanın kendi girişi korur.</p>
          </div>
        </div>
        <label class="check-option check-calm" data-testid="start-after">
          <input v-model="start" type="checkbox" />
          <span>
            <strong>Oluşturunca başlat</strong>
            <small>İşaretlemezseniz oluşturulur ama başlatılmaz.</small>
          </span>
        </label>
        <p v-if="sendError" class="form-error" role="alert" data-testid="create-error">{{ sendError }}</p>
      </template>
      <template v-else-if="run">
        <div class="flow-run" :data-durum="run.state" data-testid="create-run">
          <div class="flow-run-head">
            <strong>{{ config.name }}</strong>
            <StatusPill :tone="run.state === 'failed' ? 'danger' : 'accent'">{{ run.state === "failed" ? "Başarısız" : "Sürüyor…" }}</StatusPill>
          </div>
          <p v-if="run.state === 'running'" class="cell-note" role="status" data-testid="create-step">{{ run.step }}</p>
          <p v-else class="form-error" role="alert" data-testid="create-error">{{ run.error }}</p>
          <p v-if="run.state === 'running'" class="meter-note">Pencereyi kapatabilirsiniz; işlem sunucuda sürer ve İşlemler'de görünür. Bitince uygulamanın sayfası açılır.</p>
        </div>
      </template>
    </div>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="sending || run?.state === 'running'" data-testid="create-back" @click="back">{{ step === 1 ? "Vazgeç" : "Geri" }}</button>
      <button v-if="run?.state === 'running'" type="button" class="btn btn-secondary" data-testid="create-close" @click="close">Kapat</button>
      <button v-else type="button" class="btn btn-primary" :disabled="primary.disabled" data-testid="create-go" @click="primary.go">{{ primary.label }}</button>
    </template>
  </Modal>
</template>
