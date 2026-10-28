<!-- The text editor (DD-249, phase 4b) in a wide sheet, for both trees. GET …/text?path=&enc= gives the
     text, its encoding and line ends and, when the server lets it be saved, its version; the CodeMirror
     bundle (editor.ts) loads beside it. A file the server will not have saved (too big, not lossless in the
     encoding, another account's, a hard link) and any file while the bundle cannot load is shown read-only
     with the reason. "Kaydet" (or Ctrl+S in the text) sends POST …/text/save {path, text, encoding, version}
     and the next save sends the version it returned; a file changed since it was opened is refused (409)
     and can be opened again. In Sistem dosyaları the sheet says the save is made as root. Closing, another
     encoding, opening again or the browser's Back with unsaved changes asks first, inside the sheet; closing
     the browser tab asks too. The open file is in the address (dosya=). -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue";
import { onBeforeRouteLeave, onBeforeRouteUpdate, useRouter, type RouteLocationNormalized } from "vue-router";
import { Icon } from "../../components/icons";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { ApiError } from "../../api/http";
import { downloadUrl, readText, saveText, type Encoding, type TextFile, type Tree } from "../../api/dosyalar";
import { useLeaveGuard } from "../../leave";
import { bytes } from "../../format";
import { loadEditor, type EditorHandle } from "./editor";
import { errorText, fullPath, joinPath } from "./files";

const props = defineProps<{ tree: Tree; root: string; folder: string; name: string | null }>();
const emit = defineEmits<{ close: []; saved: [] }>();

const ENCODINGS: readonly { id: Encoding | "auto"; label: string }[] = [
  { id: "auto", label: "Otomatik" },
  { id: "utf-8", label: "UTF-8" },
  { id: "cp1254", label: "Türkçe (Windows-1254)" },
  { id: "cp437", label: "DOS (CP437)" },
];
const ENCODING_TEXT: Record<Encoding, string> = { "utf-8": "UTF-8", cp1254: "Türkçe (Windows-1254)", cp437: "DOS (CP437)" };

const open = computed(() => props.name !== null);
const path = computed(() => joinPath(props.folder, props.name ?? ""));
const file = ref<TextFile | null>(null);
const readError = ref("");
const encoding = ref<Encoding | "auto">("auto");
const bundleFailed = ref(false);
const language = ref("");
const position = ref("Satır 1, Sütun 1");
const dirty = ref(false);
const saving = ref(false);
const saveError = ref("");
const conflict = ref(false);
const savedNote = ref("");
/** What waits for "Değişiklikleri at" (closing, another encoding, opening again). */
const asking = ref<(() => void) | null>(null);
const box = ref<HTMLElement | null>(null);
const backButton = ref<HTMLButtonElement | null>(null);
let editor: EditorHandle | null = null;
let seq = 0;

const editable = computed(() => Boolean(file.value?.editable && !bundleFailed.value));
const readOnlyText = computed(() => {
  const f = file.value;
  if (!f) return "";
  if (f.editable && bundleFailed.value) return "Düzenleyici yüklenemedi; dosya salt okunur gösteriliyor.";
  if (f.truncated) return "Dosya büyük: yalnız ilk bölümü salt okunur gösteriliyor.";
  if (!f.editable) return `Salt okunur: ${f.reason || "bu dosya buradan kaydedilemez"}.`;
  return "";
});
const facts = computed(() => {
  const f = file.value;
  const where = fullPath(props.root, props.folder);
  if (!f) return where;
  return [where, bytes(f.size), ENCODING_TEXT[f.encoding] + (f.bom ? " (BOM)" : ""), f.eol === "crlf" ? "CRLF" : "LF"].join(" · ");
});

useLeaveGuard(() => open.value && dirty.value);

// Back, Forward or an address typed while the text has unsaved changes: the sheet asks, then goes there.
const router = useRouter();
function holdNavigation(to: RouteLocationNormalized): boolean {
  if (!open.value || !dirty.value) return true;
  whenClean(() => void router.push(to.fullPath));
  return false;
}
onBeforeRouteUpdate(holdNavigation);
onBeforeRouteLeave(holdNavigation);

function teardown(): void {
  seq += 1;
  editor?.destroy();
  editor = null;
  dirty.value = false;
  saving.value = false;
  saveError.value = "";
  conflict.value = false;
  savedNote.value = "";
  asking.value = null;
  position.value = "Satır 1, Sütun 1";
}

async function load(enc: Encoding | "auto"): Promise<void> {
  teardown();
  const mine = seq;
  encoding.value = enc;
  file.value = null;
  readError.value = "";
  bundleFailed.value = false;
  const name = props.name ?? "";
  const [text, KE] = await Promise.all([readText(props.tree, path.value, enc).catch((err: unknown) => (err instanceof Error ? err : new Error(String(err)))), loadEditor().catch(() => null)]);
  if (mine !== seq) return;
  if (text instanceof Error) {
    readError.value = text.message;
    return;
  }
  file.value = text;
  bundleFailed.value = !KE;
  language.value = KE ? KE.language(name) : "";
  if (!KE || !text.editable) return;
  await nextTick();
  if (mine !== seq || !box.value) return;
  editor = KE.create(box.value, {
    doc: text.text,
    name,
    label: `${name} içeriği`,
    onChange: (on) => {
      dirty.value = on;
      if (on) savedNote.value = "";
    },
    onCursor: (line, column) => (position.value = `Satır ${line}, Sütun ${column}`),
    onSave: () => void save(),
  });
  editor.focus();
}

watch(
  () => [open.value, props.tree, path.value] as const,
  ([isOpen]) => {
    if (isOpen) void load("auto");
    else teardown();
  },
  { immediate: true },
);

onBeforeUnmount(teardown);

/** Runs `then` now, or after "Değişiklikleri at" while the text has unsaved changes. */
function whenClean(then: () => void): void {
  if (!dirty.value) {
    then();
    return;
  }
  asking.value = then;
  void nextTick(() => backButton.value?.focus());
}

function requestClose(): void {
  if (asking.value) {
    asking.value = null;
    return;
  }
  whenClean(() => emit("close"));
}

function discard(): void {
  const then = asking.value;
  asking.value = null;
  dirty.value = false;
  then?.();
}

function keepEditing(): void {
  asking.value = null;
  editor?.focus();
}

function onEncoding(event: Event): void {
  const select = event.target as HTMLSelectElement;
  const want = select.value as Encoding | "auto";
  select.value = encoding.value;
  whenClean(() => void load(want));
}

async function save(): Promise<void> {
  const f = file.value;
  if (!editor || !f || !f.version || saving.value || !editor.dirty()) return;
  saving.value = true;
  saveError.value = "";
  conflict.value = false;
  savedNote.value = "";
  const mine = seq;
  try {
    const r = await saveText(props.tree, { path: path.value, text: editor.text(), encoding: f.encoding, version: f.version });
    if (mine !== seq) return;
    file.value = { ...f, version: r.version, size: r.size, mtime: r.mtime };
    editor.markSaved();
    savedNote.value = "Kaydedildi.";
    emit("saved");
  } catch (err) {
    if (mine !== seq) return;
    saveError.value = errorText(err);
    conflict.value = err instanceof ApiError && err.status === 409;
  } finally {
    if (mine === seq) {
      saving.value = false;
      editor?.focus();
    }
  }
}

// Esc in the editor's search panel closes that panel only, not the sheet.
function onBoxKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape" && event.target instanceof Element && event.target.closest(".cm-panels")) event.stopPropagation();
}
</script>

