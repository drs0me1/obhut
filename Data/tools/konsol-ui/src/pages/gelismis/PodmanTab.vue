<!-- Gelişmiş → Podman (DD-211): the base's container runtime and its resources (GET /api/konsol/konteynerler/
     liste), in sub-tabs in the address (?kaynak=imajlar|birimler|aglar). Images (name, id, size, age, who
     uses it) with "İmaj çek" for a fully qualified reference; volumes; bridge networks (driver, subnets,
     internal, who uses it, Konsol's or the system's). Only what nothing uses can be removed (the system's
     networks never), after the typed word. Every
     change is a job (POST …/islem → 202); its end arrives in the activity list, and the list is read again.
     A collection that could not be read says so instead of looking empty. The containers themselves are in
     Uygulamalar. The forms open over the page (?yeni=imaj|birim|ag). -->
<script setup lang="ts">
import { computed, onMounted, reactive, ref } from "vue";
import { RouterLink } from "vue-router";
import { Icon, type IconName } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import Tabs from "../../components/ui/Tabs.vue";
import {
  CIDR_RE,
  IMAGE_RE,
  RESOURCE_NAME_RE,
  readResources,
  startResourceJob,
  type Image,
  type Network,
  type ResourceJob,
  type Resources,
  type Volume,
} from "../../api/gelismis";
import { JobTimeout, waitForJob } from "../../jobs";
import { useLeaveGuard } from "../../leave";
import { useQueryParam } from "../../query";
import { UNKNOWN, bytes, clock, date } from "../../format";

type Action = ResourceJob["action"];
const DOING: Record<Action, string> = {
  "image-pull": "İmaj çekiliyor…", "image-remove": "İmaj siliniyor…", "volume-create": "Birim oluşturuluyor…",
  "volume-remove": "Birim siliniyor…", "network-create": "Ağ oluşturuluyor…", "network-remove": "Ağ siliniyor…",
};
const DONE: Record<Action, string> = {
  "image-pull": "imaj çekildi", "image-remove": "imaj silindi", "volume-create": "birim oluşturuldu",
  "volume-remove": "birim silindi", "network-create": "ağ oluşturuldu", "network-remove": "ağ silindi",
};
const FAILED: Record<Action, string> = {
  "image-pull": "İmaj çekilemedi", "image-remove": "İmaj silinemedi", "volume-create": "Birim oluşturulamadı",
  "volume-remove": "Birim silinemedi", "network-create": "Ağ oluşturulamadı", "network-remove": "Ağ silinemedi",
};

// ---- the list
const list = ref<Resources | null>(null);
const listError = ref("");
const loading = ref(false);
const readAt = ref(0);

async function load(): Promise<void> {
  loading.value = true;
  try {
    list.value = await readResources();
    listError.value = "";
    readAt.value = Date.now() / 1000;
  } catch (err) {
    listError.value = err instanceof Error ? err.message : String(err);
  } finally {
    loading.value = false;
  }
}
onMounted(() => void load());

const runtimeOk = computed(() => list.value?.runtime.ok === true);
const LABELS = { images: "İmajlar", volumes: "Birimler", networks: "Ağlar" } as const;
function collectionError(key: keyof typeof LABELS): string {
  const l = list.value;
  if (!l) return "";
  if (!l.runtime.ok) return l.runtime.error || "Podman yanıt vermedi.";
  return l.errors[key] || (l[key] === null ? `${LABELS[key]} okunamadı.` : "");
}
const count = (key: keyof typeof LABELS) => (collectionError(key) ? "okunamadı" : list.value?.[key] ? `${list.value[key]!.length}` : "");
const TABS = computed(() => [
  { id: "imajlar", label: "İmajlar", hint: count("images") },
  { id: "birimler", label: "Birimler", hint: count("volumes") },
  { id: "aglar", label: "Ağlar", hint: count("networks") },
]);

// ---- jobs: one at a time per target; the row shows its step until the job ends
const busy = reactive(new Map<string, string>());
const note = ref("");
const failure = ref("");

/** Follows a started job to its end; true when it succeeded. */
async function follow(id: string, action: Action, target: string, label: string): Promise<{ ok: boolean; text: string }> {
  busy.set(target, DOING[action]);
  try {
    const end = await waitForJob("konteyner", id, (j) => busy.set(target, j.adim || DOING[action]));
    if (end.durum === "tamam") return { ok: true, text: `${label}: ${DONE[action]}.` };
    return { ok: false, text: `${label}: ${FAILED[action]}: ${end.adim || "nedeni bildirilmedi"}` };
  } catch (err) {
    return { ok: false, text: `${label}: ${err instanceof JobTimeout ? err.message : err instanceof Error ? err.message : String(err)}` };
  } finally {
    busy.delete(target);
    void load();
  }
}

