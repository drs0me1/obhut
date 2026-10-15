<!-- The folder picker (DD-266, phase 4a): the chosen folder in a read-only field and "Klasör seç", which
     opens a panel under it with the base's safe folders (GET /api/konsol/ayarlar/klasorler: the download and
     library roots, then the folders under one of them; hidden, share and trash folders are never listed),
     each with its free space, "İçine gir" and "Seç". "Bu klasörü seç" takes the folder the panel is in, "Bir
     üst" goes back. Every control is a button in the tab order; Esc closes the panel (not the dialog around
     it) and gives the focus back to "Klasör seç". The field's id and description come from Field's slot. -->
<script setup lang="ts">
import { computed, nextTick, ref, useId } from "vue";
import { Icon } from "../icons";
import { readFolders } from "../../api/podman";
import { bytes } from "../../format";

withDefaults(defineProps<{ id?: string; describedby?: string; invalid?: boolean; disabled?: boolean; name?: string }>(), {
  id: undefined,
  describedby: undefined,
  invalid: false,
  disabled: false,
  name: "Klasör",
});
const value = defineModel<string>({ default: "" });

const panelId = useId();
const open = ref(false);
/** The folders entered, the last one shown ("" for the roots). */
const trail = ref<string[]>([]);
const items = ref<{ path: string; free: number }[] | null>(null);
const error = ref("");
const toggle = ref<HTMLButtonElement | null>(null);
const here = ref<HTMLElement | null>(null);
const at = computed(() => trail.value.at(-1) ?? "");
let seq = 0;

async function browse(focusHere = false): Promise<void> {
  const mine = ++seq;
  items.value = null;
  error.value = "";
  try {
    const list = await readFolders(at.value);
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
  trail.value = [];
  void browse();
}

function close(returnFocus = true): void {
  open.value = false;
  seq += 1;
  if (returnFocus) void nextTick(() => toggle.value?.focus());
}

function enter(path: string): void {
  trail.value = [...trail.value, path];
  void browse(true);
}

function up(): void {
  trail.value = trail.value.slice(0, -1);
  void browse(true);
}

function choose(path: string): void {
  value.value = path;
  close();
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key !== "Escape") return;
  event.preventDefault();
  event.stopPropagation();
  close();
}
</script>

<template>
  <div class="folder-picker">
    <div class="folder-pick">
      <input
        :id="id"
        class="input mono"
        type="text"
        readonly
        :value="value"
        placeholder="Klasör seçilmedi"
        :aria-describedby="describedby"
        :aria-invalid="invalid || undefined"
        data-testid="folder-value"
      />
      <button
        ref="toggle"
        type="button"
        class="btn btn-secondary"
        :disabled="disabled"
        :aria-expanded="open"
        :aria-controls="panelId"
        :aria-label="`${name}: klasör seç`"
        data-testid="folder-toggle"
        @click="show"
      >
        <Icon name="folder" :size="18" />Klasör seç
      </button>
    </div>
    <div v-if="open" :id="panelId" class="folder-panel" role="group" :aria-label="`${name} seçimi`" data-testid="folder-panel" @keydown="onKeydown">
      <div class="folder-here">
        <button v-if="trail.length" type="button" class="btn btn-secondary btn-sm" data-testid="folder-up" @click="up">
          <Icon name="chevron" :size="16" class="flip" />{{ trail.length > 1 ? "Bir üst" : "Başlangıç klasörleri" }}
        </button>
        <span ref="here" class="folder-where" tabindex="-1">
          <span class="sr-only">Şu an: </span><span :class="{ mono: at }">{{ at || "Başlangıç klasörleri" }}</span>
        </span>
        <button v-if="at" type="button" class="btn btn-primary btn-sm" data-testid="folder-choose-here" @click="choose(at)">Bu klasörü seç</button>
      </div>
      <p v-if="error" class="form-error" role="alert">{{ error }}</p>
      <p v-else-if="!items" class="meter-note">Klasörler okunuyor…</p>
      <ul v-else-if="items.length" class="folder-list" :aria-label="at ? `${at} altındaki klasörler` : 'Başlangıç klasörleri'">
        <li v-for="f in items" :key="f.path" class="folder-row" :data-klasor="f.path">
          <span class="folder-text">
            <span class="mono wrap">{{ f.path }}</span>
            <span class="meter-note">{{ bytes(f.free) }} boş</span>
          </span>
          <span class="folder-acts">
            <button type="button" class="btn btn-secondary btn-sm" :aria-label="`${f.path} içine gir`" @click="enter(f.path)">İçine gir</button>
            <button type="button" class="btn btn-primary btn-sm" :aria-label="`${f.path} seç`" @click="choose(f.path)">Seç</button>
          </span>
        </li>
      </ul>
      <p v-else class="meter-note">Bu klasörün altında seçilebilir klasör yok.</p>
      <p class="sr-only" role="status">{{ items ? `${items.length} klasör` : "Klasörler okunuyor" }}</p>
      <div class="folder-foot">
        <button type="button" class="btn btn-secondary btn-sm" @click="close()">Kapat</button>
      </div>
    </div>
  </div>
</template>
