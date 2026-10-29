<!-- One container's actions (DD-294): Başlat or Durdur and Yeniden başlat by its state, and "Kaldır…", for every
     container Konsol may act on, whoever installed it. An application's container leads to the application's page
     instead (its record stays true there). Each action is a job, followed in İşlemler and here: the step while it
     runs, how it ended once. Removal asks for the container's name; a systemd unit's container says the unit is
     stopped first and offers to delete its Quadlet file when it has one (ticked: otherwise the next boot brings it
     back; a unit file is disabled instead), and any container offers its anonymous volumes. Used in Podman's list (compact) and on the container's page. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import Modal from "../../components/ui/Modal.vue";
import { startContainerAction } from "../../api/podman";
import { readJob } from "../../api/konsol";
import { watchJob } from "../app/jobs";
import { appRoute } from "../../router";
import type { Islem, KonteynerEylemi, KonteynerYonetimi } from "../../api/sema";

const props = withDefaults(defineProps<{ name: string; state: string; manager: KonteynerYonetimi | null; busy?: string | null; compact?: boolean }>(), {
  busy: null,
  compact: false,
});
const emit = defineEmits<{ done: [action: KonteynerEylemi["eylem"], ok: boolean] }>();

type Action = KonteynerEylemi["eylem"];
const allowed = (a: Action) => props.manager?.eylemler.includes(a) ?? false;
const running = computed(() => props.state === "running");
const jobId = ref("");
const step = ref("");
const failure = ref("");
const note = ref("");
const holding = computed(() => Boolean(jobId.value) || Boolean(props.busy));
let stopWatch: (() => void) | null = null;

const DONE: Record<Action, string> = { baslat: "Başlatıldı.", durdur: "Durduruldu.", "yeniden-baslat": "Yeniden başlatıldı.", kaldir: "Kaldırıldı." };

async function ended(job: Islem | null, id: string, action: Action): Promise<void> {
  jobId.value = "";
  step.value = "";
  stopWatch = null;
  if (job?.durum === "hata") {
    failure.value = job.adim || "İşlem tamamlanamadı.";
    emit("done", action, false);
    return;
  }
  let text = DONE[action];
  try {
    const notes = (await readJob(id)).result?.notlar;
    if (Array.isArray(notes) && notes.length) text = `${text} ${notes.filter((n) => typeof n === "string").join(" ")}`;
  } catch {
    // the record may be gone; the drawer said how it ended
  }
  note.value = text;
  emit("done", action, true);
}

async function run(action: Action, extra: Partial<KonteynerEylemi> = {}): Promise<boolean> {
  if (holding.value || !allowed(action)) return false;
  failure.value = "";
  note.value = "";
  try {
    const job = await startContainerAction({ ad: props.name, eylem: action, ...extra });
    jobId.value = job.is;
    step.value = "Başlatılıyor";
    stopWatch = watchJob(job.is, (j) => void ended(j, job.is, action), (j) => (step.value = j.adim || step.value), "konteyner");
    return true;
  } catch (err) {
    failure.value = err instanceof Error ? err.message : String(err);
    return false;
  }
}

// ---- removal
const removeOpen = ref(false);
const word = ref(false);
const unitFile = ref(true);
const volumes = ref(false);
const sending = ref(false);
const removeError = ref("");
const isUnit = computed(() => props.manager?.tur === "birim");

function askRemove(): void {
  removeError.value = "";
  unitFile.value = true;
  volumes.value = false;
  removeOpen.value = true;
}

async function remove(): Promise<void> {
  if (!word.value || sending.value) return;
  sending.value = true;
  const ok = await run("kaldir", { onay: props.name, birim_dosyasi: Boolean(props.manager?.dosya) && unitFile.value, birimler: volumes.value });
  sending.value = false;
  if (ok) removeOpen.value = false;
  else removeError.value = failure.value;
}

onBeforeUnmount(() => stopWatch?.());
</script>

