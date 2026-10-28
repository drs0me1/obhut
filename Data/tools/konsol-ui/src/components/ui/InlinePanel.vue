<!-- A panel inside the page, in the table row under the row it belongs to (Erişim → Adresler): a compact card with
     the sheet's parts (the title, a `lead` line beside it, the body and the actions) without a layer; the page stays
     usable around it. `hideTitle` keeps the title for screen readers only (the row above already names it). When it
     opens, its row and the panel come into view (the row at the top when both do not fit; scroll-margin keeps them
     clear of a phone's bars) and focus moves in ([data-autofocus] or the first control); it comes back in when the
     control that held it goes away (a form's next step replaced it). Esc and "Kapat" close it. -->
<script setup lang="ts">
import { nextTick, onUpdated, ref, useId, watch } from "vue";
import { Icon } from "../icons";

const props = withDefaults(defineProps<{ open: boolean; title: string; description?: string; hideTitle?: boolean }>(), {
  description: "",
  hideTitle: false,
});
const emit = defineEmits<{ close: [] }>();

const panel = ref<HTMLElement | null>(null);
const titleId = useId();
const descId = useId();
/** Whether the focus is in the panel (it stays so while the focused control is replaced by the next step's). */
let inside = false;

function focusFirst(): void {
  const root = panel.value;
  if (!root) return;
  const wanted =
    root.querySelector<HTMLElement>("[data-autofocus]") ??
    root.querySelector<HTMLElement>(".inline-panel-body :is(a[href], button:not([disabled]), input:not([disabled]), select:not([disabled])), .inline-panel-foot button:not([disabled])") ??
    root.querySelector<HTMLElement>(".inline-panel-close");
  wanted?.focus({ preventScroll: true });
}

/** Its row and the panel in view: nothing moves when both are visible already. */
function reveal(): void {
  const root = panel.value;
  if (!root) return;
  const before = root.closest("tr")?.previousElementSibling;
  const lead = before instanceof HTMLElement ? before : root;
  const top = lead.getBoundingClientRect().top - parseFloat(getComputedStyle(lead).scrollMarginTop || "0");
  const bottom = root.getBoundingClientRect().bottom + parseFloat(getComputedStyle(root).scrollMarginBottom || "0");
  if (top < 0 || bottom > window.innerHeight) lead.scrollIntoView({ block: "start" });
}

watch(
  () => props.open,
  (open) => {
    inside = false;
    if (open)
      void nextTick(() => {
        reveal();
        focusFirst();
      });
  },
  { immediate: true },
);

onUpdated(() => {
  if (props.open && inside && !panel.value?.contains(document.activeElement)) focusFirst();
});

function onFocusIn(): void {
  inside = true;
}

function onFocusOut(event: FocusEvent): void {
  const next = event.relatedTarget;
  if (next instanceof Node && panel.value?.contains(next)) return;
  // A control that went away keeps the focus "inside"; one the operator left does not.
  const left = event.target;
  window.setTimeout(() => {
    if (left instanceof Node && left.isConnected) inside = false;
  });
}

function onKeydown(event: KeyboardEvent): void {
  if (event.key !== "Escape") return;
  event.preventDefault();
  event.stopPropagation();
  emit("close");
}
</script>

<template>
  <section
    v-if="open"
    ref="panel"
    class="inline-panel"
    role="region"
    :aria-labelledby="titleId"
    :aria-describedby="description ? descId : undefined"
    @focusin="onFocusIn"
    @focusout="onFocusOut"
    @keydown="onKeydown"
  >
    <header class="inline-panel-head">
      <div class="inline-panel-heading">
        <h3 :id="titleId" :class="{ 'sr-only': hideTitle }">{{ title }}</h3>
        <p v-if="description" :id="descId" class="inline-panel-desc" :class="{ 'sr-only': hideTitle }">{{ description }}</p>
        <slot name="lead" />
      </div>
      <button type="button" class="icon-btn inline-panel-close" aria-label="Kapat" @click="emit('close')">
        <Icon name="close" />
      </button>
    </header>
    <div class="inline-panel-body"><slot /></div>
    <footer v-if="$slots.actions" class="inline-panel-foot"><slot name="actions" /></footer>
  </section>
</template>
