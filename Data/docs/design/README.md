# Konsol — design mockups

Frozen HTML mockups of **Konsol**, the single admin console at
`http://panel.<domain>` that replaces the separate WireGuard (`wg.`) and
file (`dosya.`) panels. Each file is a self-contained page with sample
data and no backend; open it in a browser to see the agreed design.

Mockups are references, not code. They are frozen: iterate in a new
`konsol-vNN.html`, never edit a saved one. The behaviour they imply is
recorded in `../design-decisions.md`; the mockup only shows it.

| File | Date | Covers |
|------|------|--------|
| `konsol-v01.html` | 2026-09-16 | Sidebar and pages (Genel bakış, WireGuard, Dosyalar, Günlük); server card with CPU/RAM graphs and a disk bar; WireGuard network cards with lever switches, peer rows with on/off, QR, delete and an edit dialog; "Arayüz ekle" as its own page; file browser with a trash card; share links over a single read-only WebDAV account |
| `konsol-dosyalar-v02.html` | 2026-09-16 | Dosyalar sekmesinin FileBrowser'ı gereksiz kılan hâli: kısayol sütunu (Sunucu, downloads, media, Paylaşımlar, Çöp) ve disk göstergesi, arama ve görünüm anahtarı olan araç çubuğu, seçim modunda eylem çubuğuna dönüşen üst çubuk, ızgara görünümü + önizleme paneli, listenin içine sürükle-bırak yükleme (ilerleme satırın içinde, ayrı kuyruk alanı yok); sonunda davranış notları ve gereken API uçları |
