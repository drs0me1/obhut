<!-- Onarım kaydı (DD-241; A7): master-onar's lines (Konsol, SSH, the hourly firewall check's findings) and the
     address refresh's (boot, nightly 03–04, Caddy failures) for the last 72 hours or the last week, as the
     server's plain text (GET /api/konsol/onarim/gunluk?sure=). Open while ?kayit= is in the address; the
     text scrolls inside the sheet, starts at its newest line and can be copied whole. -->
<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import Modal from "../../components/ui/Modal.vue";
import CopyButton from "../../components/ui/CopyButton.vue";
import { readRepairLog } from "../../api/sistem";

const props = defineProps<{ span: "" | "72s" | "7g" }>();
const emit = defineEmits<{ span: [value: "72s" | "7g"]; close: [] }>();

const SPANS = [
  { id: "72s", label: "72 saat", title: "Son 72 saat" },
  { id: "7g", label: "1 hafta", title: "Son 1 hafta" },
] as const;

const text = ref<string | null>(null);
const error = ref("");
const box = ref<HTMLElement | null>(null);
let seq = 0;

async function load(span: "72s" | "7g"): Promise<void> {
  const mine = ++seq;
  text.value = null;
  error.value = "";
  try {
    const value = await readRepairLog(span);
    if (mine !== seq) return;
    text.value = value.trim();
    await nextTick();
    if (box.value) box.value.scrollTop = box.value.scrollHeight;
  } catch (err) {
    if (mine === seq) error.value = err instanceof Error ? err.message : String(err);
  }
}

watch(() => props.span, (span) => {
  if (span) void load(span);
  else seq += 1;
}, { immediate: true });

const title = computed(() => SPANS.find((s) => s.id === props.span)?.title ?? "");
</script>

<template>
  <Modal :open="span !== ''" variant="sheet" title="Onarım kaydı" :description="title" @close="emit('close')">
    <div class="log-toolbar">
      <div class="filters" role="group" aria-label="Süre">
        <button v-for="s in SPANS" :key="s.id" type="button" class="filter-chip" :aria-pressed="span === s.id" :data-sure="s.id" @click="emit('span', s.id)">
          {{ s.label }}
        </button>
      </div>
      <CopyButton v-if="text" :text="text" label="Onarım kaydı" />
    </div>
    <p v-if="error" class="form-error" role="alert" data-testid="repair-log-error">{{ error }}</p>
    <p v-else-if="text === null" class="meter-note" role="status">Okunuyor…</p>
    <pre v-else ref="box" class="log repair-log" tabindex="0" aria-label="Onarım kaydının metni" data-testid="repair-log-text">{{ text || "Bu sürede kayıt yok." }}</pre>
  </Modal>
</template>
