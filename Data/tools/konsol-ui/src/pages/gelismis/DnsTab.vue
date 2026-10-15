<!-- Gelişmiş → DNS: dnsmasq as it runs (GET /api/konsol/gelismis): the interfaces it listens on, the local
     domains it answers for, whether it hands out addresses (DHCP), every name with its answer, family and
     owner, and the raw files (?ham=1). Names are switched and added in Erişim → Adresler. -->
<script setup lang="ts">
import { computed } from "vue";
import { RouterLink } from "vue-router";
import EmptyState from "../../components/ui/EmptyState.vue";
import RawFiles from "./RawFiles.vue";
import { accessRoute } from "../../sections";
import { live } from "../../live";
import { UNKNOWN } from "../../format";
import type { Advanced, DnsName } from "../../api/gelismis";

const props = defineProps<{ data: Advanced }>();
const dns = computed(() => props.data.dnsmasq);

function owner(source: string): string {
  if (source === "base") return "Temel";
  return live.uygulamalar?.items.find((a) => a.modul === source)?.ad ?? source;
}
const answer = (n: DnsName) => n.address || (n.iface ? `${n.iface} arayüzünün adresi` : UNKNOWN);
const family = (n: DnsName) => (n.family === 4 ? "IPv4" : n.family === 6 ? "IPv6" : "IPv4 + IPv6");
const fileCount = computed(() => `${dns.value.raw.length} dosya`);
</script>

<template>
  <div class="advanced-tab" data-testid="dns">
    <section class="card" aria-labelledby="dns-baslik">
      <h2 id="dns-baslik" class="card-title">dnsmasq</h2>
      <dl class="facts" data-testid="dns-facts">
        <dt>Dinleme</dt>
        <dd class="mono">{{ dns.listen.join(", ") || UNKNOWN }}</dd>
        <dt>Yerel alan</dt>
        <dd class="mono">{{ dns.domains.join(", ") || UNKNOWN }}</dd>
        <dt>DHCP</dt>
        <dd>{{ dns.dhcp ? "Açık: dnsmasq adres dağıtıyor" : "Kapalı" }}</dd>
      </dl>
      <p class="meter-note">dnsmasq yalnız bu arayüzlerden gelen sorgulara yanıt verir; internete DNS açılmaz.</p>
    </section>

    <section class="card" aria-labelledby="dns-ad-baslik">
      <div class="card-head">
        <h2 id="dns-ad-baslik" class="card-title">Kayıtlar</h2>
        <span class="meter-note">{{ dns.names.length }} ad</span>
      </div>
      <div v-if="dns.names.length" class="table-wrap">
        <table class="data-table dns-table">
          <thead>
            <tr>
              <th scope="col">Ad</th>
              <th scope="col">Yanıt</th>
              <th scope="col">Aile</th>
              <th scope="col">Kaynak</th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="(n, i) in dns.names" :key="`${n.name}:${i}`" :data-ad="n.name">
              <th scope="row" class="col-main"><strong class="mono wrap">{{ n.name }}</strong></th>
              <td data-label="Yanıt" class="mono wrap">{{ answer(n) }}</td>
              <td data-label="Aile">{{ family(n) }}</td>
              <td data-label="Kaynak">{{ owner(n.source) }}</td>
            </tr>
          </tbody>
        </table>
      </div>
      <EmptyState v-else title="Kayıt yok" text="dnsmasq'ın dosyalarında bir ad bulunamadı." icon="globe" />
      <p class="meter-note">DNS önbellekleri hemen silinmez. Yeni bir ad eklemek Caddy sitesi oluşturmaz.</p>
      <RouterLink :to="accessRoute('adresler')" class="section-link">Yerel adları Erişim'de değiştir</RouterLink>
    </section>
    <RawFiles :files="dns.raw" :summary="`dnsmasq · ${fileCount}`" />
  </div>
</template>
