<!-- "Var olanı yönetime al" (phase 4a; the Podman page's "Sahiplen", DD-211): a sheet over Uygulamalar,
     ?ekle=sahiplen. The containers made outside Konsol (GET …/konteynerler/liste, source "external"), each
     adoptable only when the server offers "adopt" (otherwise its reason). Choosing one (&ad=<name>) asks the
     server for a preview (POST …/islem {action:"adopt", name, preview:true}; the job's record carries
     {config, unsupported, fingerprint}); nothing changes before the confirmation. The operator chooses the
     network, each published port's scope (an internet port with its acknowledgement), the account (a
     writable server folder needs the Files account) and whether it starts afterwards, then types "onayla":
     POST {action:"adopt", name, preview_fingerprint, config, start, confirm:true}. The container is re-created
     once under a Konsol unit; when that job is done its application page opens. Options the server cannot
     carry over ("unsupported") block the adoption and are listed. -->
<script setup lang="ts">
import { computed, onBeforeUnmount, ref, watch } from "vue";
import { useRouter } from "vue-router";
import { Icon } from "../../components/icons";
import ConfirmWord from "../../components/ui/ConfirmWord.vue";
import EmptyState from "../../components/ui/EmptyState.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import StatusPill from "../../components/ui/StatusPill.vue";
import { ACCOUNT_RULE, DEFAULT_NETWORK, PUBLIC_RISK, RESTART_TEXT, SCOPE_TEXT, USER_TEXT, draftFrom, networkChoices, portsOut, writesFolder, type Draft } from "./container";
import { followJob } from "./follow";
import { message, useQueryText } from "./flows";
import { isGenericConfig, readInventory, readOperation, startContainerAction, type ContainerConfig, type Inventory } from "../../api/podman";
import { refreshApps } from "../../live";
import { appRoute } from "../../router";
import { updateQuery } from "../../query";
import { isObject } from "../../api/konsol";

const router = useRouter();
const flow = useQueryText("ekle");
const name = useQueryText("ad");
const open = computed(() => flow.value === "sahiplen");

const inventory = ref<Inventory | null>(null);
const inventoryError = ref("");
interface Preview {
  config: ContainerConfig;
  unsupported: string[];
  fingerprint: string;
}
const preview = ref<Preview | null>(null);
const previewState = ref<"" | "running" | "failed">("");
const previewError = ref("");
const draft = ref<Draft | null>(null);
const start = ref(true);
const confirmed = ref(false);
const tried = ref(false);
const run = ref<{ state: "sending" | "running" | "failed"; step: string; error: string } | null>(null);
let following: { stop: () => void } | null = null;
let seq = 0;

function stop(): void {
  following?.stop();
  following = null;
}

async function load(): Promise<void> {
  const mine = ++seq;
  try {
    const value = await readInventory();
    if (mine !== seq) return;
    inventory.value = value;
    inventoryError.value = "";
  } catch (err) {
    if (mine === seq) inventoryError.value = message(err);
  }
}

function resetPreview(): void {
  stop();
  preview.value = null;
  previewState.value = "";
  previewError.value = "";
  draft.value = null;
  confirmed.value = false;
  tried.value = false;
  run.value = null;
}

watch(
  open,
  (on) => {
    resetPreview();
    if (on) void load();
    else {
      seq += 1;
      inventory.value = null;
    }
  },
  { immediate: true },
);
onBeforeUnmount(stop);

const externals = computed(() => (inventory.value?.containers ?? []).filter((c) => c.source === "external"));
const chosen = computed(() => externals.value.find((c) => c.name === name.value) ?? null);
const networks = computed(() => networkChoices(inventory.value));

// A chosen container gets its preview once the inventory is known.
watch(
  () => [open.value, name.value, Boolean(inventory.value)] as const,
  ([on, which, known]) => {
    resetPreview();
    if (on && which && known && chosen.value?.actions.includes("adopt")) void askPreview();
  },
);

