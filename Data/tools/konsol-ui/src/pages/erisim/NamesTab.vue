<!-- Erişim → Yerel adlar (rebuild phase 5, A7; GET /api/konsol/adlar): the names the server's DNS answers under the
     local domain with who owns each, the operator's records, the forwarding of other names and the local domain.
     The managed names are read-only here: Konsol's, Paylaşımlar' and every application's name change in their own
     row in Adresler (linked from here). Records and forwarding are collected as a draft and saved through the plan
     review (they commit at once). The local domain change: plan, apply, then a 300 s confirmation from the new
     address. -->
<script setup lang="ts">
import { computed, onMounted, ref, watch } from "vue";
import { RouterLink } from "vue-router";
import { Icon } from "../../components/icons";
import Card from "../../components/ui/Card.vue";
import Field from "../../components/ui/Field.vue";
import Modal from "../../components/ui/Modal.vue";
import Switch from "../../components/ui/Switch.vue";
import SettingsPlanSheet from "./SettingsPlanSheet.vue";
import { readNames } from "../../api/erisim";
import { DOMAIN_RE } from "../../access";
import { accessRoute } from "../../sections";
import { live } from "../../live";
import { useLeaveGuard } from "../../leave";
import { tailnetKonsol, tailscaleAdmin } from "../../links";
import { UNKNOWN } from "../../format";
import type { Adlar, AyarIstegi, DnsKaydi, DnsTaslagi } from "../../api/sema";

const names = ref<Adlar | null>(null);
const namesError = ref("");

async function loadNames(): Promise<void> {
  try {
    names.value = await readNames();
    namesError.value = "";
  } catch (err) {
    namesError.value = err instanceof Error ? err.message : String(err);
  }
}

onMounted(() => void loadNames());
watch(() => live.ayarSurumu, () => void loadNames());

const locked = computed(() => Boolean(live.bekleyen));
const domain = computed(() => names.value?.alan || live.erisim?.alan || live.kaynaklar?.domain || "");
const tailscaleV4 = computed(() => live.erisim?.ozet.tailscale.ipv4 || live.kaynaklar?.net?.tailscale || "");

// ---- the plan sheet (DNS draft, the local domain)
interface Sheet {
  kind: "dns" | "alan";
  title: string;
  description: string;
  request: AyarIstegi;
  applyLabel: string;
}
const sheet = ref<Sheet | null>(null);
const note = ref("");

function applied(): void {
  const kind = sheet.value?.kind;
  sheet.value = null;
  if (kind === "dns") {
    draft.value = null;
    note.value = "Yerel adlar kaydedildi.";
  } else if (kind === "alan") {
    domainInput.value = "";
    domainTried.value = false;
    note.value = "Alan adı değişikliği uygulandı; yeni adresten 5 dakika içinde onaylayın.";
  }
}

// ---- the names, one row per name (its IPv4 and IPv6 answers together)
/** Who a name belongs to: Konsol, Paylaşımlar, an application (by its access row), the base, or its source. */
function ownerOf(name: string, kaynak: string, satir: string | null): string {
  if (satir === "panel") return "Konsol";
  if (name === `paylas.${domain.value}`) return "Paylaşımlar";
  const row = satir ? live.erisim?.hizmetler.find((h) => h.id === satir) : undefined;
  if (row?.uygulama) return row.uygulama;
  if (kaynak === "base") return "Temel";
  if (kaynak === "uygulama") return "Uygulama";
  return kaynak;
}

const nameRows = computed(() => {
  const out: { ad: string; hedef: string; sahibi: string; satir: string | null }[] = [];
  for (const a of names.value?.adlar ?? []) {
    let row = out.find((r) => r.ad === a.ad);
    if (!row) {
      row = { ad: a.ad, hedef: "", sahibi: ownerOf(a.ad, a.kaynak, a.satir), satir: a.satir };
      out.push(row);
    }
    const target = a.hedef === "tailscale" ? `Tailscale adresi${tailscaleV4.value ? " · " + tailscaleV4.value : ""}` : a.hedef;
    if (target && !row.hedef.includes(target)) row.hedef = row.hedef ? `${row.hedef} · ${target}` : target;
    row.satir ??= a.satir;
  }
  return out;
});
/** A managed name's own row in Adresler (Paylaşımlar' or an application's), or "" for Konsol's (always on). */
const nameRow = (r: { satir: string | null }) => (r.satir && r.satir !== "panel" ? r.satir : "");