<template>
  <div class="container-actions" :class="{ 'container-actions-compact': compact }" :data-konteyner-eylem="name">
    <RouterLink v-if="manager?.tur === 'uygulama'" :to="appRoute(manager.ad)" class="btn btn-secondary btn-sm" data-eylem="uygulama"
      :aria-label="compact ? `${name}: ${manager.ad} uygulamasında yönet` : undefined" :title="compact ? 'Uygulamada yönet' : undefined">
      <Icon name="apps" :size="16" /><span :class="{ 'sr-only': compact }">Uygulamada yönet</span>
    </RouterLink>
    <template v-else-if="manager">
      <button v-if="!running && allowed('baslat')" type="button" class="btn btn-secondary btn-sm" :disabled="holding" data-eylem="baslat"
        :aria-label="compact ? `${name} başlat` : undefined" @click="run('baslat')">
        <Icon name="play" :size="16" /><span :class="{ 'sr-only': compact }">Başlat</span>
      </button>
      <button v-if="running && allowed('durdur')" type="button" class="btn btn-secondary btn-sm" :disabled="holding" data-eylem="durdur"
        :aria-label="compact ? `${name} durdur` : undefined" @click="run('durdur')">
        <Icon name="stop" :size="16" /><span :class="{ 'sr-only': compact }">Durdur</span>
      </button>
      <button v-if="running && allowed('yeniden-baslat')" type="button" class="btn btn-secondary btn-sm" :disabled="holding" data-eylem="yeniden-baslat"
        :aria-label="compact ? `${name} yeniden başlat` : undefined" @click="run('yeniden-baslat')">
        <Icon name="refresh" :size="16" /><span :class="{ 'sr-only': compact }">Yeniden başlat</span>
      </button>
      <button v-if="allowed('kaldir')" type="button" class="btn btn-danger-quiet btn-sm" :disabled="holding" data-eylem="kaldir"
        :aria-label="compact ? `${name} kaldır` : undefined" @click="askRemove">
        <Icon name="trash" :size="16" /><span :class="{ 'sr-only': compact }">Kaldır…</span>
      </button>
    </template>
    <span v-if="step" class="meter-note action-step" role="status" data-testid="container-step">{{ step }}…</span>
    <span v-else-if="busy" class="meter-note action-step" role="status">Bir işlem sürüyor…</span>
    <span v-if="failure && !removeOpen" class="form-error action-step" role="alert" data-testid="container-failure">{{ failure }}</span>
    <span v-else-if="note && !compact" class="meter-note action-step ok-text" role="status" data-testid="container-note">{{ note }}</span>

    <Modal :open="removeOpen" :title="`${name} kaldırılsın mı?`" @close="removeOpen = false">
      <p v-if="isUnit" data-testid="remove-unit-text">
        Bu konteyneri <span class="mono">{{ manager?.ad }}</span> birimi çalıştırıyor. Önce birim durdurulur, sonra konteyner kaldırılır.
      </p>
      <p v-else data-testid="remove-plain-text">Konteyner durdurulur ve kaldırılır. Adlı birimleri ve imajı yerinde kalır.</p>
      <label v-if="isUnit && manager?.dosya" class="check-row">
        <input v-model="unitFile" type="checkbox" data-testid="remove-unit-file" />
        <span>Birimin Quadlet dosyasını da sil (<span class="mono">{{ manager.dosya }}</span>). Silinmezse konteyner sunucu yeniden açılınca geri gelir.</span>
      </label>
      <p v-else-if="isUnit" class="meter-note" data-testid="remove-unit-disable">Birim kapatılır (disable); sunucu yeniden açılınca başlamaz.</p>
      <label class="check-row">
        <input v-model="volumes" type="checkbox" data-testid="remove-volumes" />
        <span>Adsız (anonim) birimlerini de sil</span>
      </label>
      <ConfirmWord v-model:confirmed="word" :word="name" />
      <p v-if="removeError" class="form-error" role="alert" data-testid="remove-error">{{ removeError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" @click="removeOpen = false">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!word || sending" data-testid="remove-confirm" @click="remove">Kaldır</button>
      </template>
    </Modal>
  </div>
</template>