function report(result: { ok: boolean; text: string }): void {
  if (result.ok) {
    note.value = result.text;
    failure.value = "";
  } else {
    failure.value = result.text;
    note.value = "";
  }
}

// ---- rows
const shortId = (id: string) => id.replace(/^sha256:/, "").slice(0, 12);
// A digest-pinned name shows the digest's first 12 characters; the whole name stays the row's label.
const shortImage = (name: string) => name.replace(/@sha256:([0-9a-f]{12})[0-9a-f]+$/, "@sha256:$1…");
const users = (u: string[]) => u.join(", ");

function imageBlock(i: Image): string {
  if (!i.managed) return "Konsol bu imajı yönetmiyor.";
  if (i.used_by.length) return `Kullanımda: ${users(i.used_by)}. Önce konteyneri kaldırın.`;
  if (!i.id) return "İmajın kimliği okunamadı.";
  return "";
}
function volumeBlock(v: Volume): string {
  return v.used_by.length ? `Kullanımda: ${users(v.used_by)}. Önce konteyneri kaldırın.` : "";
}
function networkBlock(n: Network): string {
  if (!n.managed) return "Konsol yönetmiyor; silinemez.";
  if (n.used_by.length) return `Kullanımda: ${users(n.used_by)}.`;
  return "";
}
const imageKey = (i: Image) => "image:" + i.id;
const volumeKey = (v: Volume) => "volume:" + v.name;
const networkKey = (n: Network) => "network:" + n.name;

// ---- removal, after the typed word
interface Removal {
  target: string;
  label: string;
  title: string;
  description: string;
  items: [IconName, string][];
  go: string;
  request: ResourceJob;
}
const removal = ref<Removal | null>(null);
const removeTyped = ref(false);
const removeError = ref("");
const removing = ref(false);

function askRemoveImage(i: Image): void {
  removal.value = {
    target: imageKey(i), label: i.name, title: `${i.name} silinsin mi?`, description: "Kullanılmayan imaj", go: "İmajı sil",
    items: [["box", "İmaj sunucudan silinir; gerekirse yeniden çekilir."]], request: { action: "image-remove", image: i.id },
  };
}
function askRemoveVolume(v: Volume): void {
  removal.value = {
    target: volumeKey(v), label: v.name, title: `${v.name} silinsin mi?`, description: "Kullanılmayan birim", go: "Birimi sil",
    items: [["trash", "Birimdeki bütün veri kalıcı olarak silinir; geri alınamaz."]], request: { action: "volume-remove", name: v.name },
  };
}
function askRemoveNetwork(n: Network): void {
  removal.value = {
    target: networkKey(n), label: n.name, title: `${n.name} ağı silinsin mi?`, description: "Kullanılmayan köprü ağı", go: "Ağı sil",
    items: [["globe", "Ağ ve onun güvenlik duvarı kuralları kaldırılır."]], request: { action: "network-remove", name: n.name },
  };
}
function closeRemoval(): void {
  removal.value = null;
  removeError.value = "";
}

async function confirmRemove(): Promise<void> {
  const r = removal.value;
  if (!r || !removeTyped.value || removing.value) return;
  removing.value = true;
  removeError.value = "";
  try {
    const job = await startResourceJob(r.request);
    removal.value = null;
    note.value = "";
    failure.value = "";
    void follow(job.id, r.request.action, r.target, r.label).then(report);
  } catch (err) {
    removeError.value = err instanceof Error ? err.message : String(err);
  } finally {
    removing.value = false;
  }
}

