<!-- Plan → apply for one settings change (DD-258 goal 4): the sheet asks POST /api/konsol/ayarlar/plan for
     `request` when it opens and shows the plan; "Uygula" sends the same body to …/uygula. A change that commits
     at once (DNS, a publication row) ends here; a timed one (the firewall, the local domain) becomes the
     pending change, which the banner above every page confirms or rolls back. The default slot adds the
     page's own explanation above the plan. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from "vue";
import Modal from "../../components/ui/Modal.vue";
import PlanReview from "../../components/ui/PlanReview.vue";
import { applySettings, planSettings } from "../../api/erisim";
import { setPending, settingsChanged } from "../../live";
import type { AyarIstegi, AyarPlani, AyarSonucu } from "../../api/sema";

const props = withDefaults(defineProps<{ open: boolean; title: string; description?: string; request: AyarIstegi | null; applyLabel?: string; danger?: boolean }>(), {
  description: "",
  applyLabel: "Uygula",
  danger: false,
});
const emit = defineEmits<{ close: []; applied: [result: AyarSonucu] }>();

const plan = ref<AyarPlani | null>(null);
const planError = ref("");
const loading = ref(false);
const applying = ref(false);
const applyError = ref("");
const elapsed = ref(0);
let timer: number | undefined;
let seq = 0;

async function load(): Promise<void> {
  const request = props.request;
  if (!request) return;
  const mine = ++seq;
  loading.value = true;
  planError.value = "";
  plan.value = null;
  try {
    const value = await planSettings(request);
    if (mine === seq) plan.value = value;
  } catch (err) {
    if (mine === seq) planError.value = err instanceof Error ? err.message : String(err);
  } finally {
    if (mine === seq) loading.value = false;
  }
}

watch(
  () => props.open,
  (open) => {
    if (!open) return;
    applyError.value = "";
    applying.value = false;
    void load();
  },
  { immediate: true },
);

// A publication row with an internet name waits for its certificate (up to about a minute): say so.
const certificate = computed(() => Boolean(props.request?.web?.enabled));
function startClock(): void {
  elapsed.value = 0;
  clearInterval(timer);
  timer = window.setInterval(() => (elapsed.value += 1), 1000);
}
onBeforeUnmount(() => clearInterval(timer));

async function apply(): Promise<void> {
  const request = props.request;
  if (!request || !plan.value?.uygulanabilir || applying.value) return;
  applying.value = true;
  applyError.value = "";
  startClock();
  try {
    const result = await applySettings(request);
    if (result.pending) setPending(result.pending);
    else settingsChanged();
    emit("applied", result);
  } catch (err) {
    // The server rolled the change back; the draft stays for another try.
    applyError.value = err instanceof Error ? err.message : String(err);
  } finally {
    applying.value = false;
    clearInterval(timer);
  }
}

function close(): void {
  if (applying.value) return;
  emit("close");
}

const progress = computed(() => {
  if (!applying.value) return "";
  if (certificate.value) return `Uygulanıyor; internet adı için sertifika bekleniyor (en çok 1 dakika)… ${elapsed.value} sn`;
  return plan.value?.onay_sn ? "Uygulanıyor; ardından onayınız beklenecek…" : "Uygulanıyor…";
});
</script>

<template>
  <Modal :open="open" variant="sheet" :title="title" :description="description" @close="close">
    <slot />
    <p v-if="loading" class="meter-note" role="status">Plan hazırlanıyor…</p>
    <div v-else-if="planError" class="plan-error">
      <p class="form-error" role="alert" data-testid="plan-error">{{ planError }}</p>
      <button type="button" class="btn btn-secondary btn-sm fit" @click="load">Yeniden denetle</button>
    </div>
    <PlanReview v-else-if="plan" :plan="plan" />
    <p class="sr-only" role="status">{{ progress }}</p>
    <p v-if="progress" class="action-note" aria-hidden="true" data-testid="apply-progress">{{ progress }}</p>
    <p v-if="applyError" class="form-error" role="alert" data-testid="apply-error">{{ applyError }}</p>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="applying" @click="close">Vazgeç</button>
      <button
        type="button"
        class="btn"
        :class="danger ? 'btn-danger' : 'btn-primary'"
        :disabled="!plan || !plan.uygulanabilir || applying || loading"
        data-testid="apply"
        @click="apply"
      >
        {{ applying ? "Uygulanıyor…" : applyLabel }}
      </button>
    </template>
  </Modal>
</template>
