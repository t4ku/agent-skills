# yt-dlp / ffmpeg Command Cookbook

## yt-dlp

### Download video + subtitles
```bash
# Full package: 720p video + auto+manual subs (en/ja), convert to SRT
yt-dlp -f 'bv[height<=720]+ba/b[height<=720]' \
  --write-auto-subs --write-subs \
  --sub-lang 'en,ja,en-US,ja-JP' --sub-format vtt \
  --convert-subs srt \
  -o '%(title)s.%(ext)s' \
  "$URL"
```

### Subtitle-only (for LLM analysis, skip video download)
```bash
yt-dlp --skip-download --write-auto-subs --write-subs \
  --sub-lang 'en,ja' --sub-format vtt --convert-subs srt \
  -o 'sub.%(ext)s' "$URL"
```

### Get video metadata only
```bash
yt-dlp --print '%(title)s' --print '%(duration)s' --print '%(id)s' --skip-download "$URL"
```

### Age-restricted / members-only
```bash
yt-dlp --cookies-from-browser chrome "$URL"
```

## ffmpeg

### Extract single frame at timestamp
```bash
# Fast (input-level seek)
ffmpeg -ss 00:01:23 -i video.mp4 -vframes 1 -q:v 2 frame.jpg

# Frame-accurate (slower)
ffmpeg -i video.mp4 -ss 00:01:23 -vframes 1 -q:v 2 frame.jpg
```

### Extract frame scaled to 1280px width
```bash
ffmpeg -ss 00:01:23 -i video.mp4 -vframes 1 -vf scale=1280:-1 frame.png
```

### Extract clip (lossless, fast cut)
```bash
ffmpeg -ss 00:01:00 -to 00:03:30 -i video.mp4 -c copy clip.mp4
```

### Extract clip (re-encode, smooth cut)
```bash
ffmpeg -ss 00:01:00 -to 00:03:30 -i video.mp4 \
  -c:v libx264 -preset fast -crf 23 -c:a aac -b:a 128k clip.mp4
```

### Vertical crop for SNS (9:16)
```bash
ffmpeg -i clip.mp4 -vf "crop=ih*9/16:ih,scale=1080:1920" -c:a copy vertical.mp4
```

### Add burn-in subtitles
```bash
ffmpeg -i clip.mp4 -vf "subtitles=video.ja.srt:force_style='FontSize=24,PrimaryColour=&Hffffff&,OutlineColour=&H000000&,BorderStyle=3'" \
  subtitled.mp4
```

### Batch extract frames at every N seconds (scene survey)
```bash
ffmpeg -i video.mp4 -vf "fps=1/30" -q:v 2 survey-%03d.jpg
# every 30s
```

### Scene change detection (optional alternative to LLM)
```bash
ffmpeg -i video.mp4 -vf "select='gt(scene,0.4)',showinfo" -vsync vfr scene-%03d.jpg 2> scenes.log
```

## SRT parsing (for LLM input)

SRT format:
```
1
00:00:00,000 --> 00:00:03,500
Welcome to the video.

2
00:00:03,500 --> 00:00:07,000
Today we'll discuss...
```

Convert SRT timestamps to `HH:MM:SS` (drop milliseconds):
```bash
grep -oE '[0-9]{2}:[0-9]{2}:[0-9]{2}' video.en.srt | head -20
```

Get full transcript as plain text:
```bash
# Strip SRT formatting, keep only dialogue
awk '/^[0-9]+$/{next} /-->/{next} /^$/{next} {print}' video.en.srt
```
