<!-- The field (DD-258 goal 5): a label, the control (the default slot gets its id, the ids that describe it
     and whether it is invalid), an error in the backend's or the form's words and a hint. `group` makes it a
     fieldset with a legend, for radios and chips. `suffix` writes a fixed ending after a text control
     (".ev" after a name). -->
<script setup lang="ts">
import { computed, useId } from "vue";

const props = withDefaults(defineProps<{ label: string; hint?: string; error?: string; optional?: boolean; group?: boolean; suffix?: string }>(), {
  hint: "",
  error: "",
  optional: false,
  group: false,
  suffix: "",
});
defineSlots<{ default(props: { id: string; describedby: string | undefined; invalid: boolean }): unknown }>();

const id = useId();
const errorId = `${id}-hata`;
const hintId = `${id}-ipucu`;
const describedby = computed(() => [props.error ? errorId : "", props.hint ? hintId : ""].filter(Boolean).join(" ") || undefined);
</script>

<template>
  <fieldset v-if="group" class="field field-group" :class="{ 'field-invalid': error }" :aria-describedby="describedby">
    <legend class="field-label">{{ label }}<span v-if="optional" class="field-optional"> · isteğe bağlı</span></legend>
    <slot :id="id" :describedby="describedby" :invalid="Boolean(error)" />
    <p v-if="error" :id="errorId" class="field-error">{{ error }}</p>
    <p v-if="hint" :id="hintId" class="field-help">{{ hint }}</p>
  </fieldset>
  <div v-else class="field" :class="{ 'field-invalid': error }">
    <label :for="id" class="field-label">{{ label }}<span v-if="optional" class="field-optional"> · isteğe bağlı</span></label>
    <div v-if="suffix" class="input-suffixed">
      <slot :id="id" :describedby="describedby" :invalid="Boolean(error)" />
      <span class="input-suffix" aria-hidden="true">{{ suffix }}</span>
    </div>
    <slot v-else :id="id" :describedby="describedby" :invalid="Boolean(error)" />
    <p v-if="error" :id="errorId" class="field-error">{{ error }}</p>
    <p v-if="hint" :id="hintId" class="field-help">{{ hint }}</p>
  </div>
</template>
