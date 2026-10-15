<!-- A name for a new folder or for an item (Dosyalar' folder views, phase 4b): POST …/mkdir {path, name} or
     …/rename {path, name, to}. The name is checked as the server checks it (not empty, no "/", not "." or
     "..", no spaces around it, at most 255 bytes); anything else the server refuses (a name already taken:
     it never writes over one) is shown in its words and the dialog stays open. -->
<script setup lang="ts">
import { computed, nextTick, ref, watch } from "vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import { makeFolder, renameItem, type Entry, type Tree } from "../../api/dosyalar";
import { errorText, fullPath, TYPE_TEXT } from "./files";

const props = defineProps<{ open: boolean; tree: Tree; root: string; folder: string; item: Entry | null }>();
const emit = defineEmits<{ close: []; done: [message: string, name: string] }>();

const name = ref("");
const tried = ref(false);
const error = ref("");
const sending = ref(false);
const input = ref<HTMLInputElement | null>(null);

const renaming = computed(() => props.item !== null);
const title = computed(() => (props.item ? "Yeniden adlandır" : "Yeni klasör"));
const where = computed(() => fullPath(props.root, props.folder));

watch(
  () => props.open,
  async (open) => {
    if (!open) return;
    name.value = props.item?.name ?? "";
    tried.value = false;
    error.value = "";
    sending.value = false;
    await nextTick();
    // A file's name is selected up to its extension, so typing replaces the name and keeps the type.
    const el = input.value;
    if (el && props.item) {
      const dot = props.item.type === "file" ? props.item.name.lastIndexOf(".") : -1;
      el.setSelectionRange(0, dot > 0 ? dot : props.item.name.length);
    }
  },
);

const problem = computed(() => {
  const v = name.value;
  if (!v.trim()) return "Bir ad yazın.";
  if (v !== v.trim()) return "Ad boşlukla başlayamaz ya da bitemez.";
  if (v.includes("/")) return "Ad / içeremez.";
  if (v === "." || v === "..") return "Bu ad kullanılamaz.";
  if (new TextEncoder().encode(v).length > 255) return "Ad en çok 255 bayt olabilir.";
  return "";
});

async function submit(): Promise<void> {
  if (sending.value) return;
  tried.value = true;
  error.value = "";
  if (problem.value) return;
  const to = name.value;
  if (props.item && to === props.item.name) {
    emit("close");
    return;
  }
  sending.value = true;
  try {
    if (props.item) {
      await renameItem(props.tree, props.folder, props.item.name, to);
      emit("done", `“${props.item.name}” → “${to}”`, to);
    } else {
      await makeFolder(props.tree, props.folder, to);
      emit("done", `“${to}” klasörü oluşturuldu.`, to);
    }
  } catch (err) {
    error.value = errorText(err);
  } finally {
    sending.value = false;
  }
}
</script>

<template>
  <Modal :open="open" :title="title" :description="renaming && item ? `${TYPE_TEXT[item.type]} · ${where}` : where" @close="emit('close')">
    <form id="ad-formu" class="form-stack" novalidate @submit.prevent="submit">
      <Field v-slot="{ id, describedby, invalid }" :label="renaming ? 'Yeni ad' : 'Klasör adı'" :error="tried ? problem : ''">
        <input
          :id="id"
          ref="input"
          v-model="name"
          class="input"
          type="text"
          maxlength="255"
          autocomplete="off"
          autocapitalize="off"
          spellcheck="false"
          :disabled="sending"
          :aria-describedby="describedby"
          :aria-invalid="invalid || undefined"
          data-autofocus
          data-testid="name-input"
        />
      </Field>
      <p v-if="error" class="form-error" role="alert" data-testid="name-error">{{ error }}</p>
    </form>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="sending" @click="emit('close')">Vazgeç</button>
      <button type="submit" form="ad-formu" class="btn btn-primary" :disabled="sending" data-testid="name-go">
        {{ sending ? "Kaydediliyor…" : renaming ? "Yeniden adlandır" : "Oluştur" }}
      </button>
    </template>
  </Modal>
</template>
