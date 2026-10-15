<!-- An application's Günlük: its last lines (GET /api/konsol/uygulamalar/gunluk: a container's unit journal
     or podman log, a package's engine log), as many as chosen (?satir=100|200|500|1000, 200 when absent),
     "Yenile", and "Canlı" (?canli=1), which reads them again every 5 s while it is on and the tab is
     visible. The search (?ara=) keeps the matching lines, matched with Turkish case rules, and marks each
     match. The view stays at the newest line unless the reader scrolled up. Built-ins keep their log in
     Ayarlar → Günlük. The log is shown as written: an application's own secrets in it are visible too. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import Switch from "../../components/ui/Switch.vue";
import { readAppLog } from "../../api/konsol";
import { useQueryFlag, useQueryParam } from "../../query";
import { clock, fold } from "../../format";
import type { Uygulama, UygulamaGunlugu } from "../../api/sema";

const TAILS = ["100", "200", "500", "1000"] as const;
type Tail = (typeof TAILS)[number];
const props = defineProps<{ app: Uygulama }>();

const liveOn = useQueryFlag("canli");
const tail = useQueryParam<Tail>("satir", TAILS, "200");
const searchParam = useQueryParam<string>("ara", null, "");
const search = ref(searchParam.value);
watch(searchParam, (value) => {
  if (value !== search.value) search.value = value;
});
watch(search, (value) => (searchParam.value = value));

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
    const value = await readAppLog(props.app.id, Number(tail.value));
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

// Another application in the same page, or another number of lines: read again (a read under way is dropped).
watch(
  () => [props.app.id, tail.value],
  ([id], [before]) => {
    seq += 1;
    loading.value = false;
    if (id !== before) log.value = null;
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

// ---- the search: matching lines, each match marked
interface Part {
  text: string;
  hit: boolean;
}

function parts(line: string, needle: string): Part[] | null {
  // Fold each character on its own, so a fold that changes a character's length keeps the positions right.
  const chars = Array.from(line);
  const folded = chars.map((c) => fold(c));
  const hay = folded.join("");
  if (!hay.includes(needle)) return null;
  const starts: number[] = [];
  let pos = 0;
  for (const f of folded) {
    starts.push(pos);
    pos += f.length;
  }
  const out: Part[] = [];
  let from = 0;
  let at = hay.indexOf(needle);
  while (at >= 0) {
    // The first character that ends after the match starts, up to the first that starts after it ends.
    const first = starts.findIndex((s, i) => at < s + Math.max(1, folded[i]?.length ?? 1));
    const endPos = at + needle.length;
    let last = first;
    while (last < chars.length && (starts[last] ?? Infinity) < endPos) last += 1;
    if (first > from) out.push({ text: chars.slice(from, first).join(""), hit: false });
    out.push({ text: chars.slice(first, last).join(""), hit: true });
    from = last;
    at = hay.indexOf(needle, endPos);
  }
  if (from < chars.length) out.push({ text: chars.slice(from).join(""), hit: false });
  return out;
}

const needle = computed(() => fold(search.value.trim()));
const shown = computed(() => {
  const lines = log.value?.satirlar ?? [];
  if (!needle.value) return lines.map((line) => [{ text: line, hit: false }]);
  return lines.map((line) => parts(line, needle.value)).filter((p): p is Part[] => p !== null);
});
const matchText = computed(() => (needle.value && log.value ? `${shown.value.length} satır eşleşiyor` : ""));
</script>

<template>
  <section class="card log-card" aria-label="Günlük" data-testid="log">
    <div class="log-toolbar">
      <Switch v-model="liveOn" label="Canlı" data-testid="live-switch" />
      <span class="meter-note" data-testid="log-read">{{ readAt ? `Son okuma ${clock(readAt)}` : loading ? "Okunuyor…" : "" }}</span>
      <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" @click="load"><Icon name="refresh" :size="16" />Yenile</button>
    </div>
    <div class="log-tools">
      <div class="search-box log-search">
        <label for="gunluk-ara" class="sr-only">Günlükte ara</label>
        <Icon name="search" :size="18" class="search-icon" />
        <input id="gunluk-ara" v-model="search" class="input" type="search" placeholder="Günlükte ara" autocomplete="off" spellcheck="false" data-testid="log-search" />
      </div>
      <div class="choice-chips" role="radiogroup" aria-label="Satır sayısı" data-testid="log-tail">
        <label v-for="n in TAILS" :key="n" class="choice-chip">
          <input v-model="tail" type="radio" name="gunluk-satir" :value="n" />
          <span>{{ n }}</span>
        </label>
      </div>
    </div>
    <p class="sr-only" role="status">{{ matchText }}</p>
    <p v-if="error" class="form-error" role="alert" data-testid="log-error">{{ error }}</p>
    <p v-if="error && builtin" class="meter-note"><a href="/#/ayarlar/log">Ayarlar → Günlük</a></p>
    <template v-if="log">
      <ol v-if="shown.length" ref="box" class="log" tabindex="0" aria-label="Günlük satırları" data-testid="log-lines">
        <li v-for="(line, i) in shown" :key="i"><template v-for="(p, j) in line" :key="j"><mark v-if="p.hit" class="log-hit">{{ p.text }}</mark><template v-else>{{ p.text }}</template></template></li>
      </ol>
      <EmptyState v-else-if="needle" title="Eşleşen satır yok" icon="search" />
      <EmptyState v-else title="Günlükte satır yok" icon="lines" />
      <p v-if="matchText" class="meter-note" data-testid="log-matches">{{ matchText }}</p>
      <p v-if="log.kesik" class="meter-note">Yalnız son {{ tail }} satır gösteriliyor.</p>
    </template>
  </section>
</template>
