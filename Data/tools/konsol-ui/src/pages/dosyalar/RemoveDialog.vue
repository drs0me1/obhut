<!-- Removing items (phase 4b). In the user area they go to the trash (POST /api/trash {path, names}) and
     come back from Çöp kutusu, so a plain confirmation is enough. In Sistem dosyaları there is no trash
     (DD-235): the delete is permanent, done as root, and needs the typed word — one item's own name, or
     "onayla" for several — which is also what the request carries (POST /api/sistem/delete {path, names,
     confirm}); the server refuses a mount point or a folder with a disk mounted inside. -->
<script setup lang="ts">
import { computed, ref, watch } from "vue";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import Modal from "../../components/ui/Modal.vue";
import { deleteItems, trashItems, type Entry, type Tree } from "../../api/dosyalar";
import { bytes } from "../../format";
import { errorText, fullPath, joinPath } from "./files";

const props = defineProps<{ open: boolean; tree: Tree; root: string; folder: string; items: Entry[] }>();
const emit = defineEmits<{ close: []; done: [message: string] }>();

const typed = ref(false);
const error = ref("");
const sending = ref(false);

const forever = computed(() => props.tree === "sistem");
const one = computed(() => (props.items.length === 1 ? props.items[0] : null));
const label = computed(() => (one.value ? `“${one.value.name}”` : `${props.items.length} öge`));
const word = computed(() => one.value?.name ?? "onayla");
const size = computed(() => props.items.reduce((sum, i) => sum + (i.size ?? 0), 0));
const title = computed(() => `${label.value} ${forever.value ? "kalıcı silinsin mi?" : "çöpe taşınsın mı?"}`);
const where = computed(() => fullPath(props.root, one.value ? joinPath(props.folder, one.value.name) : props.folder));

watch(
  () => props.open,
  (open) => {
    if (!open) return;
    error.value = "";
    sending.value = false;
  },
);

async function submit(): Promise<void> {
  if (sending.value || (forever.value && !typed.value)) return;
  sending.value = true;
  error.value = "";
  const names = props.items.map((i) => i.name);
  try {
    if (forever.value) await deleteItems(props.folder, names, word.value);
    else await trashItems(props.folder, names);
    emit("done", `${label.value} ${forever.value ? "kalıcı silindi." : "çöpe taşındı."}`);
  } catch (err) {
    error.value = errorText(err);
  } finally {
    sending.value = false;
  }
}
</script>

<template>
  <Modal :open="open" :title="title" :description="where" @close="emit('close')">
    <ul class="modal-list">
      <template v-if="forever">
        <li><Icon name="lock" :size="18" /><span>Geri alınamaz; Sistem dosyalarında çöp kutusu yoktur.</span></li>
        <li><Icon name="server" :size="18" /><span>Root olarak silinir; sistemin kendi dosyaları da silinebilir.</span></li>
      </template>
      <li v-else><Icon name="restore" :size="18" /><span>Çöp kutusundan geri yüklenebilir; disk alanı çöp boşaltılınca açılır.</span></li>
      <li v-if="size"><Icon name="file" :size="18" /><span>{{ bytes(size) }}</span></li>
    </ul>
    <ConfirmWord v-if="forever && open" v-model:confirmed="typed" :word="word" />
    <p v-if="error" class="form-error" role="alert" data-testid="remove-error">{{ error }}</p>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="sending" @click="emit('close')">Vazgeç</button>
      <button type="button" class="btn btn-danger" :disabled="sending || (forever && !typed)" data-testid="remove-go" @click="submit">
        {{ sending ? "Gönderiliyor…" : forever ? "Kalıcı sil" : "Çöpe taşı" }}
      </button>
    </template>
  </Modal>
</template>
