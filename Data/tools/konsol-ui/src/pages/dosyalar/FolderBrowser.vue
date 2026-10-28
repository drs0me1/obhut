<!-- The folder browser of Dosyalar (phase 4b, DD-267) for both trees: the user area ("srv": /api/*, the
     owner account) and, on the tailnet only, the whole server as root ("sistem": /api/sistem/*, DD-235).
     The folder is in the address (yol=, relative to the root; opening one is a history entry, so Back goes
     to the previous folder), as are the filter (ara=) and the file open in the editor (dosya=). Folders come
     first, in Turkish order, with their item count and size (DD-247) and the time they changed. Ticked items
     are downloaded (files), moved, put in the trash (srv) or deleted for good (sistem, the typed word). Each
     row has its own actions; a text file opens in the editor (EditorSheet). Uploads come from the picker or
     a drop on the browser, one at a time (uploads.ts). A shared folder carries its mark and "Paylaşımı
     yönet", another eligible folder "Paylaş" (both lead to Paylaşımlar). A folder that cannot be opened
     leaves the browser where it was, with the reason. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, onMounted, reactive, ref, watch } from "vue";
import { RouterLink, useRoute, useRouter, type LocationQueryRaw } from "vue-router";
import { Icon } from "../../components/icons";
import EmptyState from "../../components/ui/EmptyState.vue";
import { ApiError } from "../../api/http";
import { downloadUrl, readListing, readShares, readState, type Entry, type FilesState, type Listing, type Tree } from "../../api/dosyalar";
import type { Paylasim } from "../../api/sema";
import { useLeaveGuard } from "../../leave";
import { useQueryParam } from "../../query";
import { bytes, fold } from "../../format";
import { filesRoute } from "../../sections";
import {
  TYPE_TEXT,
  canEdit,
  countText,
  errorText,
  fullPath,
  isTextName,
  isoTime,
  joinPath,
  shareMark,
  shareable,
  sizeText,
  sortEntries,
  splitPath,
  when,
} from "./files";
import { onUploaded, queueFiles, uploads } from "./uploads";
import EditorSheet from "./EditorSheet.vue";
import MoveDialog from "./MoveDialog.vue";
import NameDialog from "./NameDialog.vue";
import RemoveDialog from "./RemoveDialog.vue";
import UploadQueue from "./UploadQueue.vue";

const props = defineProps<{ tree: Tree }>();
const route = useRoute();
const router = useRouter();
const system = computed(() => props.tree === "sistem");

// ---- the tree: its root, disk and text limit
const state = ref<FilesState | null>(null);
const stateError = ref<{ status: number; text: string } | null>(null);

async function loadState(): Promise<void> {
  try {
    state.value = await readState(props.tree);
    stateError.value = null;
  } catch (err) {
    stateError.value = { status: err instanceof ApiError ? err.status : 0, text: errorText(err) };
  }
}

/** The root view answers only on the tailnet, from another Tailscale device (DD-235). */
const refused = computed(() => system.value && !state.value && stateError.value !== null && [403, 404].includes(stateError.value.status));
const refusedText = computed(() => {
  const reason = stateError.value?.text.replace(/\.$/, "");
  return `${reason ? reason + ". " : ""}Bu görünüm sunucunun bütün dosyalarını root olarak açar; yalnız başka bir Tailscale cihazından, Konsol'un tailnet adresiyle kullanılır.`;
});
const root = computed(() => state.value?.root ?? (system.value ? "/" : "/srv"));

// ---- the folder shares (srv): the marks and the links to Paylaşımlar; unknown when they cannot be read
const shares = ref<Paylasim[] | null>(null);
async function loadShares(): Promise<void> {
  if (system.value) return;
  try {
    shares.value = await readShares();
  } catch {
    shares.value = null;
  }
}
const shareByPath = computed(() => new Map((shares.value ?? []).map((s) => [s.path, s])));

// ---- the folder in the address
const pathParam = useQueryParam<string>("yol", null, "");
const here = computed(() => (splitPath(pathParam.value) ?? []).join("/"));
const crumbs = computed(() => (here.value ? here.value.split("/") : []));

const listing = ref<Listing | null>(null);
const loading = ref(false);
const listError = ref("");
const heading = ref<HTMLElement | null>(null);
let seq = 0;
let keepError = false;

/** The query for another folder: the filter and the open file belong to the folder they were set in. */
function queryFor(rel: string): LocationQueryRaw {
  const query: LocationQueryRaw = { ...route.query };
  delete query.ara;
  delete query.dosya;
  if (rel) query.yol = rel;
  else delete query.yol;
  return query;
}

function go(rel: string): void {
  listError.value = "";
  failure.value = "";
  if (rel === here.value) {
    void loadList();
    return;
  }
  void router.push({ query: queryFor(rel) });
}

async function loadList(): Promise<void> {
  const mine = ++seq;
  const at = here.value;
  if (!keepError) listError.value = "";
  keepError = false;
  loading.value = true;
  try {
    const list = await readListing(props.tree, at);
    if (mine !== seq) return;
    listing.value = list;
  } catch (err) {
    if (mine !== seq) return;
    if (!at) {
      listError.value = errorText(err);
      return;
    }
    // Stay where the browser was (or go one up when the shown folder itself went away).
    listError.value = `“${fullPath(root.value, at)}” açılamadı: ${errorText(err)}`;
    keepError = true;
    const shown = listing.value?.path;
    const back = shown !== undefined && shown !== at ? shown : at.split("/").slice(0, -1).join("/");
    void router.replace({ query: queryFor(back) });
  } finally {
    if (mine === seq) loading.value = false;
  }
}

watch(here, async () => {
  selected.clear();
  naming.open = moving.open = removing.open = false;
  void loadList();
  await nextTick();
  const el = heading.value;
  if (!el) return;
  if (el.getBoundingClientRect().top < 0) el.scrollIntoView({ block: "start" });
  el.focus({ preventScroll: true });
});

/** A refresh after a change: the folder, the disk and the trash's count. */
function refresh(): void {
  void loadList();
  void loadState();
}

/** "Yenile": everything the browser shows, the share marks too. */
function reload(): void {
  listError.value = "";
  failure.value = "";
  refresh();
  void loadShares();
}

// ---- the filter (ara=), Turkish case rules
const filterParam = useQueryParam<string>("ara", null, "");
const filter = ref(filterParam.value);
watch(filterParam, (value) => {
  if (value !== filter.value) filter.value = value;
});
watch(filter, (value) => (filterParam.value = value));

interface Row {
  e: Entry;
  rel: string;
  share: Paylasim | null;
  canShare: boolean;
  /** A click on the name opens the editor. */
  text: boolean;
  edit: boolean;
}

const textLimit = computed(() => state.value?.textLimit ?? 0);
const allRows = computed<Row[]>(() => {
  const l = listing.value;
  if (!l) return [];
  return sortEntries(l.entries).map((e) => {
    const rel = joinPath(l.path, e.name);
    const share = !system.value && e.type === "dir" ? shareByPath.value.get(rel) ?? null : null;
    return {
      e,
      rel,
      share,
      canShare: !system.value && e.type === "dir" && shares.value !== null && !share && shareable(rel),
      text: e.type === "file" && isTextName(e.name),
      edit: canEdit(e, textLimit.value),
    };
  });
});
const rows = computed(() => {
  const q = fold(filter.value.trim());
  return q ? allRows.value.filter((r) => fold(r.e.name).includes(q)) : allRows.value;
});
const switching = computed(() => loading.value && listing.value !== null && listing.value.path !== here.value);
const total = computed(() => (listing.value?.entries ?? []).reduce((sum, e) => sum + (e.size ?? 0), 0));
const title = computed(() => crumbs.value.at(-1) ?? root.value);

// ---- selection: only what is shown
const selected = reactive(new Set<string>());
const chosen = computed(() => rows.value.filter((r) => selected.has(r.e.name)));
const chosenSize = computed(() => chosen.value.reduce((sum, r) => sum + (r.e.size ?? 0), 0));
const allChosen = computed(() => rows.value.length > 0 && rows.value.every((r) => selected.has(r.e.name)));
const someChosen = computed(() => chosen.value.length > 0 && !allChosen.value);
watch(rows, (list) => {
  const names = new Set(list.map((r) => r.e.name));
  for (const name of [...selected]) if (!names.has(name)) selected.delete(name);
});

function toggle(name: string): void {
  if (selected.has(name)) selected.delete(name);
  else selected.add(name);
}
function toggleAll(): void {
  if (allChosen.value) selected.clear();
  else for (const r of rows.value) selected.add(r.e.name);
}

// ---- results
const note = ref("");
const failure = ref("");
function done(message: string): void {
  naming.open = moving.open = removing.open = false;
  failure.value = "";
  note.value = message;
  selected.clear();
  refresh();
}

// ---- dialogs (their content stays while they close)
const naming = reactive({ open: false, item: null as Entry | null });
const moving = reactive({ open: false, items: [] as Entry[] });
const removing = reactive({ open: false, items: [] as Entry[] });
const writeBlock = computed(() => {
  if (!here.value && state.value && !state.value.writable) return "Bu klasöre yazma izni yok.";
  return "";
});

function newFolder(): void {
  Object.assign(naming, { open: true, item: null });
}
function rename(e: Entry): void {
  Object.assign(naming, { open: true, item: e });
}
function move(items: Entry[]): void {
  Object.assign(moving, { open: true, items });
}
function remove(items: Entry[]): void {
  Object.assign(removing, { open: true, items });
}

// ---- the editor (dosya=)
const fileParam = useQueryParam<string>("dosya", null, "");
function openEditor(name: string): void {
  fileParam.value = name;
}
function onSaved(): void {
  void loadList();
}

// ---- downloads: a plain link each (the browser saves it)
function downloadAll(list: Row[]): void {
  for (const r of list) {
    if (r.e.type !== "file") continue;
    const a = document.createElement("a");
    a.href = downloadUrl(props.tree, r.rel);
    a.download = r.e.name;
    document.body.append(a);
    a.click();
    a.remove();
  }
}

// ---- uploads: the picker and a drop on the browser
const picker = ref<HTMLInputElement | null>(null);
const dragDepth = ref(0);

function addFiles(files: File[], skipped: { name: string; reason: string }[] = []): void {
  if (!files.length && !skipped.length) return;
  if (writeBlock.value) {
    failure.value = writeBlock.value;
    return;
  }
  const l = listing.value;
  const taken = l && l.path === here.value ? l.entries.map((e) => e.name) : [];
  const skips = queueFiles(props.tree, here.value, files, taken, skipped);
  const queued = files.length + skipped.length - skips;
  failure.value = "";
  note.value = [queued ? `${queued} dosya yükleme sırasına alındı.` : "", skips ? `${skips} öge atlandı; nedeni Yüklemeler'de.` : ""].filter(Boolean).join(" ");
}

function onPicked(event: Event): void {
  const input = event.target as HTMLInputElement;
  addFiles(Array.from(input.files ?? []));
  input.value = "";
}

const hasFiles = (e: DragEvent) => Array.from(e.dataTransfer?.types ?? []).includes("Files");
function onDragEnter(e: DragEvent): void {
  if (!hasFiles(e)) return;
  e.preventDefault();
  dragDepth.value += 1;
}
function onDragOver(e: DragEvent): void {
  if (!hasFiles(e)) return;
  e.preventDefault();
  if (e.dataTransfer) e.dataTransfer.dropEffect = writeBlock.value ? "none" : "copy";
}
function onDragLeave(e: DragEvent): void {
  if (hasFiles(e)) dragDepth.value = Math.max(0, dragDepth.value - 1);
}
function onDrop(e: DragEvent): void {
  if (!hasFiles(e) || !e.dataTransfer) return;
  e.preventDefault();
  dragDepth.value = 0;
  const files: File[] = [];
  const skipped: { name: string; reason: string }[] = [];
  const items = Array.from(e.dataTransfer.items ?? []).filter((i) => i.kind === "file");
  if (items.length) {
    for (const item of items) {
      const entry = item.webkitGetAsEntry?.();
      const file = item.getAsFile();
      if (entry?.isDirectory) skipped.push({ name: entry.name, reason: "klasör yüklenmez; içindeki dosyaları seçin" });
      else if (file) files.push(file);
    }
  } else files.push(...Array.from(e.dataTransfer.files));
  addFiles(files, skipped);
}
// A file dropped beside the browser must not open in this browser tab.
const holdDrop = (e: DragEvent) => {
  if (hasFiles(e)) e.preventDefault();
};

useLeaveGuard(() => uploads.items.some((u) => u.tree === props.tree && (u.state === "sirada" || u.state === "yukleniyor")));

let stopUploads: (() => void) | null = null;
onMounted(async () => {
  document.addEventListener("dragover", holdDrop);
  document.addEventListener("drop", holdDrop);
  stopUploads = onUploaded((u) => {
    if (u.tree !== props.tree) return;
    note.value = `“${u.name}” yüklendi.`;
    if (u.folder === here.value) void loadList();
  });
  void loadShares();
  if (system.value) {
    await loadState();
    if (!refused.value) void loadList();
  } else {
    void loadState();
    void loadList();
  }
});
onBeforeUnmount(() => {
  document.removeEventListener("dragover", holdDrop);
  document.removeEventListener("drop", holdDrop);
  stopUploads?.();
});
</script>

<template>
  <section v-if="refused" class="card" aria-label="Sistem dosyaları" data-testid="system-refused">
    <EmptyState title="Sistem dosyaları yalnız Tailscale'den açılır" :text="refusedText" icon="lock" />
  </section>
  <section
    v-else
    class="card files-browser"
    :class="{ 'files-dropping': dragDepth > 0 }"
    :aria-label="system ? 'Sistem dosyaları' : 'Sunucu klasörleri'"
    :data-agac="tree"
    data-testid="browser"
    @dragenter="onDragEnter"
    @dragover="onDragOver"
    @dragleave="onDragLeave"
    @drop="onDrop"
  >
    <p v-if="system" class="notice notice-warning" data-testid="root-warning">
      <Icon name="alert" class="notice-icon" />
      <span><strong>Root olarak çalışır.</strong> Sunucunun bütün dosyaları burada değiştirilebilir ve silinebilir; çöp kutusu yoktur, silinen geri gelmez.</span>
    </p>

    <nav v-if="crumbs.length" class="files-crumbs" aria-label="Konum" data-testid="crumbs">
      <ol>
        <li><button type="button" class="files-crumb" @click="go('')">{{ root }}</button></li>
        <li v-for="(part, i) in crumbs" :key="i">
          <button v-if="i < crumbs.length - 1" type="button" class="files-crumb" @click="go(crumbs.slice(0, i + 1).join('/'))">{{ part }}</button>
          <span v-else class="files-crumb files-crumb-here" aria-current="location">{{ part }}</span>
        </li>
      </ol>
    </nav>

    <div class="files-heading">
      <div class="files-heading-text">
        <h2 ref="heading" class="card-title files-title wrap" tabindex="-1" data-testid="folder-title">{{ title }}</h2>
        <p v-if="listing && !switching" class="meter-note" data-testid="folder-summary">
          {{ filter.trim() ? `${rows.length} / ${listing.entries.length} öge gösteriliyor` : `${listing.entries.length} öge` }} · {{ bytes(total) }}
        </p>
      </div>
      <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="refresh" @click="reload"><Icon name="refresh" :size="16" />Yenile</button>
    </div>

    <div class="toolbar files-tools">
      <div class="search-box">
        <label :for="`suz-${tree}`" class="sr-only">Bu klasörde süz</label>
        <Icon name="search" :size="18" class="search-icon" />
        <input :id="`suz-${tree}`" v-model="filter" class="input" type="search" placeholder="Bu klasörde süz" autocomplete="off" spellcheck="false" data-testid="filter" @keydown.esc="filter = ''" />
      </div>
      <div class="files-tool-actions">
        <input ref="picker" class="sr-only" type="file" multiple tabindex="-1" aria-hidden="true" data-testid="upload-input" @change="onPicked" />
        <button type="button" class="btn btn-primary btn-sm" :disabled="Boolean(writeBlock)" :title="writeBlock || undefined" data-testid="upload" @click="picker?.click()">
          <Icon name="upload" :size="16" />Yükle
        </button>
        <button type="button" class="btn btn-secondary btn-sm" :disabled="Boolean(writeBlock)" :title="writeBlock || undefined" data-testid="new-folder" @click="newFolder">
          <Icon name="plus" :size="16" />Yeni klasör
        </button>
      </div>
    </div>

    <p class="sr-only" role="status">{{ note }}</p>
    <p v-if="note" class="notice notice-ok" aria-hidden="true" data-testid="note"><Icon name="check" class="notice-icon" /><span>{{ note }}</span></p>
    <p v-if="!state && stateError" class="notice notice-warning" data-testid="state-error">
      <Icon name="alert" class="notice-icon" /><span>Klasör bilgileri okunamadı: {{ stateError.text }}</span>
    </p>
    <p v-if="failure || listError" class="notice notice-danger" role="alert" data-testid="failure">
      <Icon name="xcircle" class="notice-icon" /><span>{{ failure || listError }}</span>
    </p>

    <UploadQueue :tree="tree" :root="root" />

    <div v-if="chosen.length" class="files-selection" role="group" aria-label="Seçilenler" data-testid="selection">
      <p class="files-selection-text"><strong>{{ chosen.length }} öge seçili</strong> · {{ bytes(chosenSize) }}</p>
      <div class="files-selection-actions">
        <button type="button" class="btn btn-secondary btn-sm" :disabled="!chosen.some((r) => r.e.type === 'file')" data-testid="sel-download" @click="downloadAll(chosen)">
          <Icon name="download" :size="16" />İndir
        </button>
        <button type="button" class="btn btn-secondary btn-sm" data-testid="sel-move" @click="move(chosen.map((r) => r.e))"><Icon name="move" :size="16" />Taşı</button>
        <button type="button" class="btn btn-danger-quiet btn-sm" data-testid="sel-remove" @click="remove(chosen.map((r) => r.e))">
          <Icon name="trash" :size="16" />{{ system ? "Kalıcı sil" : "Çöpe at" }}
        </button>
        <button type="button" class="btn btn-secondary btn-sm" data-testid="sel-clear" @click="selected.clear()"><Icon name="close" :size="16" />Seçimi bırak</button>
      </div>
    </div>

    <div class="files-list" :class="{ 'files-switching': switching }" :inert="switching || undefined" :aria-busy="loading || undefined" data-testid="list">
      <template v-if="listing">
        <label v-if="rows.length" class="check-row files-all">
          <input type="checkbox" :checked="allChosen" :indeterminate="someChosen" data-testid="select-all" @change="toggleAll" />
          <span>Tümünü seç</span>
        </label>
        <div v-if="rows.length" class="files-table-wrap">
          <table class="files-table">
            <thead>
              <tr>
                <th scope="col" class="files-check"><span class="sr-only">Seçim</span></th>
                <th scope="col">Ad</th>
                <th scope="col" class="files-size">Boyut</th>
                <th scope="col" class="files-date">Değiştirilme</th>
                <th scope="col" class="files-acts"><span class="sr-only">Eylemler</span></th>
              </tr>
            </thead>
            <tbody>
              <tr v-for="r in rows" :key="r.e.name" :data-oge="r.e.name" :data-tur="r.e.type" :class="{ 'files-row-on': selected.has(r.e.name) }">
                <td class="files-check">
                  <label class="files-pick">
                    <input type="checkbox" :checked="selected.has(r.e.name)" :aria-label="`Seç: ${r.e.name}`" @change="toggle(r.e.name)" />
                  </label>
                </td>
                <th scope="row" class="files-name">
                  <span class="files-item">
                    <span class="files-icon" :class="'files-icon-' + r.e.type" aria-hidden="true"><Icon :name="r.e.type === 'dir' ? 'folder' : 'file'" :size="20" /></span>
                    <span class="files-item-text">
                      <button v-if="r.e.type === 'dir'" type="button" class="files-open" data-eylem="ac" @click="go(r.rel)">{{ r.e.name }}</button>
                      <button v-else-if="r.text" type="button" class="files-open" data-eylem="ac" @click="openEditor(r.e.name)">{{ r.e.name }}</button>
                      <a v-else-if="r.e.type === 'file'" class="files-open" :href="downloadUrl(tree, r.rel)" download data-eylem="ac">{{ r.e.name }}</a>
                      <span v-else class="files-open files-open-plain">{{ r.e.name }}</span>
                      <span class="files-marks">
                        <span v-if="r.e.type === 'dir'" class="cell-note">{{ countText(r.e.count) }}</span>
                        <span v-else-if="r.e.type !== 'file'" class="cell-note">{{ TYPE_TEXT[r.e.type] }}</span>
                        <span v-if="r.share" class="files-mark" :class="{ 'files-mark-on': shareMark(r.share).on }" data-isaret="paylasim">
                          <Icon name="share" :size="14" />{{ shareMark(r.share).text }}
                        </span>
                      </span>
                    </span>
                  </span>
                </th>
                <td class="files-size" data-label="Boyut">{{ sizeText(r.e) }}</td>
                <td class="files-date" data-label="Değiştirilme"><time :datetime="isoTime(r.e.mtime)">{{ when(r.e.mtime) }}</time></td>
                <td class="files-acts">
                  <span class="files-row-actions">
                    <RouterLink v-if="r.share" :to="filesRoute('paylasimlar', { paylasim: r.share.id })" class="icon-btn" :aria-label="`Paylaşımı yönet: ${r.e.name}`"
                      title="Paylaşımı yönet" data-eylem="paylasim-yonet"><Icon name="sliders" :size="18" /></RouterLink>
                    <RouterLink v-else-if="r.canShare" :to="filesRoute('paylasimlar', { yeni: r.rel })" class="icon-btn" :aria-label="`Paylaş: ${r.e.name}`" title="Paylaş"
                      data-eylem="paylas"><Icon name="share" :size="18" /></RouterLink>
                    <a v-if="r.e.type === 'file'" class="icon-btn" :href="downloadUrl(tree, r.rel)" download :aria-label="`İndir: ${r.e.name}`" title="İndir" data-eylem="indir">
                      <Icon name="download" :size="18" />
                    </a>
                    <button v-if="r.edit" type="button" class="icon-btn" :aria-label="`Düzenle: ${r.e.name}`" title="Düzenle" data-eylem="duzenle" @click="openEditor(r.e.name)">
                      <Icon name="pencil" :size="18" />
                    </button>
                    <button type="button" class="icon-btn" :aria-label="`Yeniden adlandır: ${r.e.name}`" title="Yeniden adlandır" data-eylem="adlandir" @click="rename(r.e)">
                      <Icon name="rename" :size="18" />
                    </button>
                    <button type="button" class="icon-btn" :aria-label="`Taşı: ${r.e.name}`" title="Taşı" data-eylem="tasi" @click="move([r.e])"><Icon name="move" :size="18" /></button>
                    <button type="button" class="icon-btn icon-btn-danger" :aria-label="`${system ? 'Kalıcı sil' : 'Çöpe at'}: ${r.e.name}`" :title="system ? 'Kalıcı sil' : 'Çöpe at'"
                      :data-eylem="system ? 'sil' : 'cop'" @click="remove([r.e])"><Icon name="trash" :size="18" /></button>
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <EmptyState v-else-if="filter.trim()" title="Eşleşen öge yok" text="Süzgeci değiştirin ya da temizleyin." icon="search">
          <button type="button" class="btn btn-secondary" @click="filter = ''">Süzgeci temizle</button>
        </EmptyState>
        <EmptyState v-else title="Bu klasör boş" :text="writeBlock ? '' : 'Dosyaları buraya sürükleyin ya da Yükle ile seçin.'" icon="folder" />
        <p v-if="listing.skipped" class="meter-note">{{ listing.skipped }} öge gösterilmedi (adı geçersiz).</p>
      </template>
      <p v-else-if="loading" class="meter-note" role="status">Klasör okunuyor…</p>
      <EmptyState v-else-if="listError" title="Klasör okunamadı" icon="folder">
        <button type="button" class="btn btn-secondary" data-testid="retry" @click="go(here)">Yeniden dene</button>
      </EmptyState>
    </div>

    <div v-if="dragDepth > 0" class="files-drop" aria-hidden="true" data-testid="drop">
      <Icon name="upload" :size="22" />
      <span>{{ writeBlock || `Bırakın — ${fullPath(root, here)} içine yüklenir` }}</span>
    </div>

    <NameDialog :open="naming.open" :tree="tree" :root="root" :folder="here" :item="naming.item" @close="naming.open = false" @done="done" />
    <MoveDialog :open="moving.open" :tree="tree" :root="root" :folder="here" :items="moving.items" @close="moving.open = false" @done="done" />
    <RemoveDialog :open="removing.open" :tree="tree" :root="root" :folder="here" :items="removing.items" @close="removing.open = false" @done="done" />
    <EditorSheet :tree="tree" :root="root" :folder="here" :name="fileParam || null" @close="fileParam = ''" @saved="onSaved" />
  </section>
</template>
