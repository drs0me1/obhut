<!-- A package's settings form (DD-210, settings mode): the same declared fields as its install form, the
     current values from the package's own API (GET /api/uygulama/<id><oku>; never a password), and only the
     changed fields to POST /api/uygulama/<id><yaz>, which saves at once (the package says in `ayar_not`
     what that does). A blank password keeps the stored one. Fields another card on the page already edits
     (`omit`, an App Store adapter's) are left out, so each setting has one place. -->
<script setup lang="ts">
import { computed, onMounted, ref, useId } from "vue";
import Card from "../../components/ui/Card.vue";
import PackageForm from "./PackageForm.vue";
import { readPackageSettings, writePackageSettings } from "../../api/uygulama";
import { refreshApps } from "../../live";
import { message } from "./flows";
import type { PackageForm as Form } from "./form";

const props = withDefaults(defineProps<{ packageId: string; form: Form; omit?: readonly string[]; elsewhere?: string }>(), { omit: () => [], elsewhere: "" });
const emit = defineEmits<{ saved: [] }>();

const formId = useId();
const current = ref<Record<string, unknown> | null>(null);
const readError = ref("");
const saving = ref(false);
const error = ref("");
const done = ref("");

async function load(): Promise<void> {
  try {
    current.value = await readPackageSettings(props.packageId, props.form.oku);
    readError.value = "";
  } catch (err) {
    readError.value = message(err);
  }
}
onMounted(load);

const omitted = computed(() => props.form.fields.filter((f) => props.omit.includes(f.ad)));
const shown = computed(() => props.form.fields.length > omitted.value.length);

async function save(values: Record<string, string>): Promise<void> {
  saving.value = true;
  error.value = "";
  done.value = "";
  try {
    await writePackageSettings(props.packageId, props.form.yaz, values);
    done.value = "Ayarlar kaydedildi.";
    await load();
    void refreshApps();
    emit("saved");
  } catch (err) {
    error.value = message(err);
  } finally {
    for (const key of Object.keys(values)) values[key] = "";
    saving.value = false;
  }
}
</script>

<template>
  <Card v-if="shown" :title="form.ayarBaslik || 'Uygulama ayarları'" data-testid="package-settings">
    <p v-if="form.ayarAlt" class="card-text muted">{{ form.ayarAlt }}</p>
    <p v-if="readError" class="form-error" role="alert">Ayarlar okunamadı: {{ readError }}</p>
    <p v-else-if="!current" class="meter-note">Okunuyor…</p>
    <PackageForm v-else :form-id="formId" mode="ayar" :form="form" :initial="current" :busy="saving" :omit="omit" @submit="save">
      <p v-if="omitted.length && elsewhere" class="meter-note">{{ omitted.map((f) => f.etiket).join(", ") }}: {{ elsewhere }}</p>
      <p v-if="form.ayarNot" class="meter-note" data-testid="settings-note">{{ form.ayarNot }}</p>
      <p v-if="error" class="form-error" role="alert" data-testid="settings-error">{{ error }}</p>
      <p v-if="done" class="notice notice-ok" role="status" data-testid="settings-done">{{ done }}</p>
      <div class="form-actions">
        <button type="submit" class="btn btn-primary" :disabled="saving" data-testid="settings-save">{{ saving ? "Kaydediliyor…" : "Kaydet" }}</button>
      </div>
    </PackageForm>
  </Card>
</template>
