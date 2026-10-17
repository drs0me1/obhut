<!-- Dosyalar → Depolama (phase 4b, DD-267; K7): the disk the user area is on (GET /api/state: size, free, what the
     user area itself holds without the trash, whether it is its own mount, the trash in short); "Uygulama verileri"
     (GET /api/konsol/depolama: each application's own folder, A5, with its folders' sizes from a bounded, cached
     walk, when it was measured, which service mounts each folder where, and "Yeniden ölç" past the cache); and the
     user area's top folders (GET /api/list) with their size, item count and who uses them: applications whose
     services bind the folder or a folder inside it ("<service>: <target>"; a bind of the whole user area counts for
     every folder) and folder shares. Each user links to its application's page or to Paylaşımlar; each folder
     opens in Sunucu klasörleri, an application's folder in Sistem dosyaları (on the tailnet). -->
<script setup lang="ts">
import { computed, onMounted, ref } from "vue";
import { RouterLink, type RouteLocationRaw } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import UsageBar from "../../components/ui/UsageBar.vue";
import { readListing, readState, readStorage, type FilesState, type Listing } from "../../api/dosyalar";
import type { Depolama } from "../../api/sema";
import { appRoute } from "../../router";
import { filesRoute } from "../../sections";
import { UNKNOWN, bytes, dateTime, percent, since } from "../../format";
import { serverNow } from "../../live";
import { countText, errorText, sizeText, sortEntries } from "./files";

const state = ref<FilesState | null>(null);
const listing = ref<Listing | null>(null);
const storage = ref<Depolama | null>(null);
const errors = ref<{ state: string; list: string; storage: string }>({ state: "", list: "", storage: "" });
const loading = ref(false);
const measuring = ref(false);

/** Measures the applications' folders again (past the server's cache); the rest stays as read. */
async function measure(): Promise<void> {
  measuring.value = true;
  try {
    storage.value = await readStorage(true);
    errors.value.storage = "";
  } catch (err) {
    errors.value.storage = errorText(err);
  } finally {
    measuring.value = false;
  }
}

async function load(): Promise<void> {
  loading.value = true;
  const take = async <T,>(read: () => Promise<T>, key: keyof typeof errors.value): Promise<T | null> => {
    try {
      const value = await read();
      errors.value[key] = "";
      return value;
    } catch (err) {
      errors.value[key] = errorText(err);
      return null;
    }
  };
  const [s, l, d] = await Promise.all([take(() => readState("srv"), "state"), take(() => readListing("srv", ""), "list"), take(() => readStorage(), "storage")]);
  if (s) state.value = s;
  if (l) listing.value = l;
  if (d) storage.value = d;
  loading.value = false;
}
onMounted(() => void load());

const root = computed(() => state.value?.root ?? storage.value?.kok ?? "/srv");
const disk = computed(() => state.value?.disk ?? null);
const filled = computed(() => {
  const d = disk.value;
  return d && d.total !== null && d.free !== null && d.total > 0 ? d.total - d.free : null;
});
const filledPct = computed(() => (filled.value !== null && disk.value?.total ? (100 * filled.value) / disk.value.total : null));

interface Use {
  key: string;
  name: string;
  detail: string;
  to: RouteLocationRaw;
  kind: "uygulama" | "paylasim";
}

const SHARE_ID = /^\/s\/([^/]+)\/$/;
const access = (rw: boolean) => (rw ? "okuma-yazma" : "salt okunur");

/** A path of the depolama read relative to the user area: "" for the whole area, null when outside it. */
function relOf(yol: string): string | null {
  const kok = storage.value?.kok ?? root.value;
  if (yol === kok) return "";
  return yol.startsWith(kok + "/") ? yol.slice(kok.length + 1) : null;
}

const users = computed(() => {
  const out: { rel: string; use: Use }[] = [];
  for (const [i, u] of (storage.value?.kullananlar ?? []).entries()) {
    const rel = relOf(u.yol);
    if (rel === null) continue;
    const where = rel ? rel : "tüm kullanıcı alanı";
    if (u.tur === "paylasim") {
      const id = SHARE_ID.exec(u.hedef)?.[1];
      out.push({ rel, use: { key: `p${i}`, name: u.ad, kind: "paylasim", detail: `klasör paylaşımı · ${where} · ${access(u.yazilabilir)}`,
        to: filesRoute("paylasimlar", id ? { paylasim: id } : {}) } });
    } else {
      out.push({ rel, use: { key: `u${i}`, name: u.ad, kind: u.tur, detail: `${where} · ${access(u.yazilabilir)}${u.hedef ? ` · ${u.hedef}` : ""}`, to: appRoute(u.id) } });
    }
  }
  return out;
});
// A bind of the whole user area is named once with its details; each folder lists it in short.
const whole = computed(() => users.value.filter((u) => u.rel === "").map((u) => u.use));
const wholeNote = (u: Use) => u.detail.replace(/^tüm kullanıcı alanı · /, "");
const wholeShort = computed(() => whole.value.map((u) => ({ ...u, detail: "tüm kullanıcı alanı" })));

