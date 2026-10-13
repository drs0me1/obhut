<!-- The dialog and the sheet (DD-258 goal 5): a small confirmation in the middle ("dialog") or a larger
     panel from the side ("sheet"); on a phone both rise from the bottom. Rendered outside the page, which is
     inert meanwhile (ui.ts). Focus moves in (to [data-autofocus] or the first control) and stays inside;
     Esc, the backdrop or "Kapat" close it and focus returns to the control that opened it. -->
<script setup lang="ts">
import { nextTick, onBeforeUnmount, ref, useId, watch } from "vue";
import { Icon } from "../icons";
import { trapTab } from "../focus";
import { closeSurface, openSurface, ui } from "../../ui";

const props = withDefaults(defineProps<{ open: boolean; title: string; description?: string; variant?: "dialog" | "sheet" }>(), {
  description: "",
  variant: "dialog",
});
const emit = defineEmits<{ close: [] }>();

const panel = ref<HTMLElement | null>(null);
const titleId = useId();
const descId = useId();

function focusFirst(): void {
  const root = panel.value;
  if (!root) return;
  const wanted =
    root.querySelector<HTMLElement>("[data-autofocus]") ??
    root.querySelector<HTMLElement>(".modal-body :is(a[href], button:not([disabled]), input:not([disabled])), .modal-foot button:not([disabled])") ??
    root.querySelector<HTMLElement>(".modal-close");
  wanted?.focus();
}

// Whether this dialog holds the shell's modal surface (a page may have several dialogs, one open at a time).
let owns = false;

watch(
  () => props.open,
  (open) => {
    if (open && !owns) {
      owns = true;
      openSurface("dialog");
      void nextTick(focusFirst);
    } else if (!open && owns) {
      owns = false;
      if (ui.open === "dialog") closeSurface();
    }
  },
  { immediate: true },
);

// Another surface took over (it cannot normally: the shortcuts wait while a dialog is open).
watch(
  () => ui.open,
  (which) => {
    if (owns && which !== "dialog") {
      owns = false;
      emit("close");
    }
  },
);

// The page went away with the dialog open (Back): the shell must not stay inert.
onBeforeUnmount(() => {
  if (!owns) return;
  owns = false;
  if (ui.open === "dialog") closeSurface(false);
});

function onKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    emit("close");
  } else trapTab(event, panel.value);
}
</script>

<template>
  <Teleport to="body">
    <Transition name="modal">
      <div v-if="open" class="layer layer-modal" :class="'layer-modal-' + variant" @keydown="onKeydown">
        <div class="scrim" aria-hidden="true" @click="emit('close')"></div>
        <div
          ref="panel"
          class="modal"
          :class="'modal-' + variant"
          role="dialog"
          aria-modal="true"
          :aria-labelledby="titleId"
          :aria-describedby="description ? descId : undefined"
        >
          <header class="modal-head">
            <div class="modal-heading">
              <h2 :id="titleId">{{ title }}</h2>
              <p v-if="description" :id="descId" class="modal-desc">{{ description }}</p>
            </div>
            <button type="button" class="icon-btn modal-close" aria-label="Kapat" @click="emit('close')">
              <Icon name="close" />
            </button>
          </header>
          <div class="modal-body"><slot /></div>
          <footer v-if="$slots.actions" class="modal-foot"><slot name="actions" /></footer>
        </div>
      </div>
    </Transition>
  </Teleport>
</template>