// ---- the forms: pull an image, create a volume or a network
type Form = "imaj" | "birim" | "ag";
const formParam = useQueryParam<"" | Form>("yeni", ["", "imaj", "birim", "ag"], "");
const form = reactive({ image: "", name: "", subnet: "", internal: false });
const formTried = ref(false);
const formError = ref("");
const formSending = ref(false);
// The job the open sheet started: its step is shown in the sheet while it runs.
const formJob = ref<{ target: string; action: Action } | null>(null);
const formStep = computed(() => (formJob.value ? busy.get(formJob.value.target) ?? DOING[formJob.value.action] : ""));
// Each opening of the sheet is its own: a job sent from an earlier one reports to the page.
let formSeq = 0;
const FORMS: Record<Form, { title: string; description: string; go: string }> = {
  imaj: { title: "İmaj çek", description: "Bir kayıt defterinden tam adıyla.", go: "Çek" },
  birim: { title: "Yeni birim", description: "Podman'ın konteynerden bağımsız sakladığı adlı veri alanı.", go: "Oluştur" },
  ag: { title: "Yeni ağ", description: "Konteynerler için bir köprü ağı.", go: "Oluştur" },
};
const formText = computed(() => (formParam.value ? FORMS[formParam.value] : null));
const formErrors = computed(() => {
  const kind = formParam.value;
  const out = { image: "", name: "", subnet: "" };
  if (kind === "imaj" && !IMAGE_RE.test(form.image.trim())) out.image = "İmajın tam adını yazın: kayıt adresi, depo ve etiket (ör. docker.io/library/redis:7.4-alpine).";
  if (kind === "birim" && !RESOURCE_NAME_RE.test(form.name.trim())) out.name = "Birim adı küçük harf ya da rakamla başlar; küçük harf, rakam ve - _ . içerir.";
  if (kind === "ag") {
    if (!RESOURCE_NAME_RE.test(form.name.trim())) out.name = "Ağ adı küçük harf ya da rakamla başlar; küçük harf, rakam ve - _ . içerir.";
    else if (form.subnet.trim() && !CIDR_RE.test(form.subnet.trim())) out.subnet = "Alt ağı CIDR olarak yazın (ör. 10.89.5.0/24).";
  }
  return out;
});

function resetForm(): void {
  formSeq += 1;
  Object.assign(form, { image: "", name: "", subnet: "", internal: false });
  formTried.value = false;
  formError.value = "";
  formSending.value = false;
  formJob.value = null;
}
function openForm(kind: Form): void {
  resetForm();
  formParam.value = kind;
}
function closeForm(): void {
  formParam.value = "";
  resetForm();
}
// A form typed into is a draft until it is sent (a job that runs keeps going when the sheet closes).
useLeaveGuard(() => formParam.value !== "" && !formSending.value && Boolean(form.image.trim() || form.name.trim() || form.subnet.trim()));

async function submitForm(): Promise<void> {
  const kind = formParam.value;
  if (!kind || formSending.value) return;
  formTried.value = true;
  const e = formErrors.value;
  if (e.image || e.name || e.subnet) return;
  const request: ResourceJob =
    kind === "imaj" ? { action: "image-pull", image: form.image.trim() }
    : kind === "birim" ? { action: "volume-create", name: form.name.trim() }
    : { action: "network-create", name: form.name.trim(), subnet: form.subnet.trim(), internal: form.internal };
  const label = request.action === "image-pull" ? request.image : request.name;
  const target = (kind === "imaj" ? "image:" : kind === "birim" ? "volume:" : "network:") + label;
  const mine = formSeq;
  const current = () => mine === formSeq;
  formSending.value = true;
  formError.value = "";
  formJob.value = { target, action: request.action };
  note.value = "";
  failure.value = "";
  let job: { id: string };
  try {
    job = await startResourceJob(request);
  } catch (err) {
    if (current()) {
      formError.value = err instanceof Error ? err.message : String(err);
      formSending.value = false;
      formJob.value = null;
    } else report({ ok: false, text: `${label}: ${err instanceof Error ? err.message : String(err)}` });
    return;
  }
  const result = await follow(job.id, request.action, target, label);
  if (!current()) {
    report(result);
    return;
  }
  formSending.value = false;
  formJob.value = null;
  if (result.ok) {
    closeForm();
    report(result);
  } else formError.value = result.text;
}
</script>

