<!-- Sistem → Günlük: what was done from Konsol in the last seven days (GET /api/konsol/islemler; the root and
     the file backends' audit lines), newest first, worded by audit.ts (with
     the packages' own templates from GET /api/konsol/moduller). Filter chips for the kinds present (?tur=)
     and a search (?ara=, Turkish case rules) over the line, the kind, the user and the address. A table on
     wide screens, cards on narrow ones. -->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import { readAudit, readModules } from "../../api/sistem";
import { KIND_ORDER, kindLabel, kindOf, lineOf, packagesOf, type Packages } from "./audit";
import { useQueryParam } from "../../query";
import { clock, fold } from "../../format";
import type { KayitSatiri, Modul } from "../../api/sema";

const rows = ref<KayitSatiri[] | null>(null);
const modules = ref<Modul[]>([]);
const error = ref("");
const loading = ref(false);
const readAt = ref(0);

async function load(): Promise<void> {
  loading.value = true;
  // The packages only name things; the log shows without them (an id and the verb).
  const names = readModules().then((m) => (modules.value = m), () => undefined);
  try {
    const items = await readAudit();
    await names;
    rows.value = [...items].sort((a, b) => b.at - a.at);
    error.value = "";
    readAt.value = Date.now() / 1000;
  } catch (err) {
    error.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}
onMounted(() => void load());

const packages = computed<Packages>(() => packagesOf(modules.value));
const entries = computed(() =>
  (rows.value ?? []).map((e, i) => {
    const kind = kindOf(e);
    const label = kindLabel(kind, packages.value);
    const line = lineOf(e, packages.value);
    return { key: `${e.at}:${i}`, e, kind, label, line, hay: fold(`${line} ${label} ${e.user} ${e.client} ${e.action} ${e.detail}`) };
  }),
);

const kinds = computed(() => {
  const present = new Set(entries.value.map((x) => x.kind));
  const order = [...KIND_ORDER.filter((k) => present.has(k)), ...[...present].filter((k) => !KIND_ORDER.includes(k))];
  return order.map((id) => ({ id, label: kindLabel(id, packages.value), count: entries.value.filter((x) => x.kind === id).length }));
});
const kind = useQueryParam<string>("tur", null, "");
const queryParam = useQueryParam<string>("ara", null, "");
// The field follows the address and writes it back; typing never waits for the router.
const query = ref(queryParam.value);
watch(queryParam, (value) => {
  if (value !== query.value) query.value = value;
});
watch(query, (value) => (queryParam.value = value));
const shown = computed(() => {
  const tokens = fold(query.value).split(/\s+/).filter(Boolean);
  return entries.value.filter((x) => (!kind.value || x.kind === kind.value) && tokens.every((t) => x.hay.includes(t)));
});

const today = () => new Date().toDateString();
const dayFormat = new Intl.DateTimeFormat("tr-TR", { day: "numeric", month: "short" });
function when(at: number): string {
  const d = new Date(at * 1000);
  if (d.toDateString() === today()) return clock(at);
  const yesterday = new Date();
  yesterday.setDate(yesterday.getDate() - 1);
  if (d.toDateString() === yesterday.toDateString()) return `Dün ${clock(at)}`;
  return `${dayFormat.format(d)} ${clock(at)}`;
}
const iso = (at: number) => new Date(at * 1000).toISOString();
</script>

<template>
  <div class="system-tab">
    <section class="card audit" aria-labelledby="gunluk-baslik" data-testid="audit">
      <div class="card-head">
        <h2 id="gunluk-baslik" class="card-title">İşlem günlüğü</h2>
        <div class="card-actions">
          <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="audit-refresh" @click="load"><Icon name="refresh" :size="16" />Yenile</button>
        </div>
      </div>
      <p class="meter-note">
        Konsol'dan yapılan son işlemler (son 7 gün). Uygulamaların kendi günlükleri uygulama sayfasının Günlük sekmesinde, denetim ve onarımınki Sağlık'tadır.
        <template v-if="readAt"> Son okuma {{ clock(readAt) }}.</template>
      </p>
      <p v-if="error" class="form-error" role="alert" data-testid="audit-error">{{ error }}</p>
      <template v-if="rows">
        <div class="toolbar">
          <div class="search-box">
            <label for="gunluk-ara" class="sr-only">Günlükte ara</label>
            <Icon name="search" :size="18" class="search-icon" />
            <input id="gunluk-ara" v-model="query" class="input" type="search" placeholder="Günlükte ara" autocomplete="off" spellcheck="false" data-testid="audit-search" />
          </div>
          <div class="filters" role="group" aria-label="Türe göre süz">
            <button type="button" class="filter-chip" :aria-pressed="kind === ''" data-tur="" @click="kind = ''">Tümü <span class="filter-count">{{ entries.length }}</span></button>
            <button v-for="k in kinds" :key="k.id" type="button" class="filter-chip" :aria-pressed="kind === k.id" :data-tur="k.id" @click="kind = k.id">
              {{ k.label }} <span class="filter-count">{{ k.count }}</span>
            </button>
          </div>
        </div>
        <p class="sr-only" role="status">{{ `${shown.length} kayıt gösteriliyor` }}</p>
        <div v-if="shown.length" class="table-wrap">
          <table class="data-table audit-table">
            <thead>
              <tr>
                <th scope="col">Olay</th>
                <th scope="col">Zaman</th>
                <th scope="col">Tür</th>
                <th scope="col">Kim</th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="x in shown" :key="x.key" :class="{ 'audit-failed': !x.e.ok }" :data-eylem="x.e.action" :data-tur="x.kind">
                <th scope="row" class="col-main">
                  <strong class="audit-line" data-testid="audit-line">{{ x.line }}</strong>
                </th>
                <td data-label="Zaman"><time :datetime="iso(x.e.at)">{{ when(x.e.at) }}</time></td>
                <td data-label="Tür">{{ x.label }}</td>
                <td data-label="Kim"><span class="cell-stack"><span>{{ x.e.user }}</span><span class="mono cell-note">{{ x.e.client }}</span></span></td>
              </tr>
            </tbody>
          </table>
        </div>
        <EmptyState v-else-if="entries.length" title="Eşleşen kayıt yok" text="Süzgeci ya da aramayı değiştirin." icon="search">
          <button type="button" class="btn btn-secondary" @click="(kind = ''), (query = '')">Süzgeci temizle</button>
        </EmptyState>
        <EmptyState v-else title="Kayıt yok" text="Konsol'dan yapılan değişiklikler burada görünür." icon="lines" />
      </template>
      <EmptyState v-else-if="!error" title="Günlük okunuyor" icon="lines" />
    </section>
  </div>
</template>