<template>
  <Modal :open="open" variant="sheet" :title="name ?? ''" :description="facts" @close="requestClose">
    <div class="files-editor" data-testid="editor">
      <p v-if="tree === 'sistem' && editable" class="notice notice-warning" data-testid="root-save">
        <Icon name="alert" class="notice-icon" /><span><strong>Root olarak kaydedilir.</strong> Dosyanın sahibi ve izinleri korunur; önceki içerik geri alınamaz.</span>
      </p>
      <p v-if="readError" class="form-error" role="alert" data-testid="editor-error">{{ readError }}</p>
      <p v-else-if="!file" class="meter-note" role="status">Dosya okunuyor…</p>
      <template v-else>
        <p v-if="readOnlyText" class="notice" data-testid="read-only"><Icon name="info" class="notice-icon" /><span>{{ readOnlyText }}</span></p>
        <div class="files-editor-bar">
          <label class="files-editor-encoding">
            <span>Kodlama</span>
            <select class="input" :value="encoding" data-testid="encoding" @change="onEncoding">
              <option v-for="e in ENCODINGS" :key="e.id" :value="e.id">{{ e.label }}</option>
            </select>
          </label>
          <span v-if="language" class="pill pill-neutral" data-testid="language">{{ language }}</span>
          <StatusPill v-if="dirty" tone="warning" data-testid="dirty">Kaydedilmedi</StatusPill>
          <span v-if="editable" class="files-editor-pos" data-testid="position">{{ position }}</span>
        </div>
        <div v-if="editable" ref="box" class="ed-box" data-testid="editor-box" @keydown="onBoxKeydown"></div>
        <pre v-else class="files-textview" tabindex="0" :aria-label="`${name} içeriği`" data-testid="text-view">{{ file.text }}</pre>
        <p v-if="saveError" class="form-error" role="alert" data-testid="save-error">
          {{ saveError }}
          <button v-if="conflict" type="button" class="btn btn-secondary btn-sm files-reopen" data-testid="reopen" @click="whenClean(() => load(encoding))">Yeniden aç</button>
        </p>
        <p class="sr-only" role="status">{{ savedNote }}</p>
      </template>
    </div>
    <template #actions>
      <template v-if="asking">
        <p class="files-ask" role="alert" data-testid="discard-ask">Kaydedilmemiş değişiklikler atılsın mı?</p>
        <button ref="backButton" type="button" class="btn btn-secondary" data-testid="keep-editing" @click="keepEditing">Düzenlemeye dön</button>
        <button type="button" class="btn btn-danger" data-testid="discard" @click="discard">Değişiklikleri at</button>
      </template>
      <template v-else>
        <span v-if="editable" class="files-hint">Ctrl+S kaydeder · Ara: Ctrl+F</span>
        <span v-if="savedNote" class="files-saved" aria-hidden="true" data-testid="saved">{{ savedNote }}</span>
        <a v-if="file" class="btn btn-secondary" :href="downloadUrl(tree, path)" download data-testid="editor-download"><Icon name="download" :size="18" />İndir</a>
        <button type="button" class="btn btn-secondary" data-testid="editor-close" @click="requestClose">Kapat</button>
        <button v-if="editable" type="button" class="btn btn-primary" :disabled="!dirty || saving" data-testid="save" @click="save">{{ saving ? "Kaydediliyor…" : "Kaydet" }}</button>
      </template>
    </template>
  </Modal>
</template>
