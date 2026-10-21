# changelog

notable changes to stakrr, generated from conventional commits by
[git-cliff](https://git-cliff.org).


## unreleased

### ▸ features

- **git** add isOid and isSafeBranchRef validators [`39699cc`](https://github.com/unworried/stakrr/commit/39699cc7013ed3fef926dfc5bd966c7af78ba6b8)
- **git** declare the Git error set [`c9405bb`](https://github.com/unworried/stakrr/commit/c9405bb41d784ff66dbc7bd453041d8a5d5e7ca0)
- **git** record failed git stderr in Diagnostics [`37510ed`](https://github.com/unworried/stakrr/commit/37510ed04e7ac46bf612cb1418ab48fcdb263690)
- **git** allow overriding the child environment [`10bc90a`](https://github.com/unworried/stakrr/commit/10bc90a3633d80eb7840bb4e23eec175038608ea)
- **cli** show git's stderr when a git command fails [`c170c30`](https://github.com/unworried/stakrr/commit/c170c3060ed39aecfed8601837e76fefc080d206)
- **cli** name the base branch in the init message [`b63a364`](https://github.com/unworried/stakrr/commit/b63a3646390255d4e28efab13dbb19c863f42090)
- **stack** reject duplicate or conflicting layer names [`82d63a0`](https://github.com/unworried/stakrr/commit/82d63a0881afba1225e7e01858cfe98cdc08387d)
- **stack** accept a full base ref and report a missing base [`66177b6`](https://github.com/unworried/stakrr/commit/66177b68e7ef768dd31d00353ef8ff248b94c364)
- **stack** store the anchor in refs/stakrr/anchor [`d69b665`](https://github.com/unworried/stakrr/commit/d69b6654610fb3b1e983124f31dfc80c710d6364)
- **stack** allow cut after the base moves [`bebfe3c`](https://github.com/unworried/stakrr/commit/bebfe3ce7c18b26620310e1df119c578c3623bc3)
- **stack** add reset [`896011c`](https://github.com/unworried/stakrr/commit/896011cc3bfa741e661e36e830b4350aef3f8fc3)
- **cli** add the reset command [`d2753d9`](https://github.com/unworried/stakrr/commit/d2753d9ee3c235d1982fe89131b06bdca202cec2)
- **cli** add --version [`660e9af`](https://github.com/unworried/stakrr/commit/660e9af4e718e4d8b79e8fedd03cddfb0657d21b)
- **cli** colour error output on terminals [`1f1b526`](https://github.com/unworried/stakrr/commit/1f1b5265fede60c0363962120b164b8f37d8ee77)
- **cli** style help output [`faaf7a5`](https://github.com/unworried/stakrr/commit/faaf7a54d17702f67ebd39151d5efa8dddd148df)
- **cli** render status as a stack [`e469dee`](https://github.com/unworried/stakrr/commit/e469deeb5c3bf334eafd9ae1801809f2d13806f5)
- **cli** highlight refs in result messages [`e90d6d9`](https://github.com/unworried/stakrr/commit/e90d6d9461d9d7a7394c8fb250ad9cde46e30f04)

### ▸ fixes

- **git** pass --end-of-options to merge-base and rev-list [`39255b3`](https://github.com/unworried/stakrr/commit/39255b30cea7385c0356e986aa490364de0be969)
- **git** report unparsable rev-list counts as InvalidGitOutput [`718d098`](https://github.com/unworried/stakrr/commit/718d098f870a307c6146572919a40c195d860670)
- **git** raise the stdout limit for long histories [`4c0df36`](https://github.com/unworried/stakrr/commit/4c0df362f2a8408fff0eb1b7d9da5757e1a0eb7d)
- **stack** spell AlreadyInitialized consistently [`6458295`](https://github.com/unworried/stakrr/commit/6458295863473ade69a065a218c467670fb56ea7)
- **stack** drop the info log from initStack [`5729f78`](https://github.com/unworried/stakrr/commit/5729f78df06aba024299d6de2693eba928120005)
- **cli** print one error message and exit [`2baf505`](https://github.com/unworried/stakrr/commit/2baf505b3292120b38b481c6b90e80e0c9a6dae7)
- **cli** give every domain error a message [`2bf0e2d`](https://github.com/unworried/stakrr/commit/2bf0e2d228ca12c2cf6ab72c314542b652bb245b)
- **stack** validate the layer name before inspecting the stack [`2443bd4`](https://github.com/unworried/stakrr/commit/2443bd43fcaffb98a76b95f58e53a4620e53572e)
- **stack** validate persisted state before use [`e258951`](https://github.com/unworried/stakrr/commit/e258951879a0d929c0109c5791712c79b4afff15)
- correctly include tests in build [`41745c5`](https://github.com/unworried/stakrr/commit/41745c572e5d4fd3aa72082b10573818b989a25c)
- stale fixme [`239744a`](https://github.com/unworried/stakrr/commit/239744a158a2fb28d1ac7350b435e9fbdf2bcd35)

### ▸ perf

- **stack** resolve layer depths from one rev-list [`85d571d`](https://github.com/unworried/stakrr/commit/85d571d5548f62e8b7cc5b1c1aa60031d494f6e0)

### ▸ internals

- formatting pass [`7a3b3e1`](https://github.com/unworried/stakrr/commit/7a3b3e1279e36a609d7dfd0d4dab7e213b409deb)
- set optimize on the stakrr module [`4412b71`](https://github.com/unworried/stakrr/commit/4412b711719ff7491e4fa7a0096ceadbf9dc1231)
- register integration test suites in a loop [`fb1d1a0`](https://github.com/unworried/stakrr/commit/fb1d1a054083db43ff27665e8e64639bf5825bf0)
- **git** rename Git.free to freeResult [`63cfb76`](https://github.com/unworried/stakrr/commit/63cfb76362a602aa72822c879c0fba89ede6ee95)
- **git** share child cwd selection between run and spawn [`bc2a4b3`](https://github.com/unworried/stakrr/commit/bc2a4b30c0b2d8823d158c4220f8d5b5a908091a)
- isolate tests from global and system git config [`45b4e8d`](https://github.com/unworried/stakrr/commit/45b4e8d8dece3261ace0695483f98c8a2307cb76)
- **git** build ref transactions from RefUpdate values [`59c197d`](https://github.com/unworried/stakrr/commit/59c197d2c9d00097ad0ed0cf381f4bd3ce8c50bf)
- **stack** use the shared ref name constants [`ce7e298`](https://github.com/unworried/stakrr/commit/ce7e2987762dab0bb84bf1372a91fb37f8229dda)
- **stack** use the local allocator alias consistently [`5801dd6`](https://github.com/unworried/stakrr/commit/5801dd6258f28fa0c3ed7ab7b750c9303aaca203)
- **stack** name the state config key [`ce57e93`](https://github.com/unworried/stakrr/commit/ce57e9358e79ab4a7bb44b4f6ed667f6b9b4a32f)
- **stack** reuse configGet in initStack [`e1b5a88`](https://github.com/unworried/stakrr/commit/e1b5a889ab4651670f71633ecf7d5b5122141a4e)
- **stack** pass the allocator to Snapshot.deinit [`0b9248b`](https://github.com/unworried/stakrr/commit/0b9248bd41fd716851300b26cc66ff4c48ced0a0)
- **cli** import through the stakrr module [`d6d6c0b`](https://github.com/unworried/stakrr/commit/d6d6c0b27ee39fda6df5dae7da3e5d10c021adf3)
- **cli** write output through a buffered writer [`6fb654e`](https://github.com/unworried/stakrr/commit/6fb654e811de51c9b3a5670f3fb594d6df4c1486)
- **cli** parse arguments into a Command [`e841f5b`](https://github.com/unworried/stakrr/commit/e841f5bfb68b20c34428a9d39d289a578aac4c55)
- **stack** cover inconsistent stack states [`889684a`](https://github.com/unworried/stakrr/commit/889684ab852e51eca23a8a39878a12697398c60b)
- cover SHA-256 repositories [`b910ce5`](https://github.com/unworried/stakrr/commit/b910ce598eb2d52640daa56fb699f8dd243c63ea)
- **cli** add end-to-end tests for the built binary [`c64f204`](https://github.com/unworried/stakrr/commit/c64f204821d2d5167837930328b5c68563c28545)
- fix the binary name and typos in the README [`d39b700`](https://github.com/unworried/stakrr/commit/d39b700988d875f62880ebcd1f15f3cb32602c92)
- list commands with usage and milestone [`81e6571`](https://github.com/unworried/stakrr/commit/81e6571b1c68d1b1afa315de59c0df5fc8ecaff4)
- document stack state and recovery [`9b5338b`](https://github.com/unworried/stakrr/commit/9b5338b92bc94930ed13cd65e07b10fddc533029)
- add git-cliff config [`0fc34c1`](https://github.com/unworried/stakrr/commit/0fc34c1660a843627cded79b58e052df1a049095)
- **release** generate notes with git-cliff [`de4dff2`](https://github.com/unworried/stakrr/commit/de4dff20db27c1e6a757f845b54913c0503038c6)
- add banner and social preview [`ecf42a2`](https://github.com/unworried/stakrr/commit/ecf42a2aa46c5e04ccb3dc51aec3fc7fe65f6926)
- add terminal session art and demo tape [`ffb9a42`](https://github.com/unworried/stakrr/commit/ffb9a420135b6d5b681f1cde6c09874cd393886e)
- rewrite readme [`f0057ca`](https://github.com/unworried/stakrr/commit/f0057ca61380da0328a8536177bca27ec2363932)
- add contributing guide and github templates [`4acc5e5`](https://github.com/unworried/stakrr/commit/4acc5e5bcb13c81b14f2f77df8c321884f3e45e4)
- restyle the sandbox banner [`94ae4ec`](https://github.com/unworried/stakrr/commit/94ae4ec5b8e8da625c4bfd1badec11387ca22788)
- add changelog [`2184e77`](https://github.com/unworried/stakrr/commit/2184e77c36abf9acbfd36dc9f6cd03819a5850a6)
- fix the demo recording [`db70242`](https://github.com/unworried/stakrr/commit/db70242f1326ee987506c15e2da9b7ac5725e96b)

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

