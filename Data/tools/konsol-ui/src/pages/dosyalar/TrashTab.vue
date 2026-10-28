<!-- Dosyalar → Çöp kutusu (phase 4b, DD-267): what was moved to the trash from the user area (GET /api/trash),
     newest first, with its name, where it came from, its size and when it was deleted. Ticked items (or one
     row) are restored to where they were (POST /api/trash/restore {ids}; a name taken meanwhile gets a
     number) or deleted for good after the typed word (POST /api/trash/purge {ids}); "Çöpü boşalt" deletes
     everything after the typed word (POST /api/trash/empty {confirm: "onayla"}). A record that is not one
     item any more can only be deleted. -->
<script setup lang="ts">
import { computed, onMounted, reactive, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Modal from "../../components/ui/Modal.vue";
import { emptyTrash, purgeTrash, readState, readTrash, restoreTrash, type TrashItem } from "../../api/dosyalar";
import { bytes } from "../../format";
import { filesRoute } from "../../sections";
import { countText, errorText, fullPath, isoTime, sizeText, when } from "./files";

const items = ref<TrashItem[] | null>(null);
const readError = ref("");
const loading = ref(false);
const root = ref("/srv");

async function load(): Promise<void> {
  loading.value = true;
  try {
    items.value = await readTrash();
    readError.value = "";
  } catch (err) {
    readError.value = errorText(err);
  } finally {
    loading.value = false;
  }
}
onMounted(() => {
  void load();
  readState("srv").then((s) => (root.value = s.root), () => undefined);
});

const total = computed(() => (items.value ?? []).reduce((sum, t) => sum + (t.size ?? 0), 0));

// ---- selection
const selected = reactive(new Set<string>());
const chosen = computed(() => (items.value ?? []).filter((t) => selected.has(t.id)));
const restorable = computed(() => chosen.value.filter((t) => !t.broken));
const allChosen = computed(() => Boolean(items.value?.length) && (items.value ?? []).every((t) => selected.has(t.id)));
const someChosen = computed(() => chosen.value.length > 0 && !allChosen.value);
watch(items, (list) => {
  const ids = new Set((list ?? []).map((t) => t.id));
  for (const id of [...selected]) if (!ids.has(id)) selected.delete(id);
});
function toggle(id: string): void {
  if (selected.has(id)) selected.delete(id);
  else selected.add(id);
}
function toggleAll(): void {
  if (allChosen.value) selected.clear();
  else for (const t of items.value ?? []) selected.add(t.id);
}

// ---- results
const note = ref("");
const failure = ref("");
const busy = ref(false);

const label = (list: TrashItem[]) => (list.length === 1 ? `“${list[0]?.name}”` : `${list.length} öge`);
const from = (t: TrashItem) => (t.from === null ? "bilinmiyor" : fullPath(root.value, t.from));

async function restore(list: TrashItem[]): Promise<void> {
  if (busy.value || !list.length) return;
  busy.value = true;
  failure.value = "";
  note.value = "";
  try {
    const done = await restoreTrash(list.map((t) => t.id));
    const renamed = done.filter((r) => list.find((t) => t.id === r.id)?.name !== r.name);
    const one = done.length === 1 ? done[0] : null;
    note.value = [
      one ? `Geri yüklendi: “${one.name}” → ${fullPath(root.value, one.path)}` : `${done.length} öge geri yüklendi.`,
      ...renamed.map((r) => `“${list.find((t) => t.id === r.id)?.name}” adı doluydu; “${r.name}” olarak geri yüklendi.`),
    ].join(" ");
    selected.clear();
  } catch (err) {
    failure.value = errorText(err);
  } finally {
    busy.value = false;
    void load();
  }
}

// ---- permanent removal: some items, or the whole trash
const removal = reactive({ open: false, all: false, items: [] as TrashItem[] });
const typed = ref(false);
const removeError = ref("");
const removeSize = computed(() => (removal.all ? total.value : removal.items.reduce((sum, t) => sum + (t.size ?? 0), 0)));
const removeCount = computed(() => (removal.all ? items.value?.length ?? 0 : removal.items.length));

function askPurge(list: TrashItem[]): void {
  Object.assign(removal, { open: true, all: false, items: list });
  removeError.value = "";
}
function askEmpty(): void {
  Object.assign(removal, { open: true, all: true, items: [] });
  removeError.value = "";
}

async function confirmRemove(): Promise<void> {
  if (busy.value || !typed.value) return;
  busy.value = true;
  removeError.value = "";
  try {
    if (removal.all) {
      const n = await emptyTrash();
      note.value = `Çöp boşaltıldı: ${n} öge kalıcı silindi.`;
    } else {
      await purgeTrash(removal.items.map((t) => t.id));
      note.value = `${label(removal.items)} kalıcı silindi.`;
    }
    failure.value = "";
    removal.open = false;
    selected.clear();
    void load();
  } catch (err) {
    removeError.value = errorText(err);
  } finally {
    busy.value = false;
  }
}
</script>

<template>
  <div class="files-tab" data-testid="cop">
    <section class="card files-trash" aria-labelledby="cop-baslik" data-testid="trash">
      <div class="card-head">
        <div class="files-heading-text">
          <h2 id="cop-baslik" class="card-title">Çöp kutusu</h2>
          <p v-if="items" class="meter-note" data-testid="trash-summary">{{ items.length }} öge · {{ bytes(total) }}</p>
        </div>
        <div class="card-actions">
          <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="trash-refresh" @click="load"><Icon name="refresh" :size="16" />Yenile</button>
          <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="!items?.length || busy" data-testid="trash-empty" @click="askEmpty"><Icon name="trash" :size="16" />Çöpü boşalt</button>
        </div>
      </div>
      <p class="meter-note">Sunucu klasörlerinden silinenler burada bekler; geri yüklenene ya da kalıcı silinene kadar disk alanı kaplar.</p>

      <p class="sr-only" role="status">{{ note }}</p>
      <p v-if="note" class="notice notice-ok" aria-hidden="true" data-testid="trash-note"><Icon name="check" class="notice-icon" /><span>{{ note }}</span></p>
      <p v-if="failure || readError" class="notice notice-danger" role="alert" data-testid="trash-failure"><Icon name="xcircle" class="notice-icon" /><span>{{ failure || readError }}</span></p>

      <template v-if="items">
        <div v-if="chosen.length" class="files-selection" role="group" aria-label="Seçilenler" data-testid="trash-selection">
          <p class="files-selection-text"><strong>{{ chosen.length }} öge seçili</strong> · {{ bytes(chosen.reduce((s, t) => s + (t.size ?? 0), 0)) }}</p>
          <div class="files-selection-actions">
            <button type="button" class="btn btn-secondary btn-sm" :disabled="busy || !restorable.length" data-testid="sel-restore" @click="restore(restorable)">
              <Icon name="restore" :size="16" />Geri yükle
            </button>
            <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="busy" data-testid="sel-purge" @click="askPurge(chosen)"><Icon name="trash" :size="16" />Kalıcı sil</button>
            <button type="button" class="btn btn-secondary btn-sm" @click="selected.clear()"><Icon name="close" :size="16" />Seçimi bırak</button>
          </div>
        </div>
        <template v-if="items.length">
          <label class="check-row files-all">
            <input type="checkbox" :checked="allChosen" :indeterminate="someChosen" data-testid="trash-all" @change="toggleAll" />
            <span>Tümünü seç</span>
          </label>
          <div class="files-table-wrap">
            <table class="files-table files-trash-table">
              <thead>
                <tr>
                  <th scope="col" class="files-check"><span class="sr-only">Seçim</span></th>
                  <th scope="col">Ad</th>
                  <th scope="col" class="files-size">Boyut</th>
                  <th scope="col" class="files-date">Silinme</th>
                  <th scope="col" class="files-acts"><span class="sr-only">Eylemler</span></th>
                </tr>
              </thead>
              <tbody>
                <tr v-for="t in items" :key="t.id" :data-cop="t.id" :data-oge="t.name" :class="{ 'files-row-on': selected.has(t.id) }">
                  <td class="files-check">
                    <label class="files-pick"><input type="checkbox" :checked="selected.has(t.id)" :aria-label="`Seç: ${t.name}`" @change="toggle(t.id)" /></label>
                  </td>
                  <th scope="row" class="files-name">
                    <span class="files-item">
                      <span class="files-icon" :class="'files-icon-' + t.type" aria-hidden="true"><Icon :name="t.type === 'dir' ? 'folder' : 'file'" :size="20" /></span>
                      <span class="files-item-text">
                        <span class="files-open files-open-plain">{{ t.name }}</span>
                        <span class="files-marks">
                          <span class="cell-note">Nereden:
                            <RouterLink v-if="t.from !== null" :to="filesRoute('srv', t.from ? { yol: t.from } : {})" class="mono">{{ from(t) }}</RouterLink>
                            <template v-else>{{ from(t) }}</template>
                          </span>
                          <span v-if="t.type === 'dir'" class="cell-note">{{ countText(t.count) }}</span>
                          <span v-if="t.broken" class="files-mark files-mark-lock">Bozuk kayıt; yalnız kalıcı silinir</span>
                        </span>
                      </span>
                    </span>
                  </th>
                  <td class="files-size" data-label="Boyut">{{ sizeText(t) }}</td>
                  <td class="files-date" data-label="Silinme"><time :datetime="isoTime(t.deleted)">{{ when(t.deleted) }}</time></td>
                  <td class="files-acts">
                    <span class="files-row-actions">
                      <button v-if="!t.broken" type="button" class="btn btn-secondary btn-sm" :disabled="busy" :aria-label="`Geri yükle: ${t.name}`" data-eylem="geri-yukle" @click="restore([t])">
                        <Icon name="restore" :size="16" />Geri yükle
                      </button>
                      <button type="button" class="icon-btn icon-btn-danger" :disabled="busy" :aria-label="`Kalıcı sil: ${t.name}`" title="Kalıcı sil" data-eylem="kalici-sil" @click="askPurge([t])">
                        <Icon name="trash" :size="18" />
                      </button>
                    </span>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </template>
        <EmptyState v-else title="Çöp boş" text="Sunucu klasörlerinden silinen dosyalar burada görünür ve geri yüklenebilir." icon="trash" />
      </template>
      <p v-else-if="loading" class="meter-note" role="status">Çöp okunuyor…</p>
    </section>

    <Modal
      :open="removal.open"
      :title="removal.all ? 'Çöp boşaltılsın mı?' : `${label(removal.items)} kalıcı silinsin mi?`"
      :description="`${removeCount} öge · ${bytes(removeSize)}`"
      @close="removal.open = false"
    >
      <ul class="modal-list">
        <li><Icon name="trash" :size="18" /><span>{{ removeCount }} öge kalıcı silinir.</span></li>
        <li><Icon name="server" :size="18" /><span>{{ bytes(removeSize) }} disk alanı boşalır.</span></li>
        <li><Icon name="lock" :size="18" /><span>Geri alınamaz.</span></li>
      </ul>
      <ConfirmWord v-if="removal.open" v-model:confirmed="typed" />
      <p v-if="removeError" class="form-error" role="alert" data-testid="purge-error">{{ removeError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="busy" @click="removal.open = false">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!typed || busy" data-testid="purge-go" @click="confirmRemove">
          {{ busy ? "Siliniyor…" : removal.all ? "Çöpü boşalt" : "Kalıcı sil" }}
        </button>
      </template>
    </Modal>
  </div>
</template>
