<!-- An application's file (K2, K3): a plain text area with the line numbers in a gutter beside it and the
     inspector's marks beside their lines ("port", "gizli değer", "durduruyor"), as the prototype shows them. The
     numbers and the marks are drawn behind the text area, which stays the only thing that takes input; they scroll
     with it. No soft wrap, so a line is a line; a long one scrolls inside the box, never the page. The full words of
     each mark are the refusals, notes and questions the page lists, so the drawing is hidden from screen readers.
     `readonly` shows the file without editing it (its text stays selectable). `current` lights the line of the
     question in hand; a click reports its line (`pick`), so the page can show that line's question. -->
<script setup lang="ts">
import { computed, ref, useId } from "vue";
import type { LineMark } from "./answers";

const props = withDefaults(
  defineProps<{
    marks?: ReadonlyMap<number, LineMark> | null;
    readonly?: boolean;
    label: string;
    describedby?: string;
    invalid?: boolean;
    maxRows?: number;
    current?: number | null;
  }>(),
  { marks: null, readonly: false, describedby: undefined, invalid: false, maxRows: 24, current: null },
);
const emit = defineEmits<{ pick: [line: number] }>();
const text = defineModel<string>({ default: "" });

const id = useId();
const area = ref<HTMLTextAreaElement | null>(null);
const gutter = ref<HTMLElement | null>(null);
const backdrop = ref<HTMLElement | null>(null);

const lines = computed(() => text.value.split("\n"));
const rows = computed(() => Math.max(props.readonly ? 1 : 6, Math.min(props.maxRows, lines.value.length + (props.readonly ? 0 : 1))));
const mark = (n: number) => props.marks?.get(n) ?? null;
/** The gutter's width class: two digits by default, more for a longer file. */
const digits = computed(() => {
  const n = Math.min(6, String(lines.value.length).length);
  return n > 2 ? "code-d" + n : "";
});

function sync(): void {
  const a = area.value;
  if (!a) return;
  if (gutter.value) gutter.value.scrollTop = a.scrollTop;
  if (backdrop.value) {
    backdrop.value.scrollTop = a.scrollTop;
    backdrop.value.scrollLeft = a.scrollLeft;
  }
}

/** Shows a line (a question's "Satır 6"): the text area scrolls there and the caret goes to its start. */
function reveal(line: number): void {
  const a = area.value;
  if (!a) return;
  const start = lines.value.slice(0, Math.max(0, line - 1)).reduce((n, l) => n + l.length + 1, 0);
  a.focus({ preventScroll: true });
  a.setSelectionRange(start, start);
  a.scrollTop = Math.max(0, (line - 3) * 20);
  sync();
  a.scrollIntoView({ block: "nearest" });
}

/** Scrolls a line into the text area's view without taking the focus (the question in hand). */
function show(line: number): void {
  const a = area.value;
  if (!a) return;
  const top = (line - 1) * 20;
  if (top < a.scrollTop || top + 20 > a.scrollTop + a.clientHeight - 20) a.scrollTop = Math.max(0, top - a.clientHeight / 3);
  sync();
}

function onPick(): void {
  const a = area.value;
  if (a) emit("pick", text.value.slice(0, a.selectionStart).split("\n").length);
}

defineExpose({ reveal, show });
</script>

<template>
  <div class="code-editor" :class="[digits, { 'code-readonly': readonly, 'code-invalid': invalid }]">
    <div ref="gutter" class="code-gutter" aria-hidden="true">
      <span v-for="(_, i) in lines" :key="i" class="code-num" :class="mark(i + 1) ? 'code-num-' + mark(i + 1)?.tone : ''">{{ i + 1 }}</span>
    </div>
    <div class="code-area">
      <div ref="backdrop" class="code-backdrop" aria-hidden="true" data-testid="code-marks">
        <div v-for="(line, i) in lines" :key="i" class="code-line" :class="[mark(i + 1) ? 'code-line-' + mark(i + 1)?.tone : '', { 'code-line-current': current === i + 1 }]"
          :data-satir="mark(i + 1) ? i + 1 : undefined">
          <span class="code-text">{{ line || " " }}</span><span v-if="mark(i + 1)" class="code-mark">{{ mark(i + 1)?.labels.join(" · ") }}</span>
        </div>
      </div>
      <textarea
        :id="id"
        ref="area"
        v-model="text"
        class="code-input"
        wrap="off"
        :rows="rows"
        :readonly="readonly"
        :aria-label="label"
        :aria-describedby="describedby"
        :aria-invalid="invalid || undefined"
        autocomplete="off"
        autocapitalize="off"
        spellcheck="false"
        data-testid="code-input"
        @scroll="sync"
        @input="sync"
        @mouseup="onPick"
      ></textarea>
    </div>
  </div>
</template>
