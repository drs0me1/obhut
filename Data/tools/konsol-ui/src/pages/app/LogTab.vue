<!-- An application's Günlük: the last 200 lines (GET /api/konsol/uygulamalar/gunluk), "Yenile", and "Canlı"
     (in the address, ?canli=1), which reads them again every 5 s while it is on and the tab is visible. The
     view stays at the newest line unless the reader scrolled up. Built-ins keep their log in Ayarlar → Günlük. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import Switch from "../../components/ui/Switch.vue";
import { readAppLog } from "../../api/konsol";
import { useQueryFlag } from "../../query";
import { clock } from "../../format";
import type { Uygulama, UygulamaGunlugu } from "../../api/sema";

const LINES = 200;
const props = defineProps<{ app: Uygulama }>();

const liveOn = useQueryFlag("canli");
const log = ref<UygulamaGunlugu | null>(null);
const error = ref("");
const loading = ref(false);
const readAt = ref(0);
const box = ref<HTMLElement | null>(null);
let timer: number | undefined;
let seq = 0;

async function load(): Promise<void> {
  if (loading.value) return;
  loading.value = true;
  const mine = ++seq;
  const el = box.value;
  const atEnd = !el || el.scrollHeight - el.scrollTop - el.clientHeight < 24;
  try {
    const value = await readAppLog(props.app.id, LINES);
    if (mine !== seq) return;
    log.value = value;
    error.value = "";
    readAt.value = Date.now() / 1000;
    if (atEnd) {
      await nextTick();
      if (box.value) box.value.scrollTop = box.value.scrollHeight;
    }
  } catch (err) {
    if (mine === seq) error.value = err instanceof Error ? err.message : String(err);
  } finally {
    if (mine === seq) loading.value = false;
  }
}

function stopTimer(): void {
  clearInterval(timer);
  timer = undefined;
}

watch(
  liveOn,
  (on) => {
    stopTimer();
    if (on) {
      timer = window.setInterval(() => {
        if (!document.hidden) void load();
      }, 5000);
    }
  },
  { immediate: true },
);

// Another application in the same page: its own lines only (a read still under way is dropped).
watch(
  () => props.app.id,
  () => {
    seq += 1;
    loading.value = false;
    log.value = null;
    error.value = "";
    void load();
  },
);

onMounted(() => void load());
onBeforeUnmount(() => {
  stopTimer();
  seq += 1;
});

const builtin = computed(() => props.app.tur === "yerlesik");
</script>

<template>
  <section class="card log-card" aria-label="Günlük" data-testid="log">
    <div class="log-toolbar">
      <Switch v-model="liveOn" label="Canlı" data-testid="live-switch" />
      <span class="meter-note" data-testid="log-read">{{ readAt ? `Son okuma ${clock(readAt)}` : loading ? "Okunuyor…" : "" }}</span>
      <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" @click="load"><Icon name="refresh" :size="16" />Yenile</button>
    </div>
    <p v-if="error" class="form-error" role="alert" data-testid="log-error">{{ error }}</p>
    <p v-if="error && builtin" class="meter-note"><a href="/#/ayarlar/log">Ayarlar → Günlük</a></p>
    <template v-if="log">
      <ol v-if="log.satirlar.length" ref="box" class="log" tabindex="0" aria-label="Günlük satırları" data-testid="log-lines">
        <li v-for="(line, i) in log.satirlar" :key="i">{{ line }}</li>
      </ol>
      <EmptyState v-else title="Günlükte satır yok" icon="lines" />
      <p v-if="log.kesik" class="meter-note">Yalnız son {{ LINES }} satır gösteriliyor.</p>
    </template>
  </section>
</template>
