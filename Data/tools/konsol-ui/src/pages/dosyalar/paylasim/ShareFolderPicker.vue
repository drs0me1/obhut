<!-- The share's folder (phase 4b, DD-267): the chosen folder in a read-only field and "Klasör seç", which
     opens a panel under it with the user area's folders (the files backend, GET /api/list?path=&dirs=1;
     hidden ones are never listed), the ones already shared marked. "İçine gir" goes down, "Bir üst" back,
     "Seç" or "Bu klasörü seç" take a folder; the top of the user area itself cannot be shared. The same
     markup as the base's FolderPicker (Esc closes the panel, not the sheet around it, also from "Klasör
     seç"), but over paths relative to the user area, as a share keeps them. -->
<script setup lang="ts">
import { computed, nextTick, ref, useId } from "vue";
import { Icon } from "../../../components/icons";
import { readUserFolders, type UserFolder } from "../../../api/paylasim";
import { fullPath } from "./share";

const props = withDefaults(
  defineProps<{ id?: string; describedby?: string; invalid?: boolean; disabled?: boolean; root: string; shared?: readonly string[] }>(),
  { id: undefined, describedby: undefined, invalid: false, disabled: false, shared: () => [] },
);
const value = defineModel<string>({ default: "" });

const panelId = useId();
const open = ref(false);
const at = ref("");
const items = ref<UserFolder[] | null>(null);
const error = ref("");
const toggle = ref<HTMLButtonElement | null>(null);
const here = ref<HTMLElement | null>(null);
let seq = 0;

const top = computed(() => props.root || "Kullanıcı alanı");
const shown = (path: string) => (path ? fullPath(props.root, path) : top.value);
const isShared = (path: string) => props.shared.includes(path);

async function browse(focusHere = false): Promise<void> {
  const mine = ++seq;
  items.value = null;
  error.value = "";
  try {
    const list = await readUserFolders(at.value);
    if (mine !== seq) return;
    items.value = list;
  } catch (err) {
    if (mine === seq) error.value = err instanceof Error ? err.message : String(err);
  }
  if (focusHere && mine === seq) {
    await nextTick();
    here.value?.focus();
  }
}

function show(): void {
  if (open.value) {
    close();
    return;
  }
  open.value = true;
  // Start beside the chosen folder, so a change is one step away.
  at.value = value.value.includes("/") ? value.value.slice(0, value.value.lastIndexOf("/")) : "";
  void browse();
}

function close(returnFocus = true): void {
  open.value = false;
  seq += 1;
  if (returnFocus) void nextTick(() => toggle.value?.focus());
}

function enter(path: string): void {
  at.value = path;
  void browse(true);
}

function up(): void {
  at.value = at.value.includes("/") ? at.value.slice(0, at.value.lastIndexOf("/")) : "";
  void browse(true);
}

function choose(path: string): void {
  value.value = path;
  close();
}

// Esc while the panel is open (from it or from "Klasör seç") closes the panel, not the sheet around it.
function onKeydown(event: KeyboardEvent): void {
  if (event.key !== "Escape" || !open.value) return;
  event.preventDefault();
  event.stopPropagation();
  close();
}
</script>

<template>
  <div class="folder-picker" @keydown="onKeydown">
    <div class="folder-pick">
      <input
        :id="id"
        class="input mono"
        type="text"
        readonly
        :value="value ? shown(value) : ''"
        placeholder="Klasör seçilmedi"
        :aria-describedby="describedby"
        :aria-invalid="invalid || undefined"
        data-testid="share-folder-value"
      />
      <button
        ref="toggle"
        type="button"
        class="btn btn-secondary"
        :disabled="disabled"
        :aria-expanded="open"
        :aria-controls="panelId"
        aria-label="Paylaşılacak klasörü seç"
        data-testid="share-folder-toggle"
        @click="show"
      >
        <Icon name="folder" :size="18" />Klasör seç
      </button>
    </div>
    <div v-if="open" :id="panelId" class="folder-panel" role="group" aria-label="Klasör seçimi" data-testid="share-folder-panel">
      <div class="folder-here">
        <button v-if="at" type="button" class="btn btn-secondary btn-sm" data-testid="share-folder-up" @click="up">
          <Icon name="chevron" :size="16" class="flip" />{{ at.includes("/") ? "Bir üst" : top }}
        </button>
        <span ref="here" class="folder-where" tabindex="-1">
          <span class="sr-only">Şu an: </span><span class="mono">{{ shown(at) }}</span>
        </span>
        <button v-if="at" type="button" class="btn btn-primary btn-sm" data-testid="share-folder-here" @click="choose(at)">Bu klasörü seç</button>
      </div>
      <p v-if="error" class="form-error" role="alert">{{ error }}</p>
      <p v-else-if="!items" class="meter-note">Klasörler okunuyor…</p>
      <ul v-else-if="items.length" class="folder-list" :aria-label="`${shown(at)} altındaki klasörler`">
        <li v-for="f in items" :key="f.path" class="folder-row" :data-klasor="f.path">
          <span class="folder-text">
            <span class="wrap">{{ f.name }}</span>
            <span v-if="isShared(f.path)" class="meter-note">Paylaşılıyor</span>
          </span>
          <span class="folder-acts">
            <button type="button" class="btn btn-secondary btn-sm" :aria-label="`${f.name} içine gir`" @click="enter(f.path)">İçine gir</button>
            <button type="button" class="btn btn-primary btn-sm" :aria-label="`${f.name} seç`" @click="choose(f.path)">Seç</button>
          </span>
        </li>
      </ul>
      <p v-else class="meter-note">Bu klasörün altında klasör yok.</p>
      <p class="sr-only" role="status">{{ items ? `${items.length} klasör` : "Klasörler okunuyor" }}</p>
      <div class="folder-foot">
        <button type="button" class="btn btn-secondary btn-sm" @click="close()">Kapat</button>
      </div>
    </div>
  </div>
</template>
