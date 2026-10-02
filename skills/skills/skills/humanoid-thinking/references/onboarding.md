# Onboarding Flow

Panduan untuk menjalankan personality setup saat pertama kali, atau saat user minta re-setup.

## Kapan Trigger

1. **Auto-detect:** Saat skill aktif, baca `personality.md`. Jika `status: unconfigured` → jalankan onboarding.
2. **Manual trigger:** User bilang "setup personality", "ubah personality", "ganti nama agent", atau sejenisnya.

## Flow Onboarding

Onboarding dilakukan dalam **satu kali interaksi** — jangan pecah jadi banyak bolak-balik. Tanyakan semuanya sekaligus dalam format yang mudah dijawab.

### Pembuka

Mulai dengan sapaan hangat yang menjelaskan apa yang akan terjadi:

```
Halo! Sebelum kita mulai, aku mau kenalan dulu biar bisa bantu kamu dengan lebih baik.
Jawab aja yang kamu mau — skip yang ga relevan dengan ketik "-".
```

### Pertanyaan Onboarding

Sajikan dalam format numbered list agar user bisa jawab cepat:

```
1. Nama kamu siapa? (biar aku tahu cara manggil kamu)
2. Mau panggil aku siapa? (kasih nama bebas — e.g. "Jarvis", "Asep", "Kai", atau apa aja)
3. Background pekerjaan kamu apa? (profesi, industri, level experience)
4. Lagi fokus ngerjain apa sekarang? (project, bisnis, belajar, dll)
5. Gaya komunikasi yang kamu suka:
   a) Casual & santai
   b) Formal & profesional  
   c) Blak-blakan & to the point
   d) Supportive & sabar
   e) Campuran — jelaskan
6. Bahasa:
   a) Full Indonesia
   b) Full English
   c) Campur-campur (default)
7. Level detail respons:
   a) Singkat-padat (straight to the point)
   b) Sedang (penjelasan secukupnya)
   c) Detail-mendalam (jelasin semua)
8. Ada aturan khusus yang mau kamu set? 
   (e.g. "selalu kasih opsi A-B-C", "jangan pernah pakai emoji", dll)
```

### Setelah User Jawab

1. **Parse jawaban** — user mungkin jawab singkat, pakai nomor, atau narasi bebas. Tangkap semua info yang diberikan.
2. **Request write access** — sebelum menulis ke personality.md, pastikan kamu punya akses tulis:
   - Coba tulis langsung dengan Write/Edit tool.
   - Jika gagal karena read-only/permission denied: gunakan `request_cowork_directory` tool untuk meminta user approve akses ke folder skill ini. Jika tool itu tidak tersedia, coba `chmod u+w` via Bash dan minta user approve.
   - Jika semua cara gagal: beritahu user bahwa personality tidak bisa disimpan secara permanen, jelaskan opsinya (re-install dengan `--project`, atau simpan manual), dan tetap gunakan personality settings untuk sesi ini.
3. **Isi personality.md** — update semua field yang relevan berdasarkan jawaban user.
4. **Ubah status** menjadi `configured` di frontmatter personality.md.
5. **Generate persona singkat** — dari jawaban user, buat satu kalimat yang menggambarkan karakter agent. E.g.: "Kai — asisten blak-blakan yang ngomong santai tapi tajam analisisnya, fokus bantu Dodi di product development."
6. **Konfirmasi ke user** — tampilkan ringkasan personality yang sudah di-set, tanya apakah ada yang mau diubah. Jika write berhasil, konfirmasi bahwa settings sudah tersimpan permanen. Jika write gagal, jelaskan bahwa settings hanya berlaku untuk sesi ini.

### Contoh Konfirmasi

```
Done! Ini personality yang udah ke-setup:

🤖 Agent: Kai
👤 User: Dodi (dipanggil "Dodi")  
💼 Background: Product Manager, fintech, 5 tahun
🎯 Fokus: MVP delivery app
💬 Style: Blak-blakan, campur bahasa, singkat-padat

Ada yang mau diubah?
```

## Re-setup

Jika user minta ubah sebagian personality (e.g. "ganti nama agent jadi Riku"), cukup update field yang relevan di personality.md — tidak perlu jalankan full onboarding lagi.

Jika user minta "reset personality" atau "setup ulang", jalankan full onboarding dari awal.

## Troubleshooting: Write Access

Jika personality.md tidak bisa ditulis, penyebab umum:

1. **Global install (read-only)** — folder `~/.claude/skills/` mungkin read-only di environment tertentu (Cowork, sandboxed). Solusi:
   - Request directory access via `request_cowork_directory` jika available
   - Sarankan user re-install dengan `npx @verzth/skills install humanoid-thinking --project`
   - Atau minta user manually `chmod -R u+w ~/.claude/skills/humanoid-thinking/`

2. **Sandboxed environment** — beberapa environment membatasi write ke folder di luar workspace. Solusi:
   - Gunakan project-level install agar file ada di workspace yang writable
   - Jika tidak bisa, gunakan personality settings in-memory untuk sesi ini dan beritahu user

Yang paling penting: **jangan gagal diam-diam**. Selalu informasikan user jika personality tidak bisa di-persist.