async function askPreview(): Promise<void> {
  const target = name.value;
  previewState.value = "running";
  previewError.value = "";
  try {
    const { id } = await startContainerAction({ action: "adopt", name: target, preview: true });
    const f = followJob("konteyner", id);
    following = f;
    const job = await f.done;
    following = null;
    if (name.value !== target) return;
    if (job.durum === "hata") throw new Error(job.adim || "Önizleme hazırlanamadı.");
    const op = await readOperation(id);
    const pv = op.result && isObject(op.result.preview) ? op.result.preview : null;
    if (!pv || !isGenericConfig(pv.config)) throw new Error("Sunucu önizleme döndürmedi; yeniden deneyin.");
    preview.value = {
      config: pv.config,
      unsupported: Array.isArray(pv.unsupported) ? pv.unsupported.map(String) : [],
      fingerprint: typeof pv.fingerprint === "string" ? pv.fingerprint : "",
    };
    const d = draftFrom(pv.config);
    // Every port's scope is chosen again here: the current one is only shown.
    for (const p of d.ports) {
      p.current = p.scope;
      p.scope = "";
      p.ack = false;
      p.wasPublic = false;
    }
    if (!networks.value.some((n) => n.value === d.network)) d.network = DEFAULT_NETWORK;
    draft.value = d;
    start.value = chosen.value?.state === "running";
    previewState.value = "";
  } catch (err) {
    if (name.value !== target) return;
    following = null;
    previewState.value = "failed";
    previewError.value = message(err);
  }
}

const missing = computed(() => Boolean(draft.value?.ports.some((p) => !p.scope || (p.scope === "public" && !p.ack))));
const accountProblem = computed(() => Boolean(draft.value && draft.value.user !== "downloads" && writesFolder(draft.value)));
const unsupported = computed(() => preview.value?.unsupported ?? []);
const blocked = computed(() => !draft.value || unsupported.value.length > 0 || missing.value || accountProblem.value || !confirmed.value);
const why = computed(() => {
  if (unsupported.value.length) return "Desteklenmeyen seçenek varken yönetime alınmaz.";
  if (missing.value) return "Her portun erişimini seçin.";
  if (accountProblem.value) return "Hesabı ya da klasörü düzeltin.";
  if (!confirmed.value) return "Onay sözcüğünü yazın.";
  return "";
});

async function adopt(): Promise<void> {
  tried.value = true;
  const d = draft.value;
  const pv = preview.value;
  if (blocked.value || !d || !pv || run.value?.state === "running" || run.value?.state === "sending") return;
  const target = name.value;
  const config = { ...pv.config, network: d.network, user: d.user, ports: portsOut(d.ports) };
  run.value = { state: "sending", step: "", error: "" };
  const current = run.value;
  let id = "";
  try {
    id = (await startContainerAction({ action: "adopt", name: target, preview_fingerprint: pv.fingerprint, config, start: start.value, confirm: true })).id;
  } catch (err) {
    current.state = "failed";
    current.error = message(err);
    return;
  }
  current.state = "running";
  current.step = "Konteyner Konsol tanımıyla yeniden oluşturuluyor…";
  void refreshApps();
  const f = followJob("konteyner", id, (job) => {
    if (job.adim) current.step = job.adim;
  });
  following = f;
  try {
    const job = await f.done;
    following = null;
    if (job.durum === "hata") {
      current.state = "failed";
      current.error = job.adim ? `Yönetime alınamadı: ${job.adim}` : "Yönetime alınamadı.";
      return;
    }
  } catch (err) {
    following = null;
    current.state = "failed";
    current.error = message(err);
    return;
  }
  await refreshApps();
  void router.push(appRoute("konteyner:" + target));
}

function choose(which: string): void {
  updateQuery(router, { ad: which });
}

const busy = computed(() => run.value?.state === "sending" || run.value?.state === "running");

function back(): void {
  if (busy.value) return;
  if (name.value) updateQuery(router, { ad: null });
  else close();
}

function close(): void {
  if (run.value?.state === "sending") return;
  stop();
  updateQuery(router, { ekle: null, ad: null });
}

const currentScope = (scope: string) => SCOPE_TEXT[scope] ?? (scope || "bilinmiyor");
const USERS = Object.entries(USER_TEXT) as [Draft["user"], string][];
const title = computed(() => (name.value ? `${name.value} · yönetime al` : "Var olanı yönetime al"));
</script>