const folders = computed(() => {
  const dirs = sortEntries((listing.value?.entries ?? []).filter((e) => e.type === "dir"));
  return dirs.map((d) => ({
    d,
    uses: [...users.value.filter((u) => u.rel === d.name || u.rel.startsWith(d.name + "/")).map((u) => u.use), ...wholeShort.value],
  }));
});
const files = computed(() => (listing.value?.entries ?? []).filter((e) => e.type !== "dir").length);

// ---- Uygulama verileri: each application's own folder (A5) and its folders, the largest first
const appData = computed(() =>
  (storage.value?.uygulamalar ?? []).map((a) => ({
    a,
    folders: [...a.klasorler].sort((x, y) => (y.boyut ?? -1) - (x.boyut ?? -1) || x.ad.localeCompare(y.ad, "tr")),
  })),
);
/** The oldest measurement shown (each application's folder is measured on its own). */
const measuredAt = computed(() => {
  const times = (storage.value?.uygulamalar ?? []).map((a) => a.olculdu).filter((t): t is number => t !== null);
  return times.length ? Math.min(...times) : null;
});
// Sistem dosyaları (the whole server as root) answers only on the tailnet (DD-235).
const tailnet = location.protocol === "http:";
const systemPath = (path: string) => filesRoute("sistem", { yol: path.replace(/^\/+/, "") });
const targets = (hedefler: string[]) => (hedefler.length ? hedefler.join(", ") : "tanımda yok");
const elsewhere = computed(() => {
  const names = new Set(folders.value.map((f) => f.d.name));
  return listing.value ? users.value.filter((u) => u.rel !== "" && !names.has(u.rel.split("/")[0] ?? "")) : [];
});
</script>

