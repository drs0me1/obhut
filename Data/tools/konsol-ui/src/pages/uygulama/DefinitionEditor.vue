<!-- A Konsol container's definition on its Ayarlar (DD-211; the Podman page's "Düzenle"): the fields the
     server lets change (`editable` of GET …/konteynerler/ayrinti) as a draft that live updates never touch,
     then "Gözden geçir": each changed field (before → after) and what saving does (a running container is
     interrupted and re-created; its writable layer goes), "Kaydettikten sonra başlat" for a stopped one, and
     POST …/islem {action:"save", name, revision, config, start}. A stale revision (409) offers the current
     definition; a failed job keeps the draft. The browser asks before a reload drops the draft. -->
<script setup lang="ts">
import { computed, nextTick, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import ContainerFields from "./ContainerFields.vue";
import ChangeReview from "./ChangeReview.vue";
import { changes, configOut, consequences, draftFrom, networkChoices, problems, type Draft } from "./container";
import { useContainerSave } from "./save";
import { readInventory, type ContainerConfig, type ContainerDetail, type Inventory } from "../../api/podman";
import { useLeaveGuard } from "../../leave";

const props = defineProps<{ box: ContainerDetail & { generic: ContainerConfig } }>();
const emit = defineEmits<{ saved: []; reload: [] }>();

const inventory = ref<Inventory | null>(null);
const draft = ref<Draft>(draftFrom(props.box.generic));
const tried = ref(false);
const reviewOpen = ref(false);
const start = ref(false);
const done = ref("");
const root = ref<HTMLElement | null>(null);
const save = useContainerSave();
// After a save or "Güncel tanımı yükle" the next definition the page reads replaces the draft.
let takeNext = false;

onMounted(async () => {
  try {
    inventory.value = await readInventory();
  } catch {
    inventory.value = null; // the saved network stays offered; other bridges are listed once it reads
  }
});

const orig = computed(() => props.box.generic);
const running = computed(() => props.box.state === "running");
const networks = computed(() => networkChoices(inventory.value, orig.value.network));
const volumes = computed(() => (inventory.value?.volumes ?? []).map((v) => v.name));
const errors = computed(() => problems(draft.value, { create: false, editable: (f) => props.box.editable.includes(f), taken: new Set(), networks: networks.value,
  volumes: inventory.value ? new Set(volumes.value) : null }));
const config = computed(() => configOut(draft.value, orig.value));
const list = computed(() => changes(orig.value, config.value));
const effects = computed(() => consequences("save", running.value, list.value, config.value));
const dirty = computed(() => list.value.length > 0);
useLeaveGuard(dirty);

watch(
  () => props.box.revision,
  () => {
    if (takeNext || !dirty.value) {
      takeNext = false;
      draft.value = draftFrom(props.box.generic);
      tried.value = false;
    }
  },
);

function discard(): void {
  draft.value = draftFrom(props.box.generic);
  tried.value = false;
  done.value = "";
}

async function review(): Promise<void> {
  done.value = "";
  if (Object.keys(errors.value).length) {
    tried.value = true;
    await nextTick();
    root.value?.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus();
    return;
  }
  save.clear();
  start.value = false;
  reviewOpen.value = true;
}

async function apply(): Promise<void> {
  const ok = await save.send(
    { action: "save", name: props.box.name, revision: props.box.revision, config: config.value, start: !running.value && start.value },
    running.value ? "Konteyner yeniden oluşturuluyor…" : "Tanım kaydediliyor…",
  );
  if (!ok) return;
  takeNext = true;
  reviewOpen.value = false;
  done.value = "Değişiklikler uygulandı.";
  emit("saved");
}

function reload(): void {
  takeNext = true;
  reviewOpen.value = false;
  save.clear();
  emit("reload");
}

function closeReview(): void {
  if (save.state.value === "sending") return;
  reviewOpen.value = false;
}

const status = computed(() => (dirty.value ? `${list.value.length} değişiklik; henüz kaydedilmedi.` : "Değişiklik yok."));
const goLabel = computed(() => {
  if (save.state.value === "sending") return "Gönderiliyor…";
  if (save.state.value === "running") return running.value ? "Yeniden oluşturuluyor…" : "Kaydediliyor…";
  return running.value ? "Uygula ve yeniden oluştur" : start.value ? "Kaydet ve başlat" : "Kaydet";
});
</script>

<template>
  <Card title="Tanım" data-testid="definition">
    <p class="card-text muted">Konsol'un bu konteyner için sakladığı tanım. Değişiklikler gözden geçirilmeden uygulanmaz.</p>
    <div ref="root">
      <ContainerFields :draft="draft" :create="false" :editable="box.editable" :networks="networks" :volumes="volumes" :errors="errors" :show="tried" />
    </div>
    <p v-if="done" class="notice notice-ok" role="status" data-testid="definition-done"><Icon name="check" class="notice-icon" /><span>{{ done }}</span></p>
    <div class="draft-bar" data-testid="definition-bar">
      <span class="meter-note" role="status" data-testid="definition-status">{{ status }}</span>
      <div class="draft-actions">
        <button v-if="dirty" type="button" class="btn btn-secondary" data-testid="definition-discard" @click="discard">Değişiklikleri at</button>
        <button type="button" class="btn btn-primary" :disabled="!dirty" data-testid="definition-review" @click="review">Gözden geçir</button>
      </div>
    </div>
  </Card>

  <Modal :open="reviewOpen" variant="sheet" :title="`${box.name} · değişiklikler`" description="Henüz hiçbir şey değişmedi; Uygula'ya basınca kaydedilir." @close="closeReview">
    <div class="flow-step uyg-wide" data-testid="definition-sheet">
      <ChangeReview :changes="list" :consequences="effects" />
      <label v-if="!running" class="check-option check-calm" data-testid="start-after">
        <input v-model="start" type="checkbox" :disabled="save.state.value !== ''" />
        <span>
          <strong>Kaydettikten sonra başlat</strong>
          <small>İşaretlemezseniz durmuş kalır.</small>
        </span>
      </label>
      <div v-if="save.state.value === 'running'" class="flow-run" role="status" data-testid="definition-run">
        <div class="flow-run-head">
          <strong>{{ box.name }}</strong>
          <StatusPill tone="accent">Sürüyor…</StatusPill>
        </div>
        <p class="cell-note">{{ save.step.value }}</p>
      </div>
      <div v-if="save.error.value" class="notice notice-danger" role="alert" data-testid="definition-error">
        <Icon name="xcircle" class="notice-icon" />
        <div class="form-stack">
          <p><strong>Uygulanamadı.</strong> {{ save.error.value }}</p>
          <button v-if="save.stale.value" type="button" class="btn btn-secondary btn-sm fit" data-testid="definition-reload" @click="reload">
            <Icon name="refresh" :size="16" />Güncel tanımı yükle
          </button>
          <p v-if="save.stale.value" class="meter-note">Güncel tanım yüklenince bu taslak atılır.</p>
        </div>
      </div>
    </div>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="save.state.value === 'sending' || save.state.value === 'running'" data-testid="definition-back" @click="closeReview">Düzenlemeye dön</button>
      <button type="button" class="btn btn-primary" :disabled="save.state.value === 'sending' || save.state.value === 'running' || save.stale.value" data-testid="definition-apply" @click="apply">{{ goLabel }}</button>
    </template>
  </Modal>
</template>