<template>
  <Modal :open="open" variant="sheet" :title="title" description="Konsol dışında kurulmuş bir konteyner Konsol tanımına dönüşür; erişimini siz seçersiniz." @close="close">
    <div class="flow-step uyg-wide" data-testid="adopt-flow">
      <p v-if="inventoryError" class="form-error" role="alert">{{ inventoryError }}</p>
      <p v-else-if="!inventory" class="meter-note" role="status">Podman okunuyor…</p>

      <!-- which one -->
      <template v-else-if="!name">
        <fieldset v-if="externals.length" class="choice-list">
          <legend class="field-label">Hangi konteyner?</legend>
          <div v-for="c in externals" :key="c.name" class="choice-item" :class="{ 'choice-off': !c.actions.includes('adopt') }" :data-konteyner="c.name">
            <span class="choice-text">
              <span class="choice-head"><strong>{{ c.name }}</strong><span class="muted mono">{{ c.image }}</span></span>
              <span class="choice-sub">{{ c.state === "running" ? "Çalışıyor" : "Durmuş" }}{{ c.ports.length ? ` · ${c.ports.length} port` : "" }}</span>
              <span v-if="!c.actions.includes('adopt')" class="choice-sub warn-text">{{ c.restricted_reason || "Sunucu bu konteyneri yönetime almıyor." }}</span>
            </span>
            <button v-if="c.actions.includes('adopt')" type="button" class="btn btn-secondary btn-sm" :aria-label="`${c.name}: önizle`" @click="choose(c.name)">Önizle</button>
          </div>
        </fieldset>
        <EmptyState v-else title="Konsol dışında kurulmuş konteyner yok" text="Podman'da başka bir araçla oluşturulan konteynerler burada görünür." icon="box" />
      </template>

      <!-- the preview and the choices -->
      <EmptyState v-else-if="!chosen" title="Bu ad Konsol dışında kurulmuş bir konteyner değil" icon="box">
        <button type="button" class="btn btn-secondary" @click="back">Listeye dön</button>
      </EmptyState>
      <p v-else-if="!chosen.actions.includes('adopt')" class="notice notice-warning" role="alert">
        <Icon name="lock" class="notice-icon" /><span>{{ chosen.restricted_reason || "Sunucu bu konteyneri yönetime almıyor." }}</span>
      </p>
      <p v-else-if="previewState === 'running'" class="meter-note" role="status" data-testid="adopt-waiting">Sunucu konteynerin ayarlarını okuyor; henüz hiçbir şey değişmedi…</p>
      <div v-else-if="previewState === 'failed'" class="plan-error">
        <p class="form-error" role="alert" data-testid="adopt-error">{{ previewError }}</p>
        <button type="button" class="btn btn-secondary btn-sm fit" @click="askPreview">Yeniden dene</button>
      </div>
      <template v-else-if="draft && preview">
        <p class="meter-note">Yönetime alınınca konteyner bir kez Konsol hizmetiyle yeniden oluşturulur: kısa bir kesinti olur ve yazılabilir katmanı silinir. Kalıcı veriler bağlamalarda kalır.</p>
        <div v-if="unsupported.length" class="notice notice-danger" role="alert" data-testid="adopt-unsupported">
          <Icon name="xcircle" class="notice-icon" />
          <div>
            <p class="notice-title">Yönetime alınamaz: desteklenmeyen seçenekler</p>
            <ul class="notice-list">
              <li v-for="(u, i) in unsupported" :key="i">{{ u }}</li>
            </ul>
          </div>
        </div>
        <section class="form-section" aria-label="Okunan ayarlar">
          <h3 class="form-section-title"><Icon name="box" :size="18" />Okunan ayarlar</h3>
          <dl class="facts" data-testid="adopt-read">
            <dt>İmaj</dt>
            <dd class="mono wrap">{{ draft.imageRef || "—" }}</dd>
            <dt>Ağ</dt>
            <dd class="mono">{{ chosen.network || "—" }}</dd>
            <dt>Bağlamalar</dt>
            <dd class="wrap">{{ draft.mounts.length ? draft.mounts.map((m) => `${m.source} → ${m.destination}${m.readOnly ? " (salt okunur)" : ""}`).join(", ") : "yok" }}</dd>
            <dt>Ortam</dt>
            <dd class="wrap">{{ draft.env.length ? draft.env.map((e) => e.name + (e.secret ? " (gizli)" : "")).join(", ") : "yok" }}</dd>
            <dt>Yeniden başlatma</dt>
            <dd>{{ RESTART_TEXT[draft.restart] }}</dd>
          </dl>
        </section>
        <section class="form-section" aria-label="Ağ ve portların erişimi">
          <h3 class="form-section-title"><Icon name="globe" :size="18" />Ağ ve portların erişimi</h3>
          <Field v-slot="{ id, describedby }" label="Ağ" :hint="`Şu an: ${chosen.network || 'bilinmiyor'}`">
            <select :id="id" v-model="draft.network" class="input" :aria-describedby="describedby" data-alan="network">
              <option v-for="n in networks" :key="n.value" :value="n.value">{{ n.label }}</option>
            </select>
          </Field>
          <p v-if="!draft.ports.length" class="meter-note">Yayımlanan port yok.</p>
          <ul v-else class="edit-rows" aria-label="Portlar">
            <li v-for="p in draft.ports" :key="p.key" class="edit-row adopt-row" :data-satir="'p' + p.key">
              <Field v-slot="{ id, describedby, invalid }" :label="`${p.host} → ${p.inner}/${p.protocol}`" :hint="`Şu an: ${currentScope(p.current)}`" :error="tried && !p.scope ? 'Erişimi seçin.' : ''">
                <select :id="id" v-model="p.scope" class="input" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="scope" @change="p.scope !== 'public' && (p.ack = false)">
                  <option value="">Erişimi seçin…</option>
                  <option value="local">Yalnız bu sunucu</option>
                  <option value="tailscale">Tailscale</option>
                  <option value="public">İnternet (herkese açık)</option>
                </select>
              </Field>
              <label v-if="p.scope === 'public'" class="check-option row-wide public-ack" data-alan="ack">
                <input v-model="p.ack" type="checkbox" />
                <span>
                  <strong>Bu portun internetten herkese açık kalacağını anlıyorum</strong>
                  <small>{{ PUBLIC_RISK }}</small>
                </span>
              </label>
            </li>
          </ul>
        </section>
        <section class="form-section" aria-label="Çalıştıran hesap">
          <h3 class="form-section-title"><Icon name="key" :size="18" />Çalıştıran hesap</h3>
          <Field v-slot="{ id, describedby, invalid }" label="Hesap" :hint="`Şu an: ${USER_TEXT[preview.config.user ?? 'image'] ?? 'bilinmiyor'}`" :error="accountProblem ? ACCOUNT_RULE : ''">
            <select :id="id" v-model="draft.user" class="input" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-alan="user">
              <option v-for="[value, label] in USERS" :key="value" :value="value">{{ label }}</option>
            </select>
          </Field>
        </section>
        <label class="check-option check-calm" data-testid="start-after">
          <input v-model="start" type="checkbox" />
          <span>
            <strong>Yönetime aldıktan sonra başlat</strong>
            <small>İşaretlemezseniz durmuş kalır.</small>
          </span>
        </label>
        <ConfirmWord v-if="!unsupported.length" v-model:confirmed="confirmed" />
        <div v-if="run && run.state !== 'sending'" class="flow-run" :data-durum="run.state" data-testid="adopt-run">
          <div class="flow-run-head">
            <strong>{{ chosen.name }}</strong>
            <StatusPill :tone="run.state === 'failed' ? 'danger' : 'accent'">{{ run.state === "failed" ? "Başarısız" : "Sürüyor…" }}</StatusPill>
          </div>
          <p v-if="run.state === 'running'" class="cell-note" role="status">{{ run.step }}</p>
          <p v-else class="form-error" role="alert" data-testid="adopt-error">{{ run.error }}</p>
        </div>
        <p v-if="why && tried" class="meter-note" role="status" data-testid="adopt-why">{{ why }}</p>
      </template>
    </div>
    <template #actions>
      <button type="button" class="btn btn-secondary" :disabled="busy" data-testid="adopt-back" @click="back">{{ name ? "Geri" : "Kapat" }}</button>
      <button v-if="name && draft" type="button" class="btn btn-primary" :disabled="busy || unsupported.length > 0" data-testid="adopt-go" @click="adopt">
        {{ run?.state === "sending" ? "Gönderiliyor…" : run?.state === "running" ? "Yönetime alınıyor…" : "Yönetime al" }}
      </button>
    </template>
  </Modal>
</template>
