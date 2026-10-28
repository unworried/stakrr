# changelog

notable changes to stakrr, generated from conventional commits by
[git-cliff](https://git-cliff.org).


## v0.1.1

<sub>2026-10-28 · [diff](https://github.com/unworried/stakrr/compare/v0.1.0...v0.1.1)</sub>

### ⚠ breaking

- **stack** own snapshots with an arena like edit status [`4b4c567`](https://github.com/unworried/stakrr/commit/4b4c5678299b98036a239bea150d18a9125b0434)
- **edit** store checkpoint nodes and plan under their runtime names [`1536981`](https://github.com/unworried/stakrr/commit/1536981a851a1414b12569b307d318ab8b7808fb)

### ▸ features

- **edit** zooooooooooooop [`a6d12bc`](https://github.com/unworried/stakrr/commit/a6d12bc3c2e3af6dd852b1aa63e022ca68293da5)
- **edit** head [`61e8398`](https://github.com/unworried/stakrr/commit/61e8398cadd7d5926d19aa77d8fb030f846f694f)
- **cli** add edit --quit to leave a session safely [`a3dc33e`](https://github.com/unworried/stakrr/commit/a3dc33e572922e660777e81c90aae5f7440d6205)
- **cli** explain ref drift during edit sessions [`6763b22`](https://github.com/unworried/stakrr/commit/6763b22c36cc7c2741d3edc49aa17fc741a6b54e)
- **cli** show replay progress in edit status [`5004219`](https://github.com/unworried/stakrr/commit/500421939f7d539ad16dac228810a31011706b22)
- **stack** navigate cuts during an edit session [`a752885`](https://github.com/unworried/stakrr/commit/a7528854e1be24b7231f42e35e9488b98c3e1e2c)
- **stack** retain edit history and support undo [`0253275`](https://github.com/unworried/stakrr/commit/02532756b5ca39ac51ce4595d102ca5b7d828301)
- **cli** replace edit with go, restack, continue, abort and quit [`69b3050`](https://github.com/unworried/stakrr/commit/69b30508440f771843404ff65e279db966567471)
- **cli** distinct exit codes for conflict, dirty tree and drift [`880ad58`](https://github.com/unworried/stakrr/commit/880ad585f9f47f928b91c9b4faaceae11ba83aec)
- **git** merge and rewrite commits without touching the worktree [`da313f6`](https://github.com/unworried/stakrr/commit/da313f6e5a47a5879948b53d99e63193c0f61dae)
- **stack** fold staged changes into a lower layer [`062d77c`](https://github.com/unworried/stakrr/commit/062d77c2a05ec5323745ffc1974003873bdbb6a0)
- **cli** add fix command [`2cface0`](https://github.com/unworried/stakrr/commit/2cface07daf0cce292344378fe113a30561019da)
- **stack** restack replays commits made on a layer [`0c3de39`](https://github.com/unworried/stakrr/commit/0c3de395b8a1cf5a502df1b9087dbf5773932730)
- zsh completions [`cd216de`](https://github.com/unworried/stakrr/commit/cd216de89c178e1ed4351096bb6efa8cc99f2444)

### ▸ fixes

- remove old ExpectedRef [`5530762`](https://github.com/unworried/stakrr/commit/5530762cd1d1312933d4564d4ac488c0b16a0f41)
- harden stack state validation and edit history [`709ac53`](https://github.com/unworried/stakrr/commit/709ac5337045de7167b36ae5a8e1dd5bd2579ba6)
- **git** write objects through git plumbing [`cf1cc2f`](https://github.com/unworried/stakrr/commit/cf1cc2f68dbf45a013abd922f54bda55cba15a26)
- **stack** check diffs across the whole worktree [`265466e`](https://github.com/unworried/stakrr/commit/265466e219fe19bbcac271c9d6ba0a0ea34cfa5d)
- **git** explain unsupported merge-tree options [`c728305`](https://github.com/unworried/stakrr/commit/c7283057bd6f15f52cf18b8052c7782da3c6cd6c)
- **git** recover interrupted ref publication [`981c815`](https://github.com/unworried/stakrr/commit/981c81547e8c31d18c091c718b08f51752522dee)
- reject symbolic refs during discovery and publication [`12ff2b6`](https://github.com/unworried/stakrr/commit/12ff2b67df6d75d68b66ee19288193aefb5fde4d)
- protect checked-out layers through branch aliases [`02674c8`](https://github.com/unworried/stakrr/commit/02674c81244f039ec6301b368759da21ed6d64cd)

### ▸ perf

- **cli** read edit log without validating replay plans [`4809ac2`](https://github.com/unworried/stakrr/commit/4809ac2ebe103bb8b7dede22f69cac19239ff672)

### ▸ internals

- collect persisted ref names in layout module [`13a168e`](https://github.com/unworried/stakrr/commit/13a168e183f0eba8e0bd4bbd59f79a27cf8768fa)
- **stack** reference layout constants directly [`08ec7d4`](https://github.com/unworried/stakrr/commit/08ec7d442cba01223a3151661430f92b8625bdcf)
- run inline tests of every library file [`4fa9192`](https://github.com/unworried/stakrr/commit/4fa9192f35823072ed496499aa2e96226ce4f33d)
- **git** cover ref and oid validators inline [`4efc6dc`](https://github.com/unworried/stakrr/commit/4efc6dcbf8a56197b81675752b5fded67a0f6c2b)
- **git** share argv construction and ref byte validation [`07790c7`](https://github.com/unworried/stakrr/commit/07790c7e0c27114d83a8c873295b469afb96ba52)
- **git** map expected exit statuses in one place [`8eae2ac`](https://github.com/unworried/stakrr/commit/8eae2aca6d8941d521232e1b1184e650c6ec3e32)
- **git** parse ref listings once into typed refs [`8b49842`](https://github.com/unworried/stakrr/commit/8b498420b4aa02f2714267984e79579fa0cf6e27)
- **git** read commit ranges through one history query [`31630b7`](https://github.com/unworried/stakrr/commit/31630b7c270c01191863512144274a516c3aa95e)
- share stack lock and quiescence guards [`a02bd27`](https://github.com/unworried/stakrr/commit/a02bd2722eabe51e5e32d77bdc82eb5d879198fe)
- **edit** keep parsed branches on the session [`c3ba7eb`](https://github.com/unworried/stakrr/commit/c3ba7eb015ee96ba173984629f446fb029d4de77)
- **edit** share boundary bookkeeping between publish and abort [`41f70e6`](https://github.com/unworried/stakrr/commit/41f70e63b044f97f34cf11608e2f7670fda5201e)
- **cli** split argument parsing and rendering out of main [`a918fb3`](https://github.com/unworried/stakrr/commit/a918fb3f3719312c3ed8e80871716cc35846ccca)
- describe the current source layout [`b9c1e20`](https://github.com/unworried/stakrr/commit/b9c1e20668ead97f3c23fc2092e3d60bc3f24f81)
- share repo fixtures across suites [`69c2a87`](https://github.com/unworried/stakrr/commit/69c2a87938237052481e8b569b6b63143f3b4f97)
- share the cli runner and split edit recovery tests [`54665a8`](https://github.com/unworried/stakrr/commit/54665a84dd00491e201d197c04b84dd39331dfdc)
- move the manual sandbox script under scripts/ [`e72a41b`](https://github.com/unworried/stakrr/commit/e72a41b3f8b63020431bb6b184543634489ff347)
- **session** split metadata decoding from replay plan validation [`2dff2c8`](https://github.com/unworried/stakrr/commit/2dff2c86f3308e2bf1cb266099780b8794153df8)
- describe stakrr fix [`b3ce89d`](https://github.com/unworried/stakrr/commit/b3ce89ddbef4d593683c0f2a062a4153515c98d0)
- describe restack and recorded layer boundaries [`2e17d68`](https://github.com/unworried/stakrr/commit/2e17d6818c5b7bf6fc020e3f35f9ba544047a27d)
- cover transaction transport error cleanup [`1d3dd0c`](https://github.com/unworried/stakrr/commit/1d3dd0cb220fbf1f6362addc46d952ac9a625aee)

## v0.1.0 ── first cut

<sub>2026-10-28 · [diff](https://github.com/unworried/stakrr/compare/v0.0.3...v0.1.0)</sub>

### ▸ features

- **cli** add stack navigation ([#14](https://github.com/unworried/stakrr/pull/14)) [`35f4b70`](https://github.com/unworried/stakrr/commit/35f4b70d30f8fbc7cdff109820cfe1bb4fa0528b)

### ▸ fixes

- **stack** protect layers checked out in linked worktrees ([#12](https://github.com/unworried/stakrr/pull/12)) [`cdade72`](https://github.com/unworried/stakrr/commit/cdade723a853f896f328afc055a0a81eaecd7e69)
- **git** keep ref transactions from following symbolic refs ([#13](https://github.com/unworried/stakrr/pull/13)) [`eb07d88`](https://github.com/unworried/stakrr/commit/eb07d887d0a875ebec7d0b834b60bd2e92ef2a5e)

### ▸ internals

- **release** prepare v0.1.0 ([#15](https://github.com/unworried/stakrr/pull/15)) [`7163bc4`](https://github.com/unworried/stakrr/commit/7163bc4ecd5a2bd335b9f3dea8af497220370812)

## v0.0.3

<sub>2026-10-21 · [diff](https://github.com/unworried/stakrr/compare/v0.0.2...v0.0.3)</sub>

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

### ▸ other

- changelog [`c2b3dae`](https://github.com/unworried/stakrr/commit/c2b3dae40d1a66831efe5dfa7decda97990a5d96)

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

