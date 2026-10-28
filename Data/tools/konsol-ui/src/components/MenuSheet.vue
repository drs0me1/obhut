<!-- "Daha fazla" on a phone (DD-258): the sidebar as a sheet from the bottom. Choosing a page closes it. -->
<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, watch } from "vue";
import { useRoute } from "vue-router";
import { Icon } from "./icons";
import { trapTab } from "./focus";
import SideNav from "./SideNav.vue";
import { closeSurface, ui } from "../ui";
import type { SectionId } from "../sections";

const sheet = ref<HTMLElement | null>(null);
const closeButton = ref<HTMLButtonElement | null>(null);
const route = useRoute();
const open = computed(() => ui.open === "sheet");

// Another page takes the focus to its heading; the page already open gives it back to "Daha fazla".
const chosen = (to: SectionId) => closeSurface(route.name === to);

watch(open, (isOpen) => {
  if (isOpen) void nextTick(() => closeButton.value?.focus());
});

// The sheet belongs to the phone layout: a wider window closes it.
const wide = window.matchMedia("(min-width: 761px)");
const onWide = () => {
  if (wide.matches && open.value) closeSurface(false);
};
wide.addEventListener("change", onWide);
onBeforeUnmount(() => wide.removeEventListener("change", onWide));

function onKeydown(event: KeyboardEvent): void {
  if (event.key === "Escape") {
    event.preventDefault();
    closeSurface();
  } else trapTab(event, sheet.value);
}
</script>

<template>
  <Transition name="sheet">
    <div v-if="open" class="layer layer-sheet" @keydown="onKeydown">
      <div class="scrim" aria-hidden="true" @click="closeSurface()"></div>
      <div ref="sheet" class="sheet" role="dialog" aria-modal="true" aria-label="Menü">
        <div class="sheet-head">
          <span class="sheet-grip" aria-hidden="true"></span>
          <button ref="closeButton" type="button" class="icon-btn" aria-label="Kapat" @click="closeSurface()">
            <Icon name="close" />
          </button>
        </div>
        <SideNav @navigate="chosen" />
      </div>
    </div>
  </Transition>
</template>