const clone = <T,>(v: T): T => JSON.parse(JSON.stringify(v)) as T;
const savedDns = computed<DnsTaslagi | null>(() => {
  const n = names.value;
  if (!n) return null;
  return {
    records: n.kayitlar.map((r) => ({ name: r.name, target: r.target, enabled: r.enabled })),
    forward: n.yonlendirme,
    servers: [...n.sunucular],
  };
});
const draft = ref<DnsTaslagi | null>(null);
const dns = computed<DnsTaslagi | null>(() => draft.value ?? savedDns.value);
// The saved names changed under a draft (another tab, another change): the draft no longer fits them.
watch(savedDns, (now, before) => {
  if (draft.value && now && before && JSON.stringify(now) !== JSON.stringify(before)) draft.value = null;
});
const sameDns = (a: DnsTaslagi, b: DnsTaslagi) =>
  JSON.stringify([a.records, a.forward, a.servers]) === JSON.stringify([b.records, b.forward, b.servers]);
const dirty = computed(() => Boolean(draft.value && savedDns.value && !sameDns(draft.value, savedDns.value)));
const changes = computed(() => {
  const d = draft.value, s = savedDns.value;
  if (!d || !s) return 0;
  let n = 0;
  for (const r of d.records) {
    const old = s.records.find((x) => x.name === r.name);
    if (!old || JSON.stringify(old) !== JSON.stringify(r)) n += 1;
  }
  n += s.records.filter((r) => !d.records.some((x) => x.name === r.name)).length;
  if (d.forward !== s.forward || JSON.stringify(d.servers) !== JSON.stringify(s.servers)) n += 1;
  return n;
});

function editDraft(change: (d: DnsTaslagi) => void): void {
  const base = draft.value ?? (savedDns.value ? clone(savedDns.value) : null);
  if (!base) return;
  change(base);
  draft.value = savedDns.value && sameDns(base, savedDns.value) ? null : base;
}

function setRecord(name: string, on: boolean): void {
  editDraft((d) => {
    const r = d.records.find((x) => x.name === name);
    if (r) r.enabled = on;
  });
}

function dropRecord(name: string): void {
  editDraft((d) => {
    d.records = d.records.filter((x) => x.name !== name);
  });
}

function reviewDns(): void {
  if (!names.value || !draft.value) return;
  note.value = "";
  sheet.value = {
    kind: "dns",
    title: "Yerel ad değişiklikleri",
    description: "Uygulayınca hemen kaydedilir; dnsmasq yeniden başlar.",
    request: { revision: names.value.revizyon, dns: clone(draft.value) },
    applyLabel: "Uygula",
  };
}

