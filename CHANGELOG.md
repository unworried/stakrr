# changelog

notable changes to stakrr, generated from conventional commits by
[git-cliff](https://git-cliff.org).


## v0.2.0

<sub>2026-10-29 · [diff](https://github.com/unworried/stakrr/compare/v0.1.1...v0.2.0)</sub>

### ⚠ breaking

- **stack** unify state and isolate replay execution [`c873817`](https://github.com/unworried/stakrr/commit/c873817e040656c2f660052f0c4f726c68309bc4)

### ▸ features

- **stack** add a validated manifest model and codec [`72aa95e`](https://github.com/unworried/stakrr/commit/72aa95e1088e6683e36a41681edf2c886dca2d60)
- **cli** add bash tab completion [`80438f8`](https://github.com/unworried/stakrr/commit/80438f83b868ad5dd3b42737f5f3cd911347a1f0)

### ▸ internals

- **architecture** define stack state and replay ownership [`acd1eff`](https://github.com/unworried/stakrr/commit/acd1effd43965f379cc5c0e35b8ebdf739b71884)
- **stack** verify manifest and workspace recovery invariants [`420fc7c`](https://github.com/unworried/stakrr/commit/420fc7c6248867784789be6ec31ead37067239b6)
- **cli** document manifest state and replay workspaces [`67ed4cf`](https://github.com/unworried/stakrr/commit/67ed4cff1dea8ad9e57d14f056f3bb93c47af172)

### ▸ other

- wip [`ee99a9e`](https://github.com/unworried/stakrr/commit/ee99a9ee1fdfa1e0a6531705b47cc624fcce8499)

## v0.1.1 ── stateless to statey

<sub>2026-10-28 · [diff](https://github.com/unworried/stakrr/compare/v0.1.0...v0.1.1)</sub>

### ⚠ breaking

- **stack** own snapshot storage with an arena ([#19](https://github.com/unworried/stakrr/pull/19)) [`8c74011`](https://github.com/unworried/stakrr/commit/8c74011b9103e7dbde647be1b0d775ffa711a23b)
- **stack** track recorded layer boundaries and stale branches ([#31](https://github.com/unworried/stakrr/pull/31)) [`7399db8`](https://github.com/unworried/stakrr/commit/7399db8927c01f9254d876d1f8cfe0fed53f1a20)

### ▸ features

- **git** add object creation plumbing ([#25](https://github.com/unworried/stakrr/pull/25)) [`0d99e79`](https://github.com/unworried/stakrr/commit/0d99e79ca019eceff365c28dd330e5a8ffd020f3)
- **git** merge and rewrite commits without touching the worktree ([#26](https://github.com/unworried/stakrr/pull/26)) [`63e01b2`](https://github.com/unworried/stakrr/commit/63e01b27a6a6ab6bdbebdae8eaac0b87f52e65f5)
- **edit** add recoverable restacking history and undo ([#32](https://github.com/unworried/stakrr/pull/32)) [`8b2b58a`](https://github.com/unworried/stakrr/commit/8b2b58ae74f7203e2b45d490001d11220f63522c)
- **stack** fold staged changes into layers with fix ([#33](https://github.com/unworried/stakrr/pull/33)) [`dd5ec55`](https://github.com/unworried/stakrr/commit/dd5ec55264562942be0996acd737a19271d9a27d)

### ▸ fixes

- **stack** serialize mutations across worktrees ([#21](https://github.com/unworried/stakrr/pull/21)) [`96d914b`](https://github.com/unworried/stakrr/commit/96d914b6831f8752eb458387a5a47df5148b4b8e)
- **git** reject symbolic refs under publication locks ([#27](https://github.com/unworried/stakrr/pull/27)) [`76212c3`](https://github.com/unworried/stakrr/commit/76212c3e47e1077a37493a4f3c6b7491a262efca)
- **git** reject symbolic refs during discovery ([#28](https://github.com/unworried/stakrr/pull/28)) [`f2e264c`](https://github.com/unworried/stakrr/commit/f2e264ce0741a76a31e03575a2dccc1d06b61686)
- **git** recover interrupted ref publication ([#30](https://github.com/unworried/stakrr/pull/30)) [`e023c76`](https://github.com/unworried/stakrr/commit/e023c76abeb234c2dcacb75a65bca60d33b824ff)

### ▸ internals

- centralize persisted stack layout ([#16](https://github.com/unworried/stakrr/pull/16)) [`52138fe`](https://github.com/unworried/stakrr/commit/52138fe9afce5a5d9d153b99c3946744d184674f)
- **git** centralize query and exit-status handling ([#17](https://github.com/unworried/stakrr/pull/17)) [`3227786`](https://github.com/unworried/stakrr/commit/32277869a37e5ea803312b7eb91edcf2ff876496)
- **git** return typed ref listings and commit history ([#18](https://github.com/unworried/stakrr/pull/18)) [`1c0e62c`](https://github.com/unworried/stakrr/commit/1c0e62cc48289b247b1ccd3c2864f47f3e78c0e6)
- **cli** split argument parsing and rendering out of main ([#22](https://github.com/unworried/stakrr/pull/22)) [`eaf0f38`](https://github.com/unworried/stakrr/commit/eaf0f388e766c532c2f12f2536d5ac03acd3d685)
- share repo fixtures across suites ([#23](https://github.com/unworried/stakrr/pull/23)) [`89582f8`](https://github.com/unworried/stakrr/commit/89582f8e291a94f34e89828c75007b02909089dd)
- extract shared cli runner ([#24](https://github.com/unworried/stakrr/pull/24)) [`1be03a0`](https://github.com/unworried/stakrr/commit/1be03a070f9d1e34da9d51c9886b3f0c7cb7ba41)
- **stack** centralize worktree branch guards ([#29](https://github.com/unworried/stakrr/pull/29)) [`ada63df`](https://github.com/unworried/stakrr/commit/ada63df23a5917d0ba0dcc41dab56365ea070149)
- **release** prepare v0.1.1 ([#34](https://github.com/unworried/stakrr/pull/34)) [`4d5abd0`](https://github.com/unworried/stakrr/commit/4d5abd08a4a9c432d717c0ca277c090b600e694b)

## v0.1.0 ── first cut

<sub>2026-10-28 · [diff](https://github.com/unworried/stakrr/compare/v0.0.3...v0.1.0)</sub>

### ▸ features

- **cli** add stack navigation ([#14](https://github.com/unworried/stakrr/pull/14)) [`35f4b70`](https://github.com/unworried/stakrr/commit/35f4b70d30f8fbc7cdff109820cfe1bb4fa0528b)

### ▸ fixes

- **stack** protect layers checked out in linked worktrees ([#12](https://github.com/unworried/stakrr/pull/12)) [`cdade72`](https://github.com/unworried/stakrr/commit/cdade723a853f896f328afc055a0a81eaecd7e69)
- **git** keep ref transactions from following symbolic refs ([#13](https://github.com/unworried/stakrr/pull/13)) [`eb07d88`](https://github.com/unworried/stakrr/commit/eb07d887d0a875ebec7d0b834b60bd2e92ef2a5e)

### ▸ internals

- **release** prepare v0.1.0 ([#15](https://github.com/unworried/stakrr/pull/15)) [`7163bc4`](https://github.com/unworried/stakrr/commit/7163bc4ecd5a2bd335b9f3dea8af497220370812)

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

