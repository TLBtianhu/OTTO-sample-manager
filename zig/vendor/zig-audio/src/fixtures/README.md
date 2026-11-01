# Test fixtures

Generated locally with **ffmpeg n7.1.5** (20260731 build). They are committed
because they are tiny (about 200 KB total) and let CI exercise real encoder
output without installing ffmpeg. The two Opus files that are not tiny — the
128 kbps stereo CELT tone (1 s) and the 32 kbps mono Hybrid tone (2 s) — are
still under 20 KB each, and they are what makes the Opus benchmarks and the
Hybrid conformance test self-contained.

No third-party or copyrighted content: every WAV/FLAC file is a 0.02 s, 440 Hz
sine wave; the two MP3 files are synthetic tones described below.

## Commands

WAV fixtures use this source:

```
-f lavfi -i "sine=frequency=440:duration=0.02"
```

| File | Additional ffmpeg arguments |
| --- | --- |
| `wav-pcm16-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_s16le` |
| `wav-pcm8-mono-44100.wav` | `-ac 1 -ar 44100 -c:a pcm_u8` |
| `wav-pcm24-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_s24le` |
| `wav-pcm32-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_s32le` |
| `wav-f32-stereo-44100.wav` | `-ac 2 -ar 44100 -c:a pcm_f32le` |
| `wav-pcm16-6ch-48000.wav` | `-ac 6 -ar 48000 -c:a pcm_s16le` |

FLAC fixtures are **transcoded from the WAV files above** so that the two
decoders can be compared sample for sample without any external tool. The
fixed-predictor trio is encoded with the LPC stage disabled and independent
channels:

```
-lpc_type none -ch_mode indep -max_partition_order 4 -c:a flac
```

| File | Source / additional arguments |
| --- | --- |
| `flac-s16-stereo-44100.flac` | from `wav-pcm16-stereo-44100.wav` |
| `flac-s16-6ch-48000.flac` | from `wav-pcm16-6ch-48000.wav` |
| `flac-s24-stereo-44100.flac` | from `wav-pcm24-stereo-44100.wav`, plus `-sample_fmt s32 -bits_per_raw_sample 24` |
| `flac-s16-mono-8000-lpc.flac` | fresh sine, `-ac 1 -ar 8000 -lpc_type levinson` |
| `flac-s16-stereo-44100-lpc.flac` | from `wav-pcm16-stereo-44100.wav`, plus `-lpc_type levinson -min_prediction_order 32 -max_prediction_order 32 -lpc_coeff_precision 15 -ch_mode mid_side` |

Full example:

```sh
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=0.02" \
  -ac 2 -ar 44100 -c:a pcm_s16le wav-pcm16-stereo-44100.wav
ffmpeg -v error -y -i wav-pcm16-stereo-44100.wav \
  -c:a flac -lpc_type none -ch_mode indep -max_partition_order 4 \
  flac-s16-stereo-44100.flac
ffmpeg -v error -y -i wav-pcm16-stereo-44100.wav \
  -c:a flac -lpc_type levinson -min_prediction_order 32 \
  -max_prediction_order 32 -lpc_coeff_precision 15 -ch_mode mid_side \
  -max_partition_order 4 flac-s16-stereo-44100-lpc.flac
```

## FLAC coverage

| File | Block size | Bits | Channels | Subframes | Status |
| --- | --- | --- | --- | --- | --- |
| `flac-s16-stereo-44100.flac` | 4608 | 16 | 2 | FIXED | decodes |
| `flac-s16-6ch-48000.flac` | 4608 | 16 | 6 | 5 CONSTANT + 1 FIXED | decodes |
| `flac-s24-stereo-44100.flac` | 4608 | 24 | 2 | FIXED | decodes (`>> 8` to i16) |
| `flac-s16-mono-8000-lpc.flac` | 576 | 16 | 1 | LPC | decodes |
| `flac-s16-stereo-44100-lpc.flac` | 882 | 16 | 2 | LPC order 32, mid/side (17-bit side) | decodes |