// The operator's record: a name under the local domain, the Tailscale address or a fixed IP.
const recordOpen = ref(false);
const recordEditing = ref<string | null>(null);
const recordLabel = ref("");
const recordTarget = ref<"tailscale" | "ip">("tailscale");
const recordIp = ref("");
const recordTried = ref(false);
const LABEL_RE = /^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?(?:\.[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?)*$/;
const recordName = computed(() => {
  const text = recordLabel.value.trim().toLowerCase().replace(/\.$/, "");
  const suffix = "." + domain.value;
  return (text.endsWith(suffix) ? text.slice(0, -suffix.length) : text) + suffix;
});
const recordNameError = computed(() => {
  const label = recordName.value.slice(0, -(domain.value.length + 1));
  if (!label) return "Adı yazın (ör. yazici).";
  if (!LABEL_RE.test(label)) return "Küçük harf, rakam ve tire; noktayla ayrılmış parçalar.";
  const taken = nameRows.value.some((r) => r.ad === recordName.value) ||
    (dns.value?.records ?? []).some((r) => r.name === recordName.value && r.name !== recordEditing.value);
  return taken ? "Bu ad zaten kullanılıyor." : "";
});
const recordIpError = computed(() => {
  if (recordTarget.value !== "ip") return "";
  const ip = recordIp.value.trim();
  if (!ip) return "IPv4 ya da IPv6 adresini yazın.";
  return /^\d{1,3}(\.\d{1,3}){3}$/.test(ip) || /^[0-9a-f]*:[0-9a-f:.]*$/i.test(ip) ? "" : "Geçerli bir IPv4 ya da IPv6 adresi yazın.";
});

function openRecord(r: DnsKaydi | null): void {
  recordEditing.value = r?.name ?? null;
  recordLabel.value = r ? r.name.slice(0, -(domain.value.length + 1)) : "";
  recordTarget.value = r && r.target !== "tailscale" ? "ip" : "tailscale";
  recordIp.value = r && r.target !== "tailscale" ? r.target : "";
  recordTried.value = false;
  recordOpen.value = true;
}

function saveRecord(): void {
  recordTried.value = true;
  if (recordNameError.value || recordIpError.value) return;
  const value: DnsKaydi = { name: recordName.value, target: recordTarget.value === "tailscale" ? "tailscale" : recordIp.value.trim(), enabled: true };
  const editing = recordEditing.value;
  editDraft((d) => {
    const old = editing ? d.records.find((x) => x.name === editing) : undefined;
    if (old) {
      value.enabled = old.enabled;
      d.records = d.records.map((x) => (x.name === editing ? value : x));
    } else d.records.push(value);
  });
  recordOpen.value = false;
}

// Forwarding of other names: a provider's servers or the operator's own (at most four).
const PROVIDERS = [
  { id: "cloudflare", name: "Cloudflare", servers: ["1.1.1.1", "1.0.0.1"] },
  { id: "google", name: "Google", servers: ["8.8.8.8", "8.8.4.4"] },
  { id: "quad9", name: "Quad9", servers: ["9.9.9.9", "149.112.112.112"] },
] as const;
const provider = computed(() => {
  const servers = JSON.stringify(dns.value?.servers ?? []);
  return PROVIDERS.find((p) => JSON.stringify(p.servers) === servers)?.id ?? "ozel";
});
const customServers = ref("");
watch(
  () => dns.value?.servers,
  (servers) => {
    if (provider.value === "ozel") customServers.value = (servers ?? []).join(", ");
  },
  { immediate: true },
);
function setForward(on: boolean): void {
  editDraft((d) => {
    d.forward = on;
    if (on && !d.servers.length) d.servers = [...PROVIDERS[0].servers];
  });
}
function chooseProvider(id: string): void {
  const p = PROVIDERS.find((x) => x.id === id);
  editDraft((d) => {
    d.servers = p ? [...p.servers] : [];
  });
  if (!p) customServers.value = "";
}
function setCustomServers(): void {
  const list = customServers.value.split(",").map((x) => x.trim()).filter(Boolean).slice(0, 4);
  editDraft((d) => {
    d.servers = list;
  });
}
const serversError = computed(() => {
  const d = dns.value;
  if (!d?.forward) return "";
  if (!d.servers.length) return "Yönlendirme için en az bir DNS sunucusu seçin.";
  if (customServers.value.split(",").filter((x) => x.trim()).length > 4) return "En çok dört sunucu yazılabilir.";
  return "";
});

// ---- the local domain
const domainInput = ref("");
const domainTried = ref(false);
const newDomain = computed(() => domainInput.value.trim().toLowerCase());
const domainError = computed(() => {
  if (!newDomain.value) return "Yeni yerel alan adını yazın (ör. ev).";
  if (!DOMAIN_RE.test(newDomain.value)) return "Küçük harf, rakam ve tire; en çok 63 karakter, tireyle başlamaz ya da bitmez.";
  if (newDomain.value === domain.value) return "Yerel alan adı zaten bu değerde.";
  return "";
});
function reviewDomain(): void {
  domainTried.value = true;
  if (domainError.value || !names.value) return;
  note.value = "";
  sheet.value = {
    kind: "alan",
    title: "Yerel alan adı değişsin mi?",
    description: `${domain.value} → ${newDomain.value}`,
    request: { revision: names.value.revizyon, domain: newDomain.value },
    applyLabel: "Yerel alan adını değiştir",
  };
}
// Closing or reloading the browser tab with a DNS draft or a typed new domain asks first (DD-266).
useLeaveGuard(() => dirty.value || newDomain.value !== "");
const pendingDomain = computed(() => live.bekleyen?.domain ?? null);
const dnsAdmin = tailscaleAdmin("dns");
const pendingDomainNew = computed(() => (pendingDomain.value ? tailnetKonsol(pendingDomain.value.new, "#/erisim?sekme=adlar") : ""));
const sheetDomain = computed(() => (sheet.value?.kind === "alan" ? newDomain.value : ""));
const panelAddress = (d: string) => tailnetKonsol(d);
</script>

<template>
  <div class="access-tab names-tab" data-testid="local-names">
    <p class="sr-only" role="status">{{ note }}</p>
    <p v-if="note" class="action-note" aria-hidden="true" data-testid="names-note">{{ note }}</p>
    <p v-if="locked" class="notice" role="note" data-testid="names-locked">
      <Icon name="clock" class="notice-icon" />
      <span>Bekleyen bir ayar değişikliği var; onaylanana ya da geri alınana kadar yeni değişiklik uygulanamaz.</span>
    </p>

    <section class="card table-card" aria-labelledby="adlar-baslik" data-testid="names">
      <div class="card-head">
        <h2 id="adlar-baslik" class="card-title">Yerel adlar</h2>
        <button type="button" class="btn btn-secondary btn-sm" :disabled="locked || !names" data-testid="add-record" @click="openRecord(null)">
          <Icon name="plus" :size="16" />Kayıt ekle
        </button>
      </div>
      <p class="meter-note">.{{ domain || UNKNOWN }} altındaki adları sunucunun DNS'i yanıtlar. Konsol'un, Paylaşımlar'ın ve uygulamaların adları burada değişmez; kendi kayıtlarınızı ekleyip kapatabilirsiniz.</p>
      <p v-if="namesError" class="form-error" role="alert">{{ namesError }}</p>
      <ul v-if="names?.hatalar.length" class="notice-list">
        <li v-for="(x, i) in names.hatalar" :key="i" class="warn-text">{{ x }}</li>
      </ul>
      <div v-if="names" class="table-wrap">
        <table class="data-table names-table">
          <thead>
            <tr>
              <th scope="col">Ad</th>
              <th scope="col">Yanıt</th>
              <th scope="col">Sahibi</th>
              <th scope="col">Açık</th>
              <th scope="col"><span class="sr-only">Eylemler</span></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="r in nameRows" :key="r.ad" :data-ad="r.ad">
              <th scope="row" class="col-main"><strong class="mono">{{ r.ad }}</strong></th>
              <td data-label="Yanıt">{{ r.hedef || UNKNOWN }}</td>
              <td data-label="Sahibi">{{ r.sahibi }}</td>
              <td data-label="Açık">
                <span v-if="r.satir === 'panel'" class="lock-line" data-testid="name-locked"><Icon name="lock" :size="14" />Konsol'un adı</span>
                <span v-else-if="nameRow(r)" class="cell-stack">
                  <span class="lock-line"><Icon name="lock" :size="14" />Adresiyle açık</span>
                  <RouterLink :to="accessRoute('adresler', nameRow(r))" class="cell-note" data-testid="name-row">Adresler'de değişir</RouterLink>
                </span>
                <span v-else class="lock-line" data-testid="name-locked"><Icon name="lock" :size="14" />Salt okunur</span>
              </td>
              <td class="col-act"></td>
            </tr>
            <tr v-for="r in dns?.records ?? []" :key="'k:' + r.name" :data-kayit="r.name">
              <th scope="row" class="col-main"><strong class="mono">{{ r.name }}</strong></th>
              <td data-label="Yanıt">{{ r.target === "tailscale" ? `Tailscale adresi${tailscaleV4 ? " · " + tailscaleV4 : ""}` : `Sabit adres · ${r.target}` }}</td>
              <td data-label="Sahibi">Elle</td>
              <td data-label="Açık">
                <Switch :model-value="r.enabled" :label="`${r.name} açık`" hide-label :disabled="locked" @update:model-value="setRecord(r.name, $event)" />
              </td>
              <td class="col-act">
                <span class="row-actions">
                  <button type="button" class="btn btn-secondary btn-sm" :disabled="locked" :aria-label="`${r.name} kaydını düzenle`" @click="openRecord(r)">Düzenle</button>
                  <button type="button" class="btn btn-danger-quiet btn-sm" :disabled="locked" :aria-label="`${r.name} kaydını sil`" @click="dropRecord(r.name)">Sil</button>
                </span>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
      <p v-else-if="!namesError" class="meter-note">Okunuyor…</p>
    </section>

    <div class="names-grid">
      <section v-if="dns" class="card" aria-labelledby="diger-baslik" data-testid="forward">
        <div class="card-head">
          <h2 id="diger-baslik" class="card-title">Diğer adlar</h2>
          <Switch :model-value="dns.forward" label="Üst DNS'e gönder" hide-label :disabled="locked" @update:model-value="setForward" />
        </div>
        <p class="meter-note">.{{ domain }} dışındaki adlar {{ dns.forward ? "seçilen sunuculara sorulur" : "yanıtlanmaz" }}. .{{ domain }} içindeki adlar dışarı gönderilmez; bağlantı şifrelenmez (DoH/DoT yok).</p>
        <template v-if="dns.forward">
          <Field label="Sunucular" group>
            <div class="choice-chips" role="presentation">
              <label v-for="p in PROVIDERS" :key="p.id" class="choice-chip">
                <input type="radio" name="dns-saglayici" :value="p.id" :checked="provider === p.id" :disabled="locked" @change="chooseProvider(p.id)" />
                <span>{{ p.name }}</span>
              </label>
              <label class="choice-chip">
                <input type="radio" name="dns-saglayici" value="ozel" :checked="provider === 'ozel'" :disabled="locked" @change="chooseProvider('ozel')" />
                <span>Özel</span>
              </label>
            </div>
          </Field>
          <Field
            v-if="provider === 'ozel'"
            v-slot="{ id, describedby, invalid }"
            label="DNS sunucuları"
            hint="En çok dört genel DNS adresi; virgülle ayırın."
            :error="serversError"
          >
            <input :id="id" v-model="customServers" class="input" type="text" placeholder="1.1.1.1, 1.0.0.1" autocomplete="off" spellcheck="false"
              :aria-describedby="describedby" :aria-invalid="invalid || undefined" :disabled="locked" @change="setCustomServers" />
          </Field>
          <p v-else class="meter-note mono">{{ dns.servers.join(", ") }}</p>
        </template>
      </section>

      <Card title="Yerel alan adı" data-testid="domain">
        <p class="card-text">Geçerli: <span class="mono">panel.{{ domain || UNKNOWN }}</span>. Değişince bütün yerel adlar birlikte değişir; onay yeni adresten verilir. İnternet adları değişmez.</p>
        <div v-if="pendingDomain" class="notice" role="note" data-testid="domain-pending">
          <Icon name="clock" class="notice-icon" />
          <span>
            {{ pendingDomain.old }} → {{ pendingDomain.new }} bekliyor. Yeni Konsol'u açıp onaylayın:
            <a :href="pendingDomainNew" target="_blank" rel="noopener">panel.{{ pendingDomain.new }}</a>. Açılmazsa 5 dakika içinde eski ad geri gelir.
          </span>
        </div>
        <form class="domain-form" novalidate @submit.prevent="reviewDomain">
          <Field
            v-slot="{ id, describedby, invalid }"
            label="Yeni yerel alan adı"
            hint="Örn. ev · küçük harf, rakam ve tire."
            :error="domainTried ? domainError : ''"
          >
            <input :id="id" v-model="domainInput" class="input" type="text" maxlength="63" autocapitalize="none" autocomplete="off" spellcheck="false"
              :placeholder="domain" :aria-describedby="describedby" :aria-invalid="invalid || undefined" :disabled="locked || dirty" data-testid="domain-input" />
          </Field>
          <button type="submit" class="btn btn-secondary fit" :disabled="locked || dirty || !names" data-testid="review-domain">İncele</button>
        </form>
        <p v-if="dirty" class="meter-note warn-text">Yerel alan adını değiştirmeden önce yerel ad taslağını uygulayın ya da vazgeçin.</p>
        <details class="guide">
          <summary>Tailscale yönetim paneli · DNS tanımı</summary>
          <ol class="guide-steps">
            <li><a :href="dnsAdmin" target="_blank" rel="noopener noreferrer">Tailscale Admin → DNS</a> sayfasında Nameservers → Add nameserver → Custom seçin.</li>
            <li>Nameserver IP: <span class="mono">{{ tailscaleV4 || "Tailscale IP okunamadı" }}</span></li>
            <li>Restrict to search domain (Split DNS) seçeneğini açın. Alan adı: <span class="mono">{{ domain }}</span></li>
            <li>Save ile kaydedin. Bağlanan cihazda Tailscale DNS ayarlarını kullanma seçeneği açık olsun.</li>
          </ol>
        </details>
      </Card>
    </div>

    <!-- the draft bar -->
    <div v-if="dirty" class="draft-bar" role="region" aria-label="Taslak" data-testid="dns-draft">
      <div>
        <strong>{{ changes }} değişiklik kaydedilmedi</strong>
        <span class="meter-note">İnceleyip uygulayana kadar sunucu değişmez; uygulayınca hemen kaydedilir.</span>
      </div>
      <div class="draft-actions">
        <button type="button" class="btn btn-secondary" @click="draft = null">Vazgeç</button>
        <button type="button" class="btn btn-primary" :disabled="locked || Boolean(serversError)" data-testid="review-dns" @click="reviewDns">İncele</button>
      </div>
    </div>

    <SettingsPlanSheet
      :open="sheet !== null"
      :title="sheet?.title ?? ''"
      :description="sheet?.description"
      :request="sheet?.request ?? null"
      :apply-label="sheet?.applyLabel"
      @close="sheet = null"
      @applied="applied"
    >
      <template v-if="sheet?.kind === 'alan'">
        <ul class="modal-list">
          <li><Icon name="tailnet" :size="18" /><span>Önce Tailscale Admin → DNS'te {{ tailscaleV4 || "sunucunun Tailscale" }} sunucusuna “Restrict to domain” ile {{ sheetDomain }} alanını ekleyin. Onay bitene kadar eski {{ domain }} eşleştirmesini de koruyun.</span></li>
          <li><Icon name="clock" :size="18" /><span>Uygulamadan sonra yeni adresi açıp 5 dakika içinde onaylayın; aksi hâlde sunucu eski ada döner.</span></li>
          <li><Icon name="folder" :size="18" /><span>Dosya servisleri kısa süre yeniden başlar; devam eden dosya aktarımlarını önce bitirin.</span></li>
        </ul>
        <p class="mono plan-address">{{ panelAddress(sheetDomain) }}</p>
      </template>
    </SettingsPlanSheet>

    <Modal :open="recordOpen" variant="sheet" :title="recordEditing ? 'Kaydı düzenle' : 'Kayıt ekle'" :description="`.${domain} altında bir ad; sunucunun DNS'i yanıtlar.`" @close="recordOpen = false">
      <form id="kayit-formu" class="form-stack" novalidate @submit.prevent="saveRecord">
        <Field v-slot="{ id, describedby, invalid }" label="Ad" :suffix="'.' + domain" :error="recordTried ? recordNameError : ''">
          <input :id="id" v-model="recordLabel" class="input" type="text" maxlength="200" autocapitalize="none" autocomplete="off" spellcheck="false"
            placeholder="yazici" :aria-describedby="describedby" :aria-invalid="invalid || undefined" data-autofocus />
        </Field>
        <Field label="Yanıt" group>
          <label class="check-row"><input v-model="recordTarget" type="radio" name="kayit-hedef" value="tailscale" /><span>Sunucunun Tailscale adresi (değişse de izler)</span></label>
          <label class="check-row"><input v-model="recordTarget" type="radio" name="kayit-hedef" value="ip" /><span>Sabit bir IP adresi</span></label>
        </Field>
        <Field v-if="recordTarget === 'ip'" v-slot="{ id, describedby, invalid }" label="IP adresi" :error="recordTried ? recordIpError : ''">
          <input :id="id" v-model="recordIp" class="input" type="text" autocomplete="off" spellcheck="false" placeholder="100.64.0.7"
            :aria-describedby="describedby" :aria-invalid="invalid || undefined" />
        </Field>
        <p class="meter-note">Yeni bir ad Caddy'de site açmaz; yalnız DNS yanıtı verir. Taslağa eklenir; İncele ile uygulanır.</p>
      </form>
      <template #actions>
        <button type="button" class="btn btn-secondary" @click="recordOpen = false">Vazgeç</button>
        <button type="submit" form="kayit-formu" class="btn btn-primary">{{ recordEditing ? "Taslağa yaz" : "Taslağa ekle" }}</button>
      </template>
    </Modal>
  </div>
</template>
