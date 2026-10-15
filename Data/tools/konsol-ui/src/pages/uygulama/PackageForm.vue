<!-- A package's form (DD-210) drawn from its declaration (form.ts): text, a password with its repeat, a
     folder through the picker. "kur" starts from the declared defaults and sends every field; "ayar" starts
     from the package's current values, sends only what changed and keeps the stored password when the field
     is left blank. Checks run on the first submit and then as the operator types; the first invalid field
     gets the focus. The form holds its draft (the browser asks before a reload drops it) until the parent
     gives new `initial` values after a save. The buttons are the parent's: the default slot inside the form,
     or a submit button elsewhere with form="<formId>". -->
<script setup lang="ts">
import { computed, nextTick, reactive, ref, watch } from "vue";
import Field from "../../components/ui/Field.vue";
import FolderPicker from "../../components/ui/FolderPicker.vue";
import { useLeaveGuard } from "../../leave";
import { fieldProblem, type FormField, type PackageForm } from "./form";

const props = withDefaults(
  defineProps<{ form: PackageForm; mode: "kur" | "ayar"; formId: string; initial?: Record<string, unknown>; busy?: boolean; omit?: readonly string[] }>(),
  { initial: () => ({}), busy: false, omit: () => [] },
);
const emit = defineEmits<{ submit: [values: Record<string, string>] }>();

const install = computed(() => props.mode === "kur");
const fields = computed(() => props.form.fields.filter((f) => !props.omit.includes(f.ad)));
const values = reactive<Record<string, string>>({});
const repeats = reactive<Record<string, string>>({});
const start = reactive<Record<string, string>>({});
const tried = ref(false);
const note = ref("");
const root = ref<HTMLFormElement | null>(null);

function startValue(f: FormField): string {
  if (f.tur === "parola") return "";
  if (install.value) return f.varsayilan;
  const now = props.initial[f.ad];
  return typeof now === "string" ? now : "";
}

function reset(): void {
  for (const f of props.form.fields) {
    values[f.ad] = startValue(f);
    start[f.ad] = values[f.ad] ?? "";
    repeats[f.ad] = "";
  }
  tried.value = false;
  note.value = "";
}
watch(() => [props.form, props.initial, props.mode], reset, { immediate: true });

const problem = (f: FormField) => fieldProblem(f, values[f.ad] ?? "", repeats[f.ad] ?? "", install.value);
const errors = computed(() => Object.fromEntries(fields.value.map((f) => [f.ad, problem(f)])) as Record<string, string>);
const dirty = computed(() => fields.value.some((f) => (values[f.ad] ?? "") !== (start[f.ad] ?? "") || Boolean(repeats[f.ad])));
useLeaveGuard(dirty);

const hint = (f: FormField) => (f.tur === "parola" && !install.value ? f.ayarIpucu || f.ipucu : f.ipucu);

async function submit(): Promise<void> {
  if (props.busy) return;
  tried.value = true;
  note.value = "";
  if (fields.value.some((f) => errors.value[f.ad])) {
    await nextTick();
    root.value?.querySelector<HTMLElement>('[aria-invalid="true"]')?.focus();
    return;
  }
  const out: Record<string, string> = {};
  for (const f of fields.value) {
    const v = f.tur === "metin" ? (values[f.ad] ?? "").trim() : (values[f.ad] ?? "");
    if (install.value) out[f.ad] = v;
    else if (f.tur === "parola" ? v !== "" : v !== start[f.ad]) out[f.ad] = v;
  }
  if (!install.value && !Object.keys(out).length) {
    note.value = "Değişiklik yok.";
    return;
  }
  emit("submit", out);
}

defineExpose({ submit });
</script>

<template>
  <form :id="formId" ref="root" class="form-stack package-form" novalidate data-testid="package-form" @submit.prevent="submit">
    <template v-for="f in fields" :key="f.ad">
      <template v-if="f.tur === 'parola'">
        <Field v-slot="{ id, describedby, invalid }" :label="f.etiket" :hint="hint(f)" :error="tried ? errors[f.ad] : ''" :optional="!install">
          <input
            :id="id"
            v-model="values[f.ad]"
            class="input"
            type="password"
            autocomplete="new-password"
            :name="f.ad"
            :maxlength="f.enCok ?? undefined"
            :disabled="busy"
            :aria-describedby="describedby"
            :aria-invalid="invalid || undefined"
            :data-alan="f.ad"
          />
        </Field>
        <Field v-slot="{ id }" :label="`${f.etiket} (tekrar)`">
          <input :id="id" v-model="repeats[f.ad]" class="input" type="password" autocomplete="new-password" :name="f.ad + '-tekrar'" :disabled="busy" :data-alan="f.ad + '-tekrar'" />
        </Field>
      </template>
      <Field v-else-if="f.tur === 'klasor'" v-slot="{ id, describedby, invalid }" :label="f.etiket" :hint="hint(f)" :error="tried ? errors[f.ad] : ''">
        <FolderPicker :id="id" v-model="values[f.ad]" :name="f.etiket" :describedby="describedby" :invalid="invalid" :disabled="busy" :data-alan="f.ad" />
      </Field>
      <Field v-else v-slot="{ id, describedby, invalid }" :label="f.etiket" :hint="hint(f)" :error="tried ? errors[f.ad] : ''">
        <input
          :id="id"
          v-model="values[f.ad]"
          class="input"
          type="text"
          :name="f.ad"
          :maxlength="f.enCok ?? undefined"
          :autocomplete="f.ad === 'username' ? 'username' : 'off'"
          autocapitalize="none"
          spellcheck="false"
          :disabled="busy"
          :aria-describedby="describedby"
          :aria-invalid="invalid || undefined"
          :data-alan="f.ad"
        />
      </Field>
    </template>
    <p v-if="note" class="meter-note" role="status" data-testid="form-note">{{ note }}</p>
    <slot />
  </form>
</template>
