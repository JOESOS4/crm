# Voice input research — speech-to-text for "speak to Taylor"

Research only. No code, no schema, no API surface committed. Written
2026-09-09 to inform a future build; re-check pricing pages before actually
wiring a provider, since usage-based STT pricing moves often.

## Recommendation

**AssemblyAI Universal-Streaming**, browser → our NestJS backend → AssemblyAI,
using AssemblyAI's temporary token endpoint so the long-lived key never
reaches the browser.

Why this over the alternatives:

- **Streaming is native, not bolted on.** Universal-Streaming is built for
  live audio and publishes a concrete latency number — "300ms latency"
  ([Universal-Streaming](https://www.assemblyai.com/universal-streaming)) —
  not an estimate inferred from a batch model.
- **Cost at low volume is a non-issue.** $0.15/hr
  ([pricing](https://www.assemblyai.com/pricing)), $50 free credit with no
  card, sub-$1/day at any early-stage volume Taylor will see.
- **Zero ops burden.** Managed API, official SDKs, no GPU, no model to keep
  patched. This is the deciding factor for a small team — every self-hosted
  option below (Parakeet, self-hosted Whisper) trades cost for an ops
  commitment this team does not want yet.
- **CRM speech is exactly its stated strength.** The product page calls out
  handling "emails, codes, and names"
  ([Universal-Streaming](https://www.assemblyai.com/universal-streaming)) —
  proper nouns and company names are the CRM accuracy risk, and it's the
  one named use case on the marketing page, not an inferred fit.
- **The security question is already answered.** AssemblyAI documents
  short-lived tokens explicitly for this shape: "Don't ship your API key to
  client-side code. Authenticate from the browser with a short-lived
  temporary token instead."
  ([Universal-Streaming quickstart](https://www.assemblyai.com/docs/speech-to-text/universal-streaming)).

**Deepgram Nova-3** is the credible second choice — cheaper per minute
($0.0048/min ≈ $0.29/hr streaming, vs. AssemblyAI's $0.15/hr ≈ $0.0025/min —
Deepgram's headline number is a per-minute rate, AssemblyAI's is per-hour;
compare them as per-minute and AssemblyAI is actually the cheaper of the
two) and equally mature, with its own documented temporary-token flow
([auth grant reference](https://developers.deepgram.com/reference/auth/tokens/grant)).
Pick Deepgram instead if a later side-by-side transcription test on real
sales-call audio favors its accuracy or its SDK ergonomics — the two are
close enough that this is a bake-off, not a foregone conclusion. Don't pick
both; maintaining two STT vendors for one feature is scope nobody asked for.

**Do not use**: the browser-native Web Speech API (no Firefox/Edge support,
audio leaves the device to an undocumented Google backend on Chrome, no SLA);
NVIDIA Parakeet or self-hosted Whisper (real ops burden — GPU provisioning,
model serving, scaling — for a v1 feature); the OpenAI batch Whisper API
(not built for live audio at all).

## Comparison table

| Option | Hosting | Streaming | Cost (as of Sep 2026) | Latency | Ops burden |
|---|---|---|---|---|---|
| [NVIDIA Parakeet](#1-nvidia-parakeet) | Self-hosted (NeMo/NIM) or NVIDIA-hosted (build.nvidia.com) | Yes, via NIM `mode=str` or cache-aware streaming variants | Free (open weights) + GPU cost | Sub-second on GPU; depends on infra | High — GPU provisioning, container ops, scaling |
| [OpenAI Whisper API (batch)](#2-openai-whisper) | Hosted API | No (file-in, transcript-out) | $0.006/min | Seconds-to-minutes (batch) | Low |
| [OpenAI Whisper (self-hosted)](#2-openai-whisper) | Self-hosted (open weights) | No natively | Free + compute | Depends on hardware | High |
| [OpenAI Realtime transcription](#3-openai-realtime-transcription) | Hosted API (WebSocket/WebRTC) | Yes, purpose-built | `gpt-4o-transcribe` ≈ $0.006/min, `gpt-4o-mini-transcribe` ≈ $0.003/min, `gpt-live-transcribe` $0.017/min | Sub-second, streaming deltas | Low |
| [Deepgram Nova-3](#4-deepgram) | Hosted API | Yes, WebSocket | $0.0048/min PAYG streaming (promo), $0.0077/min regular | Sub-second; endpointing tunes finality | Low |
| [AssemblyAI Universal-Streaming](#5-assemblyai) | Hosted API | Yes, WebSocket | $0.15/hr ($0.0025/min) | 300ms published | Low |
| [Cloudflare Workers AI Whisper](#6-cloudflare-workers-ai) | Hosted (edge) | No (batch inference call) | $0.0005/min (Whisper, Whisper-large-v3-turbo) | Batch, not live | Low |
| [Web Speech API](#7-web-speech-api) | Browser-native (Chrome/Safari proxy to a cloud backend) | Yes, but backend is opaque | Free | Low, but unverifiable | None (but no server-side control) |
| [Groq-hosted Whisper](#8-groq) | Hosted API | No (file-based) | ≈ $0.04/hr ($0.00067/min) | Very fast batch (189–216x real-time) | Low |
| [Speechmatics](#9-others) | Hosted API | Yes | ~$0.129/hr Pro tier; $100 free credit | Not independently verified here | Low |
| [Google Cloud STT](#9-others) | Hosted API | Yes (v2, Chirp) | $0.016/min listed by secondary sources; not independently confirmed on Google's own pricing page (JS-rendered, didn't resolve) | Not verified here | Low |
| [Azure AI Speech](#9-others) | Hosted API | Yes | $1/hr standard real-time; 5 free hrs/mo (F0) | Not verified here | Low |
| [ElevenLabs Scribe v2 Realtime](#9-others) | Hosted API | Yes | $0.39/hr streaming, $0.22/hr batch | ~150ms published | Low |

## 1. NVIDIA Parakeet

Open-weight ASR model family from NVIDIA NeMo, distributed on Hugging Face
and deployable via NeMo, Riva, or NIM.

- **Model**: `parakeet-tdt-0.6b-v2` — FastConformer encoder + TDT decoder,
  600M params, CC-BY-4.0 license, English-only (a multilingual
  `parakeet-tdt-0.6b-v3` covers 25 European languages)
  ([model card](https://huggingface.co/nvidia/parakeet-tdt-0.6b-v2)).
- **Accuracy**: 6.05% average WER across the Hugging Face Open-ASR
  Leaderboard's test set mix, ranging 1.69% (LibriSpeech clean) to 11.16%
  (AMI meetings) — same source.
- **Streaming**: the base TDT model card doesn't describe streaming; NVIDIA's
  streaming story is a separate architecture — cache-aware streaming
  Conformer/FastConformer variants (`nemotron-speech-streaming-en-0.6b`,
  `parakeet_realtime_eou_120m-v1`) that process each audio chunk once and
  reuse cached encoder context instead of re-encoding overlapping windows.
  On an H100 this design supports "560 concurrent streams at a 320ms chunk
  size"
  ([NVIDIA blog](https://huggingface.co/blog/nvidia/nemotron-speech-asr-scaling-voice-agents)).
  NIM's ASR containers also expose a `mode=str` streaming deploy option
  alongside `mode=offline`
  ([NIM ASR support matrix / deploy docs](https://docs.nvidia.com/nim/speech/latest/reference/support-matrix/asr.html)).
- **Deployment paths**: NeMo Python (`ASRModel.from_pretrained`), NVIDIA
  Riva, or NIM containers. NIM requires **an NVIDIA GPU, Compute Capability
  ≥ 8.0, ≥16GB VRAM**, more for larger multilingual models (a 48GB L40S can't
  run the 1.1B multilingual model in `mode=all`) — Linux, Docker, an
  `NGC_API_KEY`, ~30–45 min first-run setup
  ([support matrix](https://docs.nvidia.com/nim/speech/latest/reference/support-matrix/asr.html)).
  A no-GPU option exists via NVIDIA's own hosted API at build.nvidia.com.
- **Verdict**: strong accuracy and free weights, but "self-hosted" here
  means owning GPU capacity, container lifecycle, and scaling — the wrong
  trade for a team that wants to ship a voice feature, not run an ASR
  service. Revisit only if STT volume grows enough that per-minute API cost
  starts to dominate infra cost.

## 2. OpenAI Whisper

Two distinct things share the name: the open-weight model, and OpenAI's
hosted `whisper-1` endpoint. Neither is a fit for live "speak to Taylor."

- **Hosted `whisper-1` (batch API)**: $0.006/min, billed per second, no free
  tier, no volume discount
  ([pricing search results, converted against OpenAI's own model card
  numbers](https://developers.openai.com/api/docs/pricing)). It is
  file-in/transcript-out. OpenAI's own current guidance is explicit that
  file transcription (including this model) is for **completed recordings**,
  and that **live microphone/call audio should use the Realtime API instead**
  ([speech-to-text guide](https://developers.openai.com/api/docs/guides/speech-to-text)).
  `whisper-1` also doesn't support the newer file-streaming (`stream=true`)
  delta events that `gpt-4o-transcribe`/`gpt-transcribe` support — same
  source.
- **Self-hosted open-weight Whisper**: free, but the model card and ecosystem
  give no native low-latency streaming path — it's a batch encoder-decoder,
  commonly wrapped in a sliding-window hack for pseudo-streaming, which adds
  both latency and engineering surface. Same self-hosting ops burden
  discussion as Parakeet applies, without Parakeet's accuracy edge on English.
- **Verdict**: useful as a fallback/benchmark model, not the live-voice
  answer. OpenAI itself steers this use case toward the Realtime API — see
  below.

## 3. OpenAI Realtime transcription

The actually-relevant OpenAI option for this feature, distinct from the
batch Whisper API.

- **What it is**: Realtime API sessions can run in transcription-only mode
  (`type: "transcription"`), streaming partial transcript deltas as audio
  arrives and a final transcript when a turn ends, over **WebSocket** (for
  server-side audio pipelines) or **WebRTC** (for direct browser capture)
  ([Realtime transcription guide](https://developers.openai.com/api/docs/guides/realtime-transcription)).
- **Models**: `gpt-live-transcribe` (lowest latency, streams deltas) and
  `gpt-transcribe` (adds detected-language output and cross-turn context) —
  same source.
- **Pricing**: `gpt-4o-transcribe` and `gpt-4o-mini-transcribe` are
  token-billed ($2.50/$10 and $1.25/$5 per 1M input/output tokens
  respectively) with OpenAI-quoted per-minute equivalents of **$0.006/min**
  and **$0.003/min**; the dedicated realtime-transcribe model
  `gpt-live-transcribe` is billed at **$0.017/min**
  ([pricing](https://developers.openai.com/api/docs/pricing)).
- **What it drops vs. batch**: no word-level timestamps, speaker labels, or
  confidence scores in the realtime mode — same guide.
- **Verdict**: technically capable and the right shape (WebRTC direct-to-
  browser is exactly the "stream audio to the provider without our backend
  in the hot path" pattern). Priced above Deepgram/AssemblyAI per minute at
  low volume, and ties the STT vendor to the same vendor a future LLM
  turn-taking/voice-agent layer would use — worth revisiting specifically if
  Taylor later wants OpenAI's realtime *voice agent* stack (STT+LLM+TTS
  bundled) rather than STT alone.

## 4. Deepgram

- **Streaming architecture**: WebSocket connection, SDK-driven; audio pushed
  via `sendMedia()`, transcripts and word-level timing returned as message
  events; **endpointing** detects speech pauses to emit faster interim
  finals ([live streaming getting-started
  guide](https://developers.deepgram.com/docs/getting-started-with-live-streaming-audio)).
- **Pricing** (Nova-3, current promotional rates,
  [pricing page](https://deepgram.com/pricing)):
  - Streaming, pay-as-you-go, monolingual: **$0.0048/min** (promo) / $0.0077
    regular.
  - Streaming, multilingual: $0.0058/min promo / $0.0092 regular.
  - Pre-recorded, monolingual: $0.0043/min.
  - $200 free credit on signup.
- **Client-side auth**: a dedicated grant endpoint,
  `POST https://api.deepgram.com/v1/auth/grant`, mints a short-lived JWT —
  **30-second default TTL**, configurable via `ttl_seconds`, scoped to
  `usage::write` on voice APIs only (cannot touch account-management APIs)
  ([auth token grant reference](https://developers.deepgram.com/reference/auth/tokens/grant)).
  This is the direct answer to "does Deepgram support scoped client tokens":
  yes, purpose-built for exactly this browser-streams-directly pattern.
- **Verdict**: cheapest of the mature streaming vendors per minute, mature
  SDKs, real temporary-token support. The credible alternative to
  AssemblyAI; choose between them on a real accuracy test, not price alone,
  since both are inexpensive at Taylor's likely early volume.

## 5. AssemblyAI

- **Streaming architecture**: WebSocket at
  `wss://streaming.assemblyai.com/v3/ws`, JSON control messages (`Begin`,
  `Turn`, `Termination`) plus binary audio frames; sessions auto-close after
  3 hours; mono 16-bit PCM, AAC, or Opus
  ([Universal-Streaming
  docs](https://www.assemblyai.com/docs/speech-to-text/universal-streaming)).
- **Latency**: **300ms**, stated directly on the product page
  ([Universal-Streaming](https://www.assemblyai.com/universal-streaming)) —
  the only vendor here besides ElevenLabs and Deepgram's own claims to
  publish a specific number rather than "real-time."
  Accuracy is marketed as "superior" with no published WER for this exact
  page; verify against a real sales-call sample before committing.
- **Pricing** ([pricing page](https://www.assemblyai.com/pricing)):
  Universal-Streaming, English or multilingual: **$0.15/hr** ($0.0025/min).
  Billed on **connection-open time**, not audio duration — an idle
  connection still bills. $50 free credit, no card required. Free tier caps
  concurrency at 5 new streams/min vs. 100/min on pay-as-you-go.
- **Client-side auth**: docs explicitly warn against shipping the API key
  to the browser and point to a "short-lived temporary token" flow (exact
  parameters not resolved in this pass — confirm the token endpoint's TTL
  and scope before implementation, same as was done for Deepgram above).
- **Verdict**: the recommended pick. Purpose-built streaming product,
  published latency number, cheapest-per-hour of the two credible streaming
  vendors' headline plans, documented token-based client auth, named CRM-
  relevant strength (proper nouns).

## 6. Cloudflare Workers AI

- **Models available**: `@cf/openai/whisper`, `@cf/openai/whisper-large-v3-turbo`,
  `@cf/openai/whisper-tiny-en` — all Whisper variants, all inference-call
  (batch) models, not a streaming product
  ([Workers AI model catalog](https://developers.cloudflare.com/workers-ai/models/)).
- **Pricing**: $0.0005/audio-minute for both `whisper` and
  `whisper-large-v3-turbo` (41–47 Neurons/min), inside a 10,000
  Neurons/day free allowance
  ([Workers AI pricing](https://developers.cloudflare.com/workers-ai/platform/pricing/)).
  Cheapest number in this whole survey, but it buys batch inference, not a
  live session.
- **Verdict**: relevant because the org already runs on Cloudflare, but it
  doesn't solve the actual requirement — no streaming ASR model is offered
  on Workers AI today. Worth a second look if Cloudflare ships a streaming
  ASR model later, or for an *adjacent* batch-transcription feature (e.g.
  transcribing an uploaded call recording), not for "speak to Taylor" live
  input.

## 7. Web Speech API (browser-native)

- **What it actually is**: on Chrome, `SpeechRecognition` sends audio to a
  server-based recognition engine over the network — MDN states plainly
  that it "does not work offline" and requires "a server-based recognition
  engine"
  ([MDN SpeechRecognition](https://developer.mozilla.org/en-US/docs/Web/API/SpeechRecognition)).
  In practice that backend is Google's, undocumented, with no SLA, no
  pricing, and no contract — this is consistent with the research brief's
  framing.
- **Browser support**: 87.89% "some level of support" globally, but that
  figure hides real gaps — **Firefox has it disabled by default** across
  all listed versions, and **Edge has no support at all**
  ([caniuse](https://caniuse.com/speech-recognition)). Chrome and Safari
  (14.1+) are the only reliable implementers.
- **Verdict**: free and zero-integration, but unusable as the primary path
  for a product that needs cross-browser reliability, and it hands
  potentially confidential CRM speech to an opaque third-party pipe outside
  any vendor agreement. Not recommended even as a fallback.

## 8. Groq-hosted Whisper

- **Models**: `whisper-large-v3`, `whisper-large-v3-turbo`, OpenAI-compatible
  endpoints at `api.groq.com/openai/v1/audio/transcriptions` — **file-based
  only, no streaming transcription is documented**
  ([Groq speech-to-text docs](https://console.groq.com/docs/speech-to-text)).
- **Speed**: 189x real-time (`whisper-large-v3`) and 216x real-time (turbo)
  — same source — i.e. very fast batch turnaround, not low-latency
  streaming.
- **Pricing**: reported at ≈$0.04/hr for the turbo model with a 10-second
  minimum billing increment per request (secondary source; Groq's own
  pricing page did not surface exact per-model audio rates in this pass —
  confirm on [console.groq.com](https://console.groq.com/docs/model/whisper-large-v3-turbo)
  before relying on the number).
- **Verdict**: excellent for fast batch transcription (e.g. voicemail,
  recorded call), not applicable to a live "speak to Taylor" UX — no
  streaming.

## 9. Others (brief)

- **Speechmatics**: streaming and batch STT, ~$0.129/hr "Pro" tier, $100
  free credit, volume discount above 500 hrs/mo
  ([pricing](https://www.speechmatics.com/pricing)). Credible enterprise
  option; no distinct advantage over Deepgram/AssemblyAI at Taylor's stage.
- **Google Cloud Speech-to-Text (Chirp, v2)**: streaming supported.
  Google's own pricing page is JS-rendered and did not resolve via fetch in
  this pass; secondary sources report **$0.016/min** standard real-time,
  scaling down to $0.004/min above 2M minutes/month — **verify directly on
  [cloud.google.com/speech-to-text/pricing](https://cloud.google.com/speech-to-text/pricing)**
  before using this number. Meaningfully more expensive than Deepgram/
  AssemblyAI at low volume regardless.
- **Azure AI Speech**: streaming supported via Speech SDK. **$1/hr**
  standard real-time (Microsoft's own quota/limits doc confirms real-time
  STT is a supported SDK/REST surface with concurrency quotas, though exact
  pricing lives on Azure's separate pricing page —
  [quotas doc](https://learn.microsoft.com/en-us/azure/ai-services/speech-service/speech-services-quotas-and-limits)).
  5 free hours/month on the F0 tier. Supports ephemeral tokens for
  browser use, minted server-side via a token-exchange endpoint — see
  architecture section below. More expensive than Deepgram/AssemblyAI at
  Taylor's volume; only worth it for org-wide Azure/Entra ID integration
  needs Taylor doesn't have today.
- **ElevenLabs Scribe v2 Realtime**: streaming, **$0.39/hr**, ~150ms
  published latency, 90+ languages; Scribe v2 batch is $0.22/hr
  (secondary sources citing ElevenLabs' own pricing and announcements,
  e.g. [pricing](https://elevenlabs.io/pricing/api)). Notably the same
  vendor Taylor would likely pick for **TTS** later (ElevenLabs' core
  product) — see the TTS roadmap note below.

## Prior art: Berd (Block)

Block's Berd — a Tauri desktop app, source at
[github.com/block/berd](https://github.com/block/berd), cloned and read at tag
`v0.6.3` for this research — ships a working, shipped voice-input feature
with three STT backends. Its architecture is desktop-native, not
browser/server like Taylor, so read this as evidence and a contrast, not a
template to copy.

- **Three backends, user-selected, no auto-fallback.** A plain config enum —
  local Parakeet, native macOS Speech, or OpenAI Realtime
  (`src-tauri/crates/berd-voice/src/input.rs`) — chosen explicitly by the
  user in settings, not a runtime degrade chain. The default is on-device;
  cloud (OpenAI) is opt-in.
- **Parakeet runs CPU-only, sidestepping NIM entirely.** Berd uses a
  community-converted, **int8-quantized 110M-param** ONNX export of
  Parakeet TDT-CTC via `sherpa-onnx`
  (`src-tauri/crates/berd-voice/src/parakeet.rs`), downloaded on first use
  from a GitHub release and SHA-256 verified
  (`src-tauri/crates/berd-voice/src/parakeet_assets.rs`), run on a single CPU
  thread on the user's own machine — no GPU, no NeMo runtime, no NIM
  container. This is a real, cheaper self-hosting path than the
  NIM/GPU route described in [§1](#1-nvidia-parakeet) above — **but it only
  applies to on-device inference.** A server handling many concurrent
  Taylor users running 110M-param CTC inference per request on CPU is a
  capacity-planning problem, not a solved one; this doesn't change the
  recommendation for a browser-based product today, but it's a concretely
  cheaper option worth revisiting if Taylor ever ships a desktop/offline
  client.
- **OpenAI credentials: long-lived raw key in the OS keychain, not a scoped
  token** (`src-tauri/src/commands/openai_voice_credentials.rs`,
  `openai_realtime.rs`). This doesn't contradict the scoped-token
  recommendation above — it reflects a different trust boundary. Berd's Rust
  process *is* the trusted native app on the user's own machine, so the raw
  key never crosses into an untrusted context. Taylor's client is a browser,
  which is exactly the untrusted-surface case the scoped-token pattern
  exists to close. Same underlying principle (a raw provider key never
  reaches the untrusted UI surface), different mechanism because the
  "client" differs.
- **No shared STT interface, but a real one for TTS.** STT backends are enum-
  dispatched with no common trait; TTS has an actual `TtsBackend` trait
  (`tts.rs`) implemented by OpenAI, a local "Pocket" backend, and Siri.
  Capture/VAD is backend-agnostic — every backend is fed identical 48kHz
  mono 20ms PCM frames (`input.rs`).
- **Accuracy is tracked internally, not published.** A WER regression
  harness (`src-tauri/crates/berd-voice/src/benchmark/stt.rs`) runs against a
  bundled LibriSpeech `test-clean` mini-subset
  (`fixtures/stt/librispeech-test-clean-mini/manifest.json`) as a CI check —
  no WER numbers appear in their changelog or docs.
- **TTS is decoupled from STT, except for OpenAI Realtime.** Any STT backend
  can pair with any TTS backend independently — except OpenAI Realtime,
  where one WebSocket session natively carries both directions, so choosing
  it for STT gets TTS "for free" architecturally. This matches the same
  point made in the [TTS roadmap note](#tts-roadmap-note) below,
  independently arrived at by a different team shipping a real product.

**Net effect on the recommendation above: none.** Berd validates the
scoped-credential principle from the opposite trust boundary rather than
undercutting it, and confirms AssemblyAI/Deepgram-style client-direct
streaming with a short-lived token is the right shape for a browser client.
It adds one new, concrete fact for later: Parakeet via quantized ONNX/CPU is
a real self-host option if Taylor's roadmap ever includes a desktop client —
just not today, and not for a shared server.

## Frontend/backend architecture

### Where audio capture happens

In the browser, via the **`MediaRecorder` API** (or raw `getUserMedia` +
`AudioWorklet`/`Web Audio API` if you need PCM frames rather than
`MediaRecorder`'s compressed chunks — most streaming STT vendors' JS SDKs
handle this capture step for you and expect linear16/PCM or Opus). This part
is uncontroversial across every vendor surveyed — none of Deepgram,
AssemblyAI, or OpenAI's own docs propose server-side audio capture; capture
always starts in the browser because that's where the microphone is.

### Client-direct vs. backend-proxied streaming

Two real patterns, and every streaming vendor above supports the
client-direct one specifically because they publish scoped/short-lived
tokens for it:

1. **Backend proxy**: browser → our NestJS API (WebSocket) → STT vendor
   (WebSocket). Our backend never exposes a vendor credential to the
   browser at all — it holds the long-lived key and relays raw audio
   frames both ways.
   - *Pro*: total control — logging, rate limiting, per-tenant metering,
     swapping vendors invisibly to the client, matches this repo's existing
     "service layer" pattern for every other external API.
     `apps/api` already owns exactly this shape for other integrations
     (`docs/connections.md`, `docs/api.md` — not read for this research
     task per its own text, but the pattern of vendor credentials living
     server-side is consistent across this codebase's connections model).
   - *Con*: adds one extra network hop's worth of latency and makes our
     API a mandatory relay for every word spoken — more moving parts, more
     bytes through our own infra, and our WebSocket server has to hold a
     connection open per active voice session.

2. **Client-direct with a scoped token**: browser → our NestJS API (a
   normal, short HTTP call) to mint a short-lived token → browser opens the
   WebSocket **directly to the vendor** using that token → audio never
   touches our backend at all.
   - *Pro*: lowest latency (one hop, not two), and our backend's job shrinks
     to "prove this user is allowed to start a voice session, hand back a
     token that expires in seconds-to-minutes." This is the pattern both
     Deepgram and AssemblyAI explicitly document and expect
     ([Deepgram grant endpoint](https://developers.deepgram.com/reference/auth/tokens/grant),
     [AssemblyAI streaming
     docs](https://www.assemblyai.com/docs/speech-to-text/universal-streaming)
     warn against shipping the raw key and imply the temp-token path
     instead), and it's also what OpenAI's Realtime API's WebRTC transport
     is built for.
   - *Con*: raw audio and interim transcripts flow to a third party the
     browser talks to directly — no chance for our backend to inspect,
     redact, or block a stream mid-flight if something needs stopping
     server-side (a token TTL of 30 seconds–a few minutes bounds the blast
     radius of a leaked token, but doesn't let you kill a live session
     instantly the way closing a proxied socket would).

**Recommendation for Taylor**: client-direct with a short-lived token. The
security concern ("API keys must never be exposed client-side") is fully
answered by the token-grant pattern — the long-lived key stays in
`apps/api`'s environment, never reaches the browser, and the only thing
exposed is a token that expires in under a minute per Deepgram's default.
The latency win matters specifically because this is a *live* conversational
UX, and the "our backend never even sees the audio bytes" property also
sidesteps a data-handling question this early-stage team doesn't need to
solve yet (nothing about voice audio passes through, or is ever written by,
our own infra). Mint the token from a `apps/api` endpoint gated by our own
session auth (same shape as every other authenticated API route), not from
`apps/app` directly.

### Latency and security summary

| Pattern | Extra hops | Where the vendor key lives | Who can kill a live session mid-stream |
|---|---|---|---|
| Backend proxy | Browser → API → vendor (2 hops) | `apps/api` env only | Our backend, instantly |
| Client-direct + scoped token | Browser → vendor (1 hop) for audio; browser → API (1 short call) for the token | `apps/api` env only, never sent to browser | Nobody, until the token expires (seconds–minutes) |

## TTS roadmap note

TTS ("Taylor talking back") is explicitly out of scope now. The question
that matters for sequencing: **does the STT architecture choice above block
or ease TTS later?**

It eases it, with one caveat:

- The client-direct + scoped-token pattern generalizes directly to TTS. A
  TTS request is the same shape in reverse — mint a scoped token
  server-side, stream synthesized audio to the browser without our backend
  proxying bytes. Whichever vendor is chosen for STT does not lock out a
  different TTS vendor; nothing in the STT integration (a WebSocket, a
  short-lived token, browser-side audio handling) is vendor-specific
  plumbing that a different TTS vendor couldn't reuse.
- **The one place vendor choice matters**: if OpenAI's Realtime API were
  picked for STT, the *same* API also does TTS and full voice-agent
  turn-taking in one session
  ([Realtime API](https://developers.openai.com/api/docs/guides/realtime-transcription)) —
  picking it now would mean STT and TTS could later collapse into one
  vendor relationship and one session type, at a real per-minute cost
  premium today ($0.006–$0.017/min vs. AssemblyAI's $0.0025/min).
  ElevenLabs is the mirror case: its Scribe STT is not the leader on price
  or latency, but ElevenLabs is a strong TTS candidate in its own right, so
  choosing it for STT now would only matter if Taylor also expects to use
  ElevenLabs for TTS later — worth flagging, not worth choosing on.
- **Conclusion**: don't let the TTS roadmap override the STT decision above.
  AssemblyAI (or Deepgram) for STT today doesn't foreclose any TTS vendor
  later — TTS will be its own token-minting endpoint and its own websocket,
  built the same way, whenever it's actually prioritized.
