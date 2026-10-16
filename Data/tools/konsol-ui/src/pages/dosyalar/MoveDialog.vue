<!-- Moving items to another folder (phase 4b): the dialog browses the tree's folders (GET …/list?dirs=1),
     starting where the items are, and "Buraya taşı" sends POST …/move {path, names, to}. It cannot move into
     the same folder or into one of the moved folders. On the same disk a move is a rename and nothing is
     copied; the server refuses a name the target already holds. -->
<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import Modal from "../../components/ui/Modal.vue";
import { moveItems, readListing, type Entry, type Tree } from "../../api/dosyalar";
import { bytes } from "../../format";
import { compareNames, errorText, fullPath, joinPath } from "./files";

const props = defineProps<{ open: boolean; tree: Tree; root: string; folder: string; items: Entry[] }>();
const emit = defineEmits<{ close: []; done: [message: string] }>();

/** The destination's parts while browsing. */
const dest = ref<string[]>([]);
const dirs = ref<string[] | null>(null);
const readError = ref("");
const error = ref("");
const sending = ref(false);
const body = ref<HTMLElement | null>(null);
let seq = 0;

const destPath = computed(() => dest.value.join("/"));
const moving = computed(() => new Set(props.items.map((i) => joinPath(props.folder, i.name))));
const label = computed(() => (props.items.length === 1 ? `“${props.items[0]?.name}”` : `${props.items.length} öge`));
const size = computed(() => props.items.reduce((sum, i) => sum + (i.size ?? 0), 0));
const same = computed(() => destPath.value === props.folder);
const block = computed(() => {
  if (same.value) return "Seçilenler zaten bu klasörde; hedef klasörün içine girin.";
  if ([...moving.value].some((m) => destPath.value === m || destPath.value.startsWith(m + "/"))) return "Bir klasör kendi içine taşınamaz.";
  return "";
});

async function browse(parts: string[], focus = false): Promise<void> {
  const mine = ++seq;
  dest.value = parts;
  dirs.value = null;
  readError.value = "";
  try {
    const list = await readListing(props.tree, parts.join("/"), true);
    if (mine !== seq) return;
    dirs.value = list.entries.filter((e) => e.type === "dir").map((e) => e.name).sort(compareNames);
  } catch (err) {
    if (mine === seq) readError.value = errorText(err);
  }
  if (focus && mine === seq) {
    await nextTick();
    body.value?.querySelector<HTMLElement>('[data-testid="move-where"]')?.focus();
  }
}

watch(
  () => props.open,
  (open) => {
    seq += 1;
    if (!open) return;
    error.value = "";
    sending.value = false;
    void browse(props.folder ? props.folder.split("/") : []);
  },
);

/** A folder the moved items cannot go into (one of them), or "". */
const rowNote = (name: string): string => (moving.value.has(joinPath(destPath.value, name)) ? "taşınan klasör" : "");

async function submit(): Promise<void> {
  if (sending.value || block.value) return;
  sending.value = true;
  error.value = "";
  const target = destPath.value;
  try {
    await moveItems(props.tree, props.folder, props.items.map((i) => i.name), target);
    emit("done", `${label.value} taşındı → ${fullPath(props.root, target)}`);
  } catch (err) {
    error.value = errorText(err);
  } finally {
    sending.value = false;
  }
}
</script>

<template>
  <Modal :open="open" variant="sheet" :title="`${label} taşı`" :description="`${fullPath(root, folder)} · ${bytes(size)}`" @close="emit('close')">
    <div ref="body" class="files-move" data-testid="move">
      <div class="files-move-here">
        <button v-if="dest.length" type="button" class="icon-btn" aria-label="Bir üst klasör" title="Bir üst klasör" data-testid="move-up" @click="browse(dest.slice(0, -1), true)">
          <Icon name="chevron" :size="18" class="flip" />
        </button>
        <nav class="files-crumbs" aria-label="Hedef klasör">
          <ol>
            <li>
              <button v-if="dest.length" type="button" class="files-crumb" @click="browse([], true)">{{ root }}</button>
              <span v-else class="files-crumb files-crumb-here" aria-current="location" tabindex="-1" data-testid="move-where">{{ root }}</span>
            </li>
            <li v-for="(part, i) in dest" :key="i">
              <button v-if="i < dest.length - 1" type="button" class="files-crumb" @click="browse(dest.slice(0, i + 1), true)">{{ part }}</button>
              <span v-else class="files-crumb files-crumb-here" aria-current="location" tabindex="-1" data-testid="move-where">{{ part }}</span>
            </li>
          </ol>
        </nav>
      </div>
      <p v-if="readError" class="form-error" role="alert" data-testid="move-read-error">{{ readError }}</p>
      <p v-else-if="!dirs" class="meter-note" role="status">Klasörler okunuyor…</p>
      <ul v-else-if="dirs.length" class="files-move-list" :aria-label="`${fullPath(root, destPath)} içindeki klasörler`">
        <li v-for="d in dirs" :key="d" :data-klasor="d">
          <button type="button" class="files-move-dir" :disabled="moving.has(joinPath(destPath, d))" :aria-label="`${d} içine gir`" @click="browse([...dest, d], true)">
            <Icon name="folder" :size="18" /><span class="wrap">{{ d }}</span><span v-if="rowNote(d)" class="cell-note files-move-note">{{ rowNote(d) }}</span>
            <Icon name="chevron" :size="16" class="files-move-chevron" />
          </button>
        </li>
      </ul>
      <p v-else class="meter-note">Bu klasörde alt klasör yok; buraya taşıyabilirsiniz.</p>
      <p class="meter-note">Aynı diskte taşıma anında biter; dosya kopyalanmaz. Hedefte aynı adlı bir öge varsa taşınmaz.</p>
      <p v-if="block && dirs && same" class="meter-note" data-testid="move-block">{{ block }}</p>
      <p v-else-if="block && dirs" class="notice notice-warning" data-testid="move-block"><Icon name="info" class="notice-icon" /><span>{{ block }}</span></p>
      <p v-if="error" class="form-error" role="alert" data-testid="move-error">{{ error }}</p>
    </div>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="sending" @click="emit('close')">Vazgeç</button>
      <button type="button" class="btn btn-primary" :disabled="sending || Boolean(block) || !dirs" data-testid="move-go" @click="submit">
        {{ sending ? "Taşınıyor…" : "Buraya taşı" }}
      </button>
    </template>
  </Modal>
</template>
