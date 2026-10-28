<!-- Plan → apply for one settings change (DD-258 goal 4): the sheet asks POST /api/konsol/ayarlar/plan for
     `request` and shows the plan; "Uygula" sends the same body to …/uygula. A change that commits at once (DNS,
     anything that only closes access) ends here; a timed one (an opening, the firewall, the local domain) becomes
     the pending change, which the banner above every page confirms or rolls back. The default slot adds the
     page's own explanation above the plan.
     With a `form` slot the sheet has a step before the plan: while `request` is null it shows the form and a
     review button (`reviewLabel`; a submit button of the form named by `form`, otherwise it emits `review`); the
     page then sets `request` and the plan is asked for. "Geri" (emits `back`) returns to the form. An access row's
     apply may restart a service and wait until it is ready (minutes): the request stays open, the sheet says what
     it waits for and counts the seconds. With `inline` the same steps are a panel in the page (InlinePanel, under an
     access row in Adresler; `hideTitle` and a `lead` line as there); `busy` says while an apply runs, so the page
     holds its other controls meanwhile. An `extra` slot puts the form step's own actions at the start of the actions
     (a removal, another mode). -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref, useSlots, watch } from "vue";
import InlinePanel from "../../components/ui/InlinePanel.vue";
import Modal from "../../components/ui/Modal.vue";
import PlanReview from "../../components/ui/PlanReview.vue";
import { applySettings, planSettings } from "../../api/erisim";
import { refreshAccess, setPending, settingsChanged } from "../../live";
import type { AyarIstegi, AyarPlani, AyarSonucu } from "../../api/sema";

const props = withDefaults(
  defineProps<{
    open: boolean;
    title: string;
    description?: string;
    request: AyarIstegi | null;
    applyLabel?: string;
    danger?: boolean;
    reviewLabel?: string;
    canReview?: boolean;
    form?: string;
    inline?: boolean;
    hideTitle?: boolean;
  }>(),
  { description: "", applyLabel: "Uygula", danger: false, reviewLabel: "İncele", canReview: true, form: "", inline: false, hideTitle: false },
);
const emit = defineEmits<{ close: []; applied: [result: AyarSonucu]; review: []; back: []; busy: [busy: boolean] }>();
const slots = useSlots();

const plan = ref<AyarPlani | null>(null);
const planError = ref("");
const loading = ref(false);
const applying = ref(false);
const applyError = ref("");
const elapsed = ref(0);
let timer: number | undefined;
let seq = 0;

/** The form step: a form slot and no request yet. */
const editing = (): boolean => Boolean(slots.form) && props.request === null;

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

// The plan follows the request while the sheet is open: opening it, or the form step's review, asks for it.
watch(
  () => (props.open && props.request ? JSON.stringify(props.request) : ""),
  (key) => {
    applyError.value = "";
    if (!key) {
      seq += 1;
      plan.value = null;
      planError.value = "";
      loading.value = false;
      return;
    }
    applying.value = false;
    void load();
  },
  { immediate: true },
);

// What the apply waits for: an internet name's certificate (up to about a minute), an access row's service
// restart and ready check (up to a few minutes).
const certificate = computed(() => {
  const r = props.request;
  if (!r) return false;
  if ("web" in r) return r.web.enabled;
  if ("erisim" in r) return r.erisim.satir.tur === "adres" && r.erisim.satir.internet !== "" && Boolean(plan.value?.etkiler.some((e) => e.includes("sertifika")));
  return false;
});
const accessRow = computed(() => Boolean(props.request && "erisim" in props.request));
function startClock(): void {
  elapsed.value = 0;
  clearInterval(timer);
  timer = window.setInterval(() => (elapsed.value += 1), 1000);
}
watch(applying, (on) => emit("busy", on));
onBeforeUnmount(() => {
  clearInterval(timer);
  if (applying.value) emit("busy", false);
});

async function apply(): Promise<void> {
  const request = props.request;
  if (!request || !plan.value?.uygulanabilir || applying.value) return;
  applying.value = true;
  applyError.value = "";
  startClock();
  try {
    const result = await applySettings(request);
    if (result.pending) {
      setPending(result.pending);
      // An opening is live until it is confirmed or rolled back: Erişim shows what the server now serves.
      void refreshAccess();
    } else settingsChanged();
    emit("applied", result);
  } catch (err) {
    // The server rolled the change back; the draft stays for another try.
    applyError.value = err instanceof Error ? err.message : String(err);
    void refreshAccess();
  } finally {
    applying.value = false;
    clearInterval(timer);
  }
}

function close(): void {
  if (applying.value) return;
  emit("close");
}

function back(): void {
  if (applying.value) return;
  emit("back");
}

const progress = computed(() => {
  if (!applying.value) return "";
  const seconds = ` ${elapsed.value} sn`;
  if (accessRow.value) {
    return certificate.value
      ? `Uygulanıyor; servis gerekirse yeniden başlar ve internet adı için sertifika beklenir (birkaç dakika sürebilir)…${seconds}`
      : `Uygulanıyor; servis gerekirse yeniden başlar ve hazır olması beklenir (birkaç dakika sürebilir)…${seconds}`;
  }
  if (certificate.value) return `Uygulanıyor; internet adı için sertifika bekleniyor (en çok 1 dakika)…${seconds}`;
  return plan.value?.onay_sn ? `Uygulanıyor; ardından onayınız beklenecek…${seconds}` : `Uygulanıyor…${seconds}`;
});
</script>

<template>
  <component
    :is="inline ? InlinePanel : Modal"
    :open="open"
    v-bind="inline ? { hideTitle } : { variant: 'sheet' }"
    :title="title"
    :description="description"
    @close="close"
  >
    <template v-if="slots.lead" #lead><slot name="lead" /></template>
    <slot v-if="editing()" name="form" />
    <template v-else>
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
    </template>
    <template #actions>
      <template v-if="editing()">
        <span v-if="slots.extra" class="foot-start"><slot name="extra" /></span>
        <button type="button" class="btn btn-secondary" @click="close">Vazgeç</button>
        <button
          v-if="form"
          type="submit"
          :form="form"
          class="btn"
          :class="danger ? 'btn-danger' : 'btn-primary'"
          :disabled="!canReview"
          data-testid="review"
        >
          {{ reviewLabel }}
        </button>
        <button v-else type="button" class="btn" :class="danger ? 'btn-danger' : 'btn-primary'" :disabled="!canReview" data-testid="review" @click="emit('review')">
          {{ reviewLabel }}
        </button>
      </template>
      <template v-else>
        <button v-if="slots.form" type="button" class="btn btn-secondary" :disabled="applying" data-testid="plan-back" @click="back">Geri</button>
        <button v-else type="button" class="btn btn-secondary" :disabled="applying" @click="close">Vazgeç</button>
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
    </template>
  </component>
</template>
