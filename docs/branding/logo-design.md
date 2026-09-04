# Larenor marka varlıkları

Slogan aynen korundu: **Unus Lar, omnem domum servat.**

Ana simge yerleşik ImageGen ile üretildi; CLI/API fallback kullanılmadı.
Fildişi ev çerçevesi ve altın ocak/koruyucu figürü, lacivert zemin üzerinde
önceki ev/koruyucu temasını sürdürüyor. Slogan ve Larenor adı uygulamada gerçek
metin olarak çizilir; küçük simgeye gömülmez.

## Dosyalar ve üretim

- Ana PNG: `assets/icon/app_icon.png` (uygulama içi, Android eski sürüm ve iOS).
- Android uyarlanabilir simge: `android/app/src/main/res/drawable/larenor_color.xml`.
- Android tek renkli/temalı simge: `android/app/src/main/res/drawable/larenor_monochrome.xml`.
- Üretim: `dart run flutter_launcher_icons`. Android'in yerel vektör katmanları ve
  `mipmap-anydpi-v26/ic_launcher.xml` korunur; PNG ve iOS boyutları güncellenir.
- Ortak uygulama bileşeni: `lib/shared/widgets/larenor_brand.dart`.

ImageGen'in şeffaflık denemeleri RGB dama deseni ürettiği için kullanılmadı.
Android için gerçek şeffaf negatif alan taşıyan yerel vektör eşlikçisi yazıldı;
tek renkli sürüm aynı geometriden oluşur. Vektörün güvenli alanı 0.86 ölçekle
maskelerin içinde tutulur. iOS ikon seti üretildi, iOS imzalı build yapılmadı.

## Seçilen görselin üretim istemi

```text
Use case: logo-brand.
Asset type: final production app icon master, 1024x1024 square, for Larenor, a private premium smart-home control app with an Apple Home-inspired interface.
Primary request: Design a sophisticated, highly distinctive and instantly legible emblem for the guardian spirit of the home. The existing brand has a blue background, white house and golden guardian dot; evolve that idea into a refined cohesive mark, not a literal stock house pictogram.
Subject: one bold architectural house/portal silhouette formed by a continuous ivory rounded stroke with a gently peaked roof, enveloping one warm golden hearth/guardian flame. The inner flame can subtly suggest a lower-case lar / human presence, but keep extremely simple. A balanced protected-home feeling; generous negative space, no thin decorative strokes.
Style/medium: premium contemporary iOS app icon, precise vector-like geometry, softly rounded joins, very subtle dimensional enamel finish and restrained light, not photorealistic, not a mockup. Strong recognizable silhouette at 32px.
Color palette: rich midnight navy #142B3B filling the entire square edge-to-edge, very subtle blue-to-teal depth; warm ivory #F8F4E8 house mark and soft amber gold #DFA65C flame. Warm, calm and crafted rather than electric blue.
Composition: one centered mark, emblem occupies about 62% of the image width and height, optically centered with even safe margin; all content fits inside the central circle-safe area. Background full bleed with NO rounded outer corners: Android/iOS will apply their own mask.
Text: none. The exact brand slogan 'Unus Lar, omnem domum servat.' is conceptual context only and will be set as real text separately in the app.
Constraints: production-ready single app icon asset, no lettering, no wordmark, no slogan inside image, no extra versions, no presentation sheet, no surrounding device, no watermark, no tiny details, no shield border, no detached sparkles.
```