The 8-bit / 12-bit / 20-bit / wasted-bits / predictor-overflow / Rice-escape
cases cannot be produced by ffmpeg's FLAC encoder, and the official test vector
corpus is not committed. Those cases are therefore built in memory by
`src/flac_build.zig` and compared against ffmpeg's own decoder in
`src/flac_lpc_test.zig` and the other `src/*_test.zig` files.

## MP3 fixtures

Both are MPEG-1 Layer III, 44.1 kHz, 128 kbps, encoded with `libmp3lame` from
ffmpeg's `sine` / `aevalsrc` sources, and are used by `zig build bench` (one
decodes the whole file repeatedly for 20 s of audio):

```sh
ffmpeg -v error -y -f lavfi -i "sine=frequency=440:duration=3" \
  -ac 1 -ar 44100 -c:a libmp3lame -b:a 128k mp3-mono-44k-128.mp3
ffmpeg -v error -y -f lavfi \
  -i "aevalsrc=sin(2*PI*440*t)|sin(2*PI*660*t):s=44100:d=1" \
  -ac 2 -ar 44100 -c:a libmp3lame -b:a 128k mp3-stereo-44k-128.mp3
```

| File | Channels | Frames | Purpose |
| --- | --- | --- | --- |
| `mp3-mono-44k-128.mp3` | 1 | 132300 | mono throughput (3 s) |
| `mp3-stereo-44k-128.mp3` | 2 | 44100 | stereo throughput: two synthesis chains (1 s) |
| `opus-stereo-48k-128.opus` | 2 | 48000 | Opus CELT throughput: the whole CELT chain on two channels (1 s) |
| `opus-silk-wb-12k.opus` | 1 | 96000 | Opus SILK conformance vector and throughput (2 s wideband) |
| `opus-hybrid-mono-48k.opus` | 1 | 96000 | Opus Hybrid conformance and throughput: all 101 packets are configuration 15 (2 s) |

## What each fixture covers

- WAV: unsigned PCM8, PCM16, PCM24, PCM32, IEEE float32, and 5.1
  `WAVE_FORMAT_EXTENSIBLE`.
- FLAC: 16-bit stereo, 16-bit 5.1, 24-bit stereo, plus two LPC files (8 kHz mono
  and 44.1 kHz stereo with order-32 mid/side prediction). The 16/24-bit files
  and the stereo LPC file decode to exactly the same i16 samples as their WAV
  sources, which is checked on every CI run.
- MP3: one mono and one stereo tone, for the benchmark only. The MP3 conformance
  corpus lives outside the repository (`..\zig-audio-vectors\mp3`) and the
  intensity-stereo cases are built in memory by `src/mp3_build.zig`.
- Opus: one 440 Hz stereo tone at 128 kbps with 20 ms frames, so every packet is
  the CELT-only configuration 31; one wideband SILK speech file (configuration
  9), which is the SILK conformance vector; and one pure-Hybrid file whose 101
  packets are all configuration 15, which is compared against ffmpeg in
  `src/opus_hybrid_vectors_test.zig` and used by the benchmark. The CELT/SILK
  conformance corpus lives outside the repository (`..\zig-audio-vectors\ogg`).

## Regenerating

```
ffmpeg -f lavfi -i "sine=frequency=440:sample_rate=48000:duration=1" -ac 2 \
       -c:a libopus -b:a 128k -frame_duration 20 -application audio \
       -f ogg opus-stereo-48k-128.opus
ffmpeg -f lavfi -i "anoisesrc=color=pink:sample_rate=48000:duration=2" -ac 1 \
       -c:a libopus -b:a 32k -application voip -frame_duration 20 -vbr off \
       -f ogg opus-hybrid-mono-48k.opus
```

libopus chooses Hybrid for all 101 packets of the pink-noise file: CBR at
32 kbps with the VOIP application selects the SWB/FB path, and pink noise has
energy where Hybrid's high band lives. That is what makes it a *pure* Hybrid
fixture; re-encoding with different content or a different rate can silently
turn it into SILK or CELT, so the test pins `configs[15] == 101`.

The live ffmpeg integration tests in `src/ffmpeg_test.zig` generate equivalent
files through a pipe, where ffmpeg writes WAV `data` size `0xFFFFFFFF` and FLAC
`total_samples = 0`; both exercise the "unknown length" paths.