<template>
  <div class="advanced-tab podman" data-testid="podman">
    <section class="card podman-runtime" aria-labelledby="podman-baslik" data-testid="podman-runtime">
      <div class="card-head">
        <h2 id="podman-baslik" class="card-title">Podman</h2>
        <div class="card-actions">
          <span v-if="readAt" class="meter-note">Son okuma {{ clock(readAt) }}</span>
          <button type="button" class="btn btn-secondary btn-sm" :disabled="loading" data-testid="podman-refresh" @click="load"><Icon name="refresh" :size="16" />Yenile</button>
        </div>
      </div>
      <p v-if="listError" class="form-error" role="alert" data-testid="podman-error">{{ list ? `Son okuma başarısız: ${listError}` : listError }}</p>
      <template v-if="list">
        <div v-if="list.runtime.ok" class="podman-facts">
          <StatusPill tone="ok" dot>Çalışıyor</StatusPill>
          <dl class="facts">
            <dt>Sürüm</dt>
            <dd>Podman {{ list.runtime.version || UNKNOWN }} · bu sunucu, rootful, systemd ile yönetilir</dd>
            <dt>Depolama</dt>
            <dd>{{ list.storage.size === null ? UNKNOWN : bytes(list.storage.size) }}</dd>
          </dl>
        </div>
        <p v-else class="notice notice-danger" role="alert" data-testid="podman-runtime-error">
          <Icon name="xcircle" class="notice-icon" /><span>{{ list.runtime.error || "Podman yanıt vermedi." }}</span>
        </p>
        <p class="meter-note">Konteynerler <RouterLink to="/uygulamalar">Uygulamalar</RouterLink>'dadır; burada imajlar, birimler ve ağlar yönetilir.</p>
      </template>
      <p v-else-if="!listError" class="meter-note" role="status">Okunuyor…</p>
    </section>

    <p class="sr-only" role="status">{{ note }}</p>
    <p v-if="note" class="notice notice-ok" aria-hidden="true" data-testid="podman-done"><Icon name="check" class="notice-icon" /><span>{{ note }}</span></p>
    <p v-if="failure" class="notice notice-danger" role="alert" data-testid="podman-failed"><Icon name="xcircle" class="notice-icon" /><span>{{ failure }}</span></p>

    <Tabs v-if="list" :tabs="TABS" label="Podman kaynakları" param="kaynak">
      <template #default="{ active }">
        <!-- images -->
        <section v-if="active === 'imajlar'" class="card resource-card" aria-label="İmajlar" data-testid="images">
          <div class="resource-head">
            <p class="meter-note">Yalnız Konsol'un yönettiği ve hiçbir konteynerin kullanmadığı imajlar silinir.</p>
            <button type="button" class="btn btn-primary btn-sm" :disabled="!runtimeOk" data-testid="image-pull" @click="openForm('imaj')"><Icon name="download" :size="16" />İmaj çek</button>
          </div>
          <p v-if="collectionError('images')" class="notice notice-warning" role="alert" data-testid="images-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("images") }}</span></p>
          <div v-else-if="list.images?.length" class="table-wrap">
            <table class="data-table resource-table">
              <thead>
                <tr><th scope="col">İmaj</th><th scope="col">Kimlik</th><th scope="col">Boyut</th><th scope="col">Oluşturma</th><th scope="col">Kullanan</th><th scope="col"><span class="sr-only">Eylemler</span></th></tr>
              </thead>
              <tbody>
                <tr v-for="(i, n) in list.images" :key="`${i.id}:${i.name}:${n}`" :data-imaj="i.name">
                  <th scope="row" class="col-main">
                    <strong class="mono wrap"><span aria-hidden="true">{{ shortImage(i.name) }}</span><span class="sr-only">{{ i.name }}</span></strong>
                    <span v-if="imageBlock(i)" :id="`imaj-engel-${n}`" class="cell-note">{{ imageBlock(i) }}</span>
                  </th>
                  <td data-label="Kimlik" class="mono">{{ shortId(i.id) || UNKNOWN }}</td>
                  <td data-label="Boyut" class="nowrap">{{ bytes(i.size) }}</td>
                  <td data-label="Oluşturma" class="nowrap">{{ date(i.created) }}</td>
                  <td data-label="Kullanan"><span :class="{ muted: !i.used_by.length }">{{ i.used_by.length ? users(i.used_by) : "kullanılmıyor" }}</span></td>
                  <td class="col-act">
                    <span v-if="busy.get(imageKey(i))" class="cell-note busy-note" data-testid="row-busy">{{ busy.get(imageKey(i)) }}</span>
                    <template v-else>
                      <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="Boolean(imageBlock(i)) || !runtimeOk" :aria-label="`${i.name} imajını sil`"
                        :aria-describedby="imageBlock(i) ? `imaj-engel-${n}` : undefined" data-eylem="sil" @click="askRemoveImage(i)">
                        <Icon name="trash" :size="16" />Sil
                      </button>
                    </template>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="İmaj yok" text="Bir uygulama kurulunca ya da bir imaj çekilince burada görünür." icon="box" />
        </section>

        <!-- volumes -->
        <section v-else-if="active === 'birimler'" class="card resource-card" aria-label="Birimler" data-testid="volumes">
          <div class="resource-head">
            <p class="meter-note">Birim (volume), Podman'ın konteynerden bağımsız sakladığı adlı veri alanıdır: konteyner kaldırılınca kalır, yalnız burada açıkça silinir. Sunucu klasörleri Dosyalar'dadır.</p>
            <button type="button" class="btn btn-primary btn-sm" :disabled="!runtimeOk" data-testid="volume-create" @click="openForm('birim')"><Icon name="plus" :size="16" />Yeni birim</button>
          </div>
          <p v-if="collectionError('volumes')" class="notice notice-warning" role="alert" data-testid="volumes-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("volumes") }}</span></p>
          <div v-else-if="list.volumes?.length" class="table-wrap">
            <table class="data-table resource-table">
              <thead>
                <tr><th scope="col">Birim</th><th scope="col">Sürücü</th><th scope="col">Boyut</th><th scope="col">Kullanan</th><th scope="col"><span class="sr-only">Eylemler</span></th></tr>
              </thead>
              <tbody>
                <tr v-for="v in list.volumes" :key="v.name" :data-birim="v.name">
                  <th scope="row" class="col-main">
                    <strong class="mono wrap">{{ v.name }}</strong>
                    <span class="badges"><StatusPill :tone="v.managed ? 'ok' : 'neutral'">{{ v.managed ? "Konsol" : "Dışarıda" }}</StatusPill></span>
                    <span v-if="volumeBlock(v)" :id="`birim-engel-${v.name}`" class="cell-note">{{ volumeBlock(v) }}</span>
                  </th>
                  <td data-label="Sürücü">{{ v.driver || UNKNOWN }}</td>
                  <td data-label="Boyut">{{ bytes(v.size) }}</td>
                  <td data-label="Kullanan"><span :class="{ 'warn-text': !v.used_by.length }">{{ v.used_by.length ? users(v.used_by) : "kullanılmıyor" }}</span></td>
                  <td class="col-act">
                    <span v-if="busy.get(volumeKey(v))" class="cell-note busy-note" data-testid="row-busy">{{ busy.get(volumeKey(v)) }}</span>
                    <template v-else>
                      <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="Boolean(volumeBlock(v)) || !runtimeOk" :aria-label="`${v.name} birimini sil`"
                        :aria-describedby="volumeBlock(v) ? `birim-engel-${v.name}` : undefined" data-eylem="sil" @click="askRemoveVolume(v)">
                        <Icon name="trash" :size="16" />Sil
                      </button>
                    </template>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="Birim yok" text="Bir konteyner adlı bir birim kullanınca ya da burada oluşturulunca görünür." icon="box" />
        </section>

        <!-- networks -->
        <section v-else-if="active === 'aglar'" class="card resource-card" aria-label="Ağlar" data-testid="networks">
          <div class="resource-head">
            <p class="meter-note">Köprü ağlarındaki portlar seçilen erişime göre açılır; sunucu ağını (host) kullanan uygulamalar port eşlemesi kullanmaz. Yalnız köprü ağı oluşturulur.</p>
            <button type="button" class="btn btn-primary btn-sm" :disabled="!runtimeOk" data-testid="network-create" @click="openForm('ag')"><Icon name="plus" :size="16" />Yeni ağ</button>
          </div>
          <p v-if="collectionError('networks')" class="notice notice-warning" role="alert" data-testid="networks-error"><Icon name="alert" class="notice-icon" /><span>{{ collectionError("networks") }}</span></p>
          <div v-else-if="list.networks?.length" class="table-wrap">
            <table class="data-table resource-table">
              <thead>
                <tr><th scope="col">Ağ</th><th scope="col">Sürücü</th><th scope="col">Alt ağ</th><th scope="col">Kullanan</th><th scope="col"><span class="sr-only">Eylemler</span></th></tr>
              </thead>
              <tbody>
                <tr v-for="net in list.networks" :key="net.name" :data-ag="net.name">
                  <th scope="row" class="col-main">
                    <strong class="mono wrap">{{ net.name }}</strong>
                    <span class="badges">
                      <StatusPill :tone="net.managed ? 'ok' : 'neutral'">{{ net.managed ? "Konsol" : "Sistem" }}</StatusPill>
                      <StatusPill v-if="net.internal" tone="accent">İç ağ</StatusPill>
                    </span>
                    <span v-if="networkBlock(net)" :id="`ag-engel-${net.name}`" class="cell-note">{{ networkBlock(net) }}</span>
                  </th>
                  <td data-label="Sürücü">{{ net.driver || UNKNOWN }}</td>
                  <td data-label="Alt ağ" class="mono wrap">{{ net.subnets.join(", ") || UNKNOWN }}</td>
                  <td data-label="Kullanan">{{ net.used_by.length ? users(net.used_by) : UNKNOWN }}</td>
                  <td class="col-act">
                    <span v-if="busy.get(networkKey(net))" class="cell-note busy-note" data-testid="row-busy">{{ busy.get(networkKey(net)) }}</span>
                    <template v-else>
                      <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="Boolean(networkBlock(net)) || !runtimeOk" :aria-label="`${net.name} ağını sil`"
                        :aria-describedby="networkBlock(net) ? `ag-engel-${net.name}` : undefined" data-eylem="sil" @click="askRemoveNetwork(net)">
                        <Icon name="trash" :size="16" />Sil
                      </button>
                    </template>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
          <EmptyState v-else title="Ağ yok" icon="globe" />
        </section>
      </template>
    </Tabs>

    <Modal :open="removal !== null" :title="removal?.title ?? ''" :description="removal?.description" @close="closeRemoval">
      <ul v-if="removal" class="modal-list">
        <li v-for="(item, i) in removal.items" :key="i"><Icon :name="item[0]" :size="18" /><span>{{ item[1] }}</span></li>
      </ul>
      <ConfirmWord v-model:confirmed="removeTyped" />
      <p v-if="removeError" class="form-error" role="alert" data-testid="remove-error">{{ removeError }}</p>
      <template #actions>
        <button type="button" class="btn btn-secondary" :disabled="removing" @click="closeRemoval">Vazgeç</button>
        <button type="button" class="btn btn-danger" :disabled="!removeTyped || removing" data-testid="remove-go" @click="confirmRemove">{{ removing ? "Gönderiliyor…" : removal?.go }}</button>
      </template>
    </Modal>

    <Modal :open="formText !== null" variant="sheet" :title="formText?.title ?? ''" :description="formText?.description" @close="closeForm">
      <form id="podman-formu" class="form-stack" novalidate @submit.prevent="submitForm">
        <Field v-if="formParam === 'imaj'" v-slot="{ id, describedby, invalid }" label="İmaj" hint="İndirme sunucuda sürer; pencereyi kapatabilirsiniz." :error="formTried ? formErrors.image : ''">
          <input :id="id" v-model="form.image" class="input mono" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" maxlength="300"
            placeholder="docker.io/library/redis:7.4-alpine" :disabled="formSending" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
        </Field>
        <template v-else>
          <Field v-slot="{ id, describedby, invalid }" :label="formParam === 'ag' ? 'Ağ adı' : 'Birim adı'" :error="formTried ? formErrors.name : ''">
            <input :id="id" v-model="form.name" class="input mono" type="text" autocomplete="off" autocapitalize="none" spellcheck="false" maxlength="63"
              :placeholder="formParam === 'ag' ? 'ornek-ag' : 'ornek-veri'" :disabled="formSending" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
          </Field>
          <template v-if="formParam === 'ag'">
            <Field v-slot="{ id, describedby, invalid }" label="Alt ağ" optional hint="Boşsa Podman boş bir aralık seçer." :error="formTried ? formErrors.subnet : ''">
              <input :id="id" v-model="form.subnet" class="input mono" type="text" autocomplete="off" spellcheck="false" maxlength="18" placeholder="10.89.5.0/24"
                :disabled="formSending" :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
            </Field>
            <label class="check-option check-option-calm">
              <input v-model="form.internal" type="checkbox" :disabled="formSending" />
              <span><strong>İç ağ</strong><small>Konteynerler birbirine ulaşır, dışarıya çıkamaz.</small></span>
            </label>
          </template>
        </template>
        <p v-if="formSending" class="job-progress" role="status" data-testid="form-progress"><span class="spinner" aria-hidden="true"></span><span>{{ formStep }}</span></p>
        <p v-if="formError" class="form-error" role="alert" data-testid="form-error">{{ formError }}</p>
      </form>
      <template #actions>
        <button type="button" class="btn btn-secondary" @click="closeForm">{{ formSending ? "Kapat" : "Vazgeç" }}</button>
        <button type="submit" form="podman-formu" class="btn btn-primary" :disabled="formSending" data-testid="form-go">{{ formText?.go }}</button>
      </template>
    </Modal>
  </div>
</template>