<template>
  <div class="files-tab files-storage" data-testid="depolama">
    <div class="files-storage-top">
      <Card title="Disk" data-testid="disk">
        <template #actions>
          <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="storage-refresh" @click="load"><Icon name="refresh" :size="16" />Yenile</button>
        </template>
        <p v-if="errors.state" class="form-error" role="alert" data-testid="state-error">{{ errors.state }}</p>
        <template v-if="disk">
          <div class="meter-row">
            <div class="meter-line"><span>Dolu</span><strong data-testid="disk-used">{{ bytes(filled) }} / {{ bytes(disk.total) }}</strong></div>
            <UsageBar :value="filledPct" />
            <p class="meter-note" data-testid="disk-free">{{ bytes(disk.free) }} boş<template v-if="filledPct !== null"> · {{ percent(filledPct) }} dolu</template></p>
          </div>
          <dl class="facts">
            <dt>Kullanıcı alanı</dt>
            <dd data-testid="area"><span class="mono">{{ root }}</span> · {{ disk.used === null ? "boyutu hesaplanamadı (çok fazla öge)" : `${bytes(disk.used)} (çöp hariç)` }}</dd>
            <dt>Bağlama</dt>
            <dd data-testid="mount">{{ disk.mount ? "Kendi diskinde (ayrı bir bağlama noktası)" : "Sistem diskinde; boş alan sistemle ortak" }}</dd>
            <dt>Çöp kutusu</dt>
            <dd data-testid="trash-card">
              <span data-testid="trash-count">{{ state?.trash ? `${state.trash.count} öge · ${bytes(state.trash.size)}` : UNKNOWN }}</span>
              · <RouterLink :to="filesRoute('cop')" data-testid="trash-link">Çöp kutusunu aç</RouterLink>
            </dd>
          </dl>
          <p class="meter-note">Silinenler geri yüklenene ya da kalıcı silinene kadar disk alanı kaplar.</p>
        </template>
        <p v-else-if="loading" class="meter-note" role="status">Okunuyor…</p>
      </Card>

      <section class="card files-appdata" aria-labelledby="uygulama-verileri-baslik" data-testid="app-data">
        <div class="card-head">
          <h2 id="uygulama-verileri-baslik" class="card-title">Uygulama verileri</h2>
          <div class="card-actions">
            <button type="button" class="btn btn-secondary btn-sm" :disabled="measuring || !storage" data-testid="app-data-measure" @click="measure">
              <Icon name="refresh" :size="16" />{{ measuring ? "Ölçülüyor…" : "Yeniden ölç" }}
            </button>
          </div>
        </div>
        <p class="meter-note">Her uygulamanın kendi klasörü; uygulama kaldırılırken saklanması sorulur.</p>
        <ul v-if="appData.length" class="appdata-list">
          <li v-for="x in appData" :key="x.a.ad" class="appdata" :data-uygulama="x.a.ad">
            <div class="appdata-head">
              <RouterLink :to="appRoute(x.a.ad)" class="files-use-name">{{ x.a.ad }}</RouterLink>
              <strong class="nowrap" data-testid="app-data-size">{{ x.a.boyut === null ? UNKNOWN : bytes(x.a.boyut) }}</strong>
            </div>
            <component :is="tailnet ? RouterLink : 'span'" :to="tailnet ? systemPath(x.a.yol) : undefined" class="mono wrap appdata-path">{{ x.a.yol }}</component>
            <p v-if="x.a.neden" class="cell-note" data-testid="app-data-reason">{{ x.a.neden }}</p>
            <ul v-if="x.folders.length" class="appdata-folders">
              <li v-for="k in x.folders" :key="k.ad" :data-klasor="k.ad">
                <span class="appdata-folder"><span class="mono wrap">{{ k.ad }}</span><span class="nowrap">{{ k.boyut === null ? UNKNOWN : bytes(k.boyut) }}</span></span>
                <span class="cell-note">{{ targets(k.hedefler) }}<template v-if="k.neden && !x.a.neden"> · {{ k.neden }}</template></span>
              </li>
            </ul>
          </li>
        </ul>
        <p v-else-if="storage" class="card-text" data-testid="app-data-empty">Kurulu uygulama yok.</p>
        <p v-else-if="!errors.storage" class="meter-note" role="status">Okunuyor…</p>
        <p v-if="measuredAt" class="meter-note" data-testid="app-data-measured">Ölçüldü {{ dateTime(measuredAt) }} ({{ since(measuredAt, serverNow()) }}).</p>
      </section>
    </div>

    <section class="card files-folders" aria-labelledby="klasorler-baslik" data-testid="folders">
      <h2 id="klasorler-baslik" class="card-title">Klasörler ve kullananlar</h2>
      <p class="meter-note">
        <span class="mono">{{ root }}</span> altındaki klasörler, boyutları ve onları kullanan uygulamalar ve paylaşımlar.
      </p>
      <p v-if="errors.list" class="form-error" role="alert" data-testid="list-error">{{ errors.list }}</p>
      <p v-if="errors.storage" class="notice notice-warning" role="alert" data-testid="storage-error">
        <Icon name="alert" class="notice-icon" /><span>Kullananlar okunamadı: {{ errors.storage }}</span>
      </p>
      <p v-for="(h, i) in storage?.hatalar ?? []" :key="i" class="notice notice-warning" data-testid="storage-warning"><Icon name="alert" class="notice-icon" /><span>{{ h }}</span></p>
      <p v-if="whole.length" class="meter-note" data-testid="whole">
        Bütün kullanıcı alanını kullanan:
        <template v-for="(u, i) in whole" :key="u.key"><template v-if="i">; </template><strong>{{ u.name }}</strong> ({{ wholeNote(u) }})</template>.
      </p>
      <div v-if="folders.length" class="table-wrap">
        <table class="data-table files-folders-table">
          <thead>
            <tr><th scope="col">Klasör</th><th scope="col">Boyut</th><th scope="col">İçerik</th><th scope="col">Kullanan</th></tr>
          </thead>
          <tbody>
            <tr v-for="f in folders" :key="f.d.name" :data-klasor="f.d.name">
              <th scope="row" class="col-main">
                <RouterLink :to="filesRoute('srv', { yol: f.d.name })" class="files-folder-link"><Icon name="folder" :size="18" /><strong class="wrap">{{ f.d.name }}</strong></RouterLink>
              </th>
              <td data-label="Boyut" class="nowrap">{{ sizeText(f.d) }}</td>
              <td data-label="İçerik" class="nowrap">{{ countText(f.d.count) }}</td>
              <td data-label="Kullanan" class="files-uses-cell">
                <ul v-if="f.uses.length" class="files-uses">
                  <li v-for="u in f.uses" :key="u.key" :data-kullanan="u.kind">
                    <RouterLink :to="u.to" class="files-use-name">{{ u.name }}</RouterLink>
                    <span class="cell-note">{{ u.detail }}</span>
                  </li>
                </ul>
                <span v-else-if="errors.storage" class="muted">okunamadı</span>
                <span v-else class="muted">kullanan yok</span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else-if="listing" title="Kullanıcı alanında klasör yok" text="Sunucu klasörlerinden yeni bir klasör oluşturabilirsiniz." icon="folder">
        <RouterLink :to="filesRoute('srv')" class="btn btn-secondary">Sunucu klasörlerini aç</RouterLink>
      </EmptyState>
      <p v-if="files" class="meter-note" data-testid="root-files">Kökte ayrıca {{ files }} dosya var; <RouterLink :to="filesRoute('srv')">Sunucu klasörlerinde</RouterLink> görünür.</p>
      <div v-if="elsewhere.length" class="files-elsewhere" data-testid="elsewhere">
        <p class="meter-note">Listede olmayan klasörleri kullananlar:</p>
        <ul class="files-uses">
          <li v-for="u in elsewhere" :key="u.use.key" :data-kullanan="u.use.kind">
            <RouterLink :to="u.use.to" class="files-use-name">{{ u.use.name }}</RouterLink>
            <span class="cell-note">{{ u.use.detail }}</span>
          </li>
        </ul>
      </div>
    </section>
  </div>
</template>
