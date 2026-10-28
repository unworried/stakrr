# changelog

notable changes to stakrr, generated from conventional commits by
[git-cliff](https://git-cliff.org).


## v0.1.0

<sub>2026-10-28 · [diff](https://github.com/unworried/stakrr/compare/v0.0.3...v0.1.0)</sub>

### ▸ features

- **cli** add stack navigation ([#14](https://github.com/unworried/stakrr/pull/14)) [`35f4b70`](https://github.com/unworried/stakrr/commit/35f4b70d30f8fbc7cdff109820cfe1bb4fa0528b)

### ▸ fixes

- **stack** protect layers checked out in linked worktrees ([#12](https://github.com/unworried/stakrr/pull/12)) [`cdade72`](https://github.com/unworried/stakrr/commit/cdade723a853f896f328afc055a0a81eaecd7e69)
- **git** keep ref transactions from following symbolic refs ([#13](https://github.com/unworried/stakrr/pull/13)) [`eb07d88`](https://github.com/unworried/stakrr/commit/eb07d887d0a875ebec7d0b834b60bd2e92ef2a5e)

## v0.0.3 ── thanks codex 4the readme + QOL

<sub>2026-10-21 · [diff](https://github.com/unworried/stakrr/compare/v0.0.2...v0.0.3)</sub>

### ▸ other

- QOLLLLLLLLL ([#11](https://github.com/unworried/stakrr/pull/11)) [`1f0b6d9`](https://github.com/unworried/stakrr/commit/1f0b6d99b2f835d3f00a61efd72c0b5c35e3c742)

## v0.0.2 ── test flight pt2

<sub>2026-10-19 · [diff](https://github.com/unworried/stakrr/compare/v0.0.1...v0.0.2)</sub>

### ▸ fixes

- issues discovered in v0.0.1 ([#10](https://github.com/unworried/stakrr/pull/10)) [`81933bc`](https://github.com/unworried/stakrr/commit/81933bc28f1309b6e06980fd9ccfda889b523974)

## v0.0.1 ── test flight

<sub>2026-10-19</sub>

### ▸ features

- base outline in readme [`dd94da6`](https://github.com/unworried/stakrr/commit/dd94da60dbc0e0bfbd6dcd5ae490b24fcbc147d6)
- inital git proj [`a8011f7`](https://github.com/unworried/stakrr/commit/a8011f73d1661827c27ebd48762f4268eae5a114)
- basic zig gitignore [`303bb8e`](https://github.com/unworried/stakrr/commit/303bb8eb0f2fc3f890eeb8cfeb60b069f0ab0891)
- inital skeletons for m1 [`8678475`](https://github.com/unworried/stakrr/commit/86784756184bb75c437a5a39e61d4b6501ce7390)
- zig explaination [`45a6c35`](https://github.com/unworried/stakrr/commit/45a6c356b57c997647dab9b2c648480b04f76e8a)
- inital initialisation flow [`faa2ca8`](https://github.com/unworried/stakrr/commit/faa2ca8d22ad6a8138ef8349a82ffa6e2587df9d)
- initial temprepo testing script [`cd20814`](https://github.com/unworried/stakrr/commit/cd2081453b23d46f8573b96c0a65a8c4a847b1cf)
- git config to avoid gotchas [`8c6f70c`](https://github.com/unworried/stakrr/commit/8c6f70c7e482f0270da269ea12c03f10f6f5dca1)
- status related git actions [`21f9376`](https://github.com/unworried/stakrr/commit/21f93763e063fcbb879c5aff376f736177b9b4c3)
- initial stack state ops [`c31bfad`](https://github.com/unworried/stakrr/commit/c31bfad25e78b675923e69bf5aa2785af174920e)
- stakrr status :) [`cae67c8`](https://github.com/unworried/stakrr/commit/cae67c83519db2ed40937e0303f69a7ccf22dba1)
- tester build directives [`08478b8`](https://github.com/unworried/stakrr/commit/08478b80eda394dc9e0e2c836b408ecedac30122)
- optional cwd for mocking, remove nested logging [`a098b34`](https://github.com/unworried/stakrr/commit/a098b3447876ee38163f66bf7638a5f4085f2396)
- git testing and repo helper [`c163c84`](https://github.com/unworried/stakrr/commit/c163c844c73654e339f8aaa1e4a444a6164d345e)
- stack tests [`23a9c89`](https://github.com/unworried/stakrr/commit/23a9c899e8253db2f01a267b71596edd8bb49ff0)
- basic test runner and build ci [`dbb7bd9`](https://github.com/unworried/stakrr/commit/dbb7bd9688562bd51ef679d4c7087ed5a40cb1d2)
- super minimal dependabot for workflows [`a1ed817`](https://github.com/unworried/stakrr/commit/a1ed81710697d7fd7d34fc8316d290871d80e970)
- cut command ([#5](https://github.com/unworried/stakrr/pull/5)) [`32d2d88`](https://github.com/unworried/stakrr/commit/32d2d88fb2ab8762780685dbf3152876cfce19d2)
- cut testing suite ([#6](https://github.com/unworried/stakrr/pull/6)) [`18d2866`](https://github.com/unworried/stakrr/commit/18d2866d4d4967108f08c396cab15773dfb8def5)
- release workflow ([#9](https://github.com/unworried/stakrr/pull/9)) [`c9ec91d`](https://github.com/unworried/stakrr/commit/c9ec91da2f5d6e7e93d3278f1d0a1e7ec5c568a0)

### ▸ fixes

- pin ver 17 not 18 nightly [`d570478`](https://github.com/unworried/stakrr/commit/d5704783a341f5af178d440a4f9024dd3ff59357)
- stack config ownership issues with raw strings [`fc5cac4`](https://github.com/unworried/stakrr/commit/fc5cac458703b10c05561be135444725ae14e531)
- snapshot ownership with raw input [`ef36220`](https://github.com/unworried/stakrr/commit/ef36220004b8713d2cbf9cba75c1d89fc2636115)
- wack as mem leak when inspecting stack with layers [`10852e8`](https://github.com/unworried/stakrr/commit/10852e814b730b5fa2c739019d0c40d4fa94c876)
- call me a plumber the way I be fixing these... [`7f34a43`](https://github.com/unworried/stakrr/commit/7f34a430bf4ee4665496cecf39829c19cab3e598)

### ▸ internals

- testing script and add instructions [`8638e63`](https://github.com/unworried/stakrr/commit/8638e63294cd4122c5b4326f21540f45d9931aa7)
- use root module export [`77c362b`](https://github.com/unworried/stakrr/commit/77c362bb44b9b028b30f7c2fa96bc97dba3b1cc7)
- auto generated template comments [`25a7cfe`](https://github.com/unworried/stakrr/commit/25a7cfee88e416296e1f64d97e6ad899583dbe4a)
- features implemented in M1 ([#8](https://github.com/unworried/stakrr/pull/8)) [`ac7fbe0`](https://github.com/unworried/stakrr/commit/ac7fbe024b4595873924240d19ed76ea07300a2d)

### ▸ other

- Initial commit [`a52593e`](https://github.com/unworried/stakrr/commit/a52593eb0618acbe87e3cf595497288430bd393d)

