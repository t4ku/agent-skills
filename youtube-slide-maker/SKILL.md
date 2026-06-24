---
name: youtube-slide-maker
version: "0.1.0"
description: YouTube動画からスライドまたは切り抜き動画を生成する。字幕ベースでキーフレームを選定しffmpegで抽出、Marpスライド or 切り抜きクリップを出力。Use when user asks to create slides from a YouTube video, extract key frames, summarize a video visually, or create short clips/切り抜き動画.
---

# YouTube Slide Maker

YouTube URL → スライドデッキ or 切り抜き動画 の2モード。字幕 → LLMでキーフレーム選定 → ffmpegで抽出。

## Modes

| Mode | Output | Use Case |
|------|--------|----------|
| **slides** | `slides.md` (Marp) + `frames/*.png` | 動画の要点スライド化（PKM・ブログ等） |
| **clips** | `clips/*.mp4` (1-3分の切り抜き) | SNS・ダイジェスト用 |
| **both** | 両方 | スライドと切り抜きを同時生成 |

## Workflow

### 1. Prepare
```bash
# Default output directory (PKMのInbox配下)
OUT="Projects/PKM/youtube-slides/<video-slug>"
mkdir -p "$OUT/frames" "$OUT/clips"
cd "$OUT"
```

### 2. Download video + subtitles
```bash
# Video (prefer 720p to save space)
yt-dlp -f 'bv[height<=720]+ba/b[height<=720]' \
  --write-auto-subs --write-subs --sub-lang en,ja --sub-format vtt \
  --convert-subs srt \
  -o 'video.%(ext)s' "$URL"
```

Fields of interest after download:
- `video.mp4` / `video.webm` — full video
- `video.en.srt` or `video.ja.srt` — transcript

### 3. Analyze transcript → select keyframes

Read the SRT. For a target of N slides (default 10-15):
- Identify chapter-like structure (topic shifts, emphasis words, demos)
- Output JSON-like list: `[{ts: "00:01:23", title: "...", summary: "..."}]`
- For clips mode: identify 1-3 min contiguous segments (`{start, end, title}`)

**Prompt pattern for transcript → keyframes**:
```
This is a video transcript (SRT). Select {N} key moments that best represent the video.
For each, output:
- ts: timestamp in HH:MM:SS (pick a moment ~2-5s after speaker introduces topic to catch the explanation frame)
- title: ≤30 char headline
- summary: 1-2 sentence body
```

### 4. Extract frames
```bash
# Per keyframe (ts = HH:MM:SS)
ffmpeg -ss "$ts" -i video.mp4 -vframes 1 -q:v 2 "frames/$(printf '%02d' $i)-$slug.png"
```

Tips:
- `-ss` before `-i` = fast seek (input-level)
- `-q:v 2` = high quality JPEG (or omit for PNG)
- For slide thumbnails: scale with `-vf scale=1280:-1`

### 5. Extract clips (clips/both mode)
```bash
# Lossless cut (fast, no re-encode)
ffmpeg -ss "$start" -to "$end" -i video.mp4 -c copy "clips/$(printf '%02d' $i)-$slug.mp4"

# Re-encode (needed if keyframe alignment matters, smooth cut)
ffmpeg -ss "$start" -to "$end" -i video.mp4 -c:v libx264 -c:a aac "clips/$(printf '%02d' $i)-$slug.mp4"
```

For SNS切り抜き: consider vertical crop
```bash
ffmpeg -i clip.mp4 -vf "crop=ih*9/16:ih,scale=1080:1920" -c:a copy vertical.mp4
```

### 6. Generate Marp slides (slides/both mode)

See [references/marp-template.md](references/marp-template.md) for the slide structure.

Key points:
- 1 frame per slide, title overlay + summary bullet
- Use `Projects/PKM/youtube-slides/<slug>/slides.md`
- Render to PDF/HTML: `npx @marp-team/marp-cli slides.md -o slides.pdf`

### 7. Link back to PKM

Add to the original Readwise inbox file (`Inbox/readwise-*.md`) or Journal:
```markdown
### Slide Deck
- slides
- Source: <video URL>
- Generated: YYYY-MM-DD
```

## Parameters (ask if unclear)

- **URL**: required
- **Mode**: `slides` | `clips` | `both` (default: `slides`)
- **N**: slide count (default: 12) or clip count (default: 3)
- **Language**: subtitle preference (`en`, `ja`, `auto`)
- **Output dir**: default `Projects/PKM/youtube-slides/<slug>/`

## Common Pitfalls

- **No subtitles available**: fall back to `--write-auto-subs` (auto-generated). If still none, use `whisper` or ask user.
- **Slug conflicts**: derive from video title + short ID hash
- **Large videos**: limit to 720p by default, warn if >1GB
- **Rate limits**: yt-dlp may need `--cookies-from-browser` for members-only or age-restricted
- **Timestamp offset**: `-ss` before `-i` is fast but can be ~1s off on some codecs; use `-ss` after `-i` for frame-accurate at cost of speed

## Tool Reference

See [references/commands.md](references/commands.md) for full yt-dlp / ffmpeg command cookbook.

## Integration with PKM

- Output dir: `Projects/PKM/youtube-slides/<slug>/` (submodule-safe location)
- Slide deck reference added to source `Inbox/readwise-*.md` file
- No Cards auto-creation — user decides if content warrants a Card
