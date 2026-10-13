<!-- Tabs (DD-258 goal 5): the chosen tab is a query parameter of the address (`param`, the first tab when
     absent), so a reload or a shared link opens the same tab. One tab stop: ←/→ move and choose, Home/End
     go to the ends. The panel below shows the chosen tab's content (the default slot gets its id). -->
<script setup lang="ts">
import { ref, useId } from "vue";
import { useQueryParam } from "../../query";
import type { TabItem } from "./types";

const props = defineProps<{ tabs: readonly TabItem[]; label: string; param: string }>();
defineSlots<{ default(props: { active: string }): unknown }>();

const ids = props.tabs.map((t) => t.id);
const active = useQueryParam(props.param, ids, ids[0] ?? "");
const base = useId();
const tabId = (id: string) => `${base}-sekme-${id}`;
const panelId = `${base}-panel`;
const buttons = ref<HTMLButtonElement[]>([]);

function onKeydown(event: KeyboardEvent, index: number): void {
  const n = props.tabs.length;
  const to =
    event.key === "ArrowRight" ? (index + 1) % n
    : event.key === "ArrowLeft" ? (index - 1 + n) % n
    : event.key === "Home" ? 0
    : event.key === "End" ? n - 1
    : -1;
  const tab = props.tabs[to];
  if (!tab) return;
  event.preventDefault();
  active.value = tab.id;
  buttons.value.find((b) => b.dataset.sekme === tab.id)?.focus();
}
</script>

<template>
  <div class="tabs">
    <div class="tablist" role="tablist" :aria-label="label">
      <button
        v-for="(t, i) in tabs"
        :id="tabId(t.id)"
        :key="t.id"
        ref="buttons"
        type="button"
        role="tab"
        class="tab"
        :data-sekme="t.id"
        :aria-selected="active === t.id"
        :aria-controls="panelId"
        :tabindex="active === t.id ? 0 : -1"
        @click="active = t.id"
        @keydown="onKeydown($event, i)"
      >
        {{ t.label }}
      </button>
    </div>
    <div :id="panelId" class="tabpanel" role="tabpanel" :aria-labelledby="tabId(active)" tabindex="0">
      <slot :active="active" />
    </div>
  </div>
</template>
