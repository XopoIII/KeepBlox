--!strict
--- The suite: every spec file, in order. A spec file runs its specs as it loads.
---
--- Run from the repository root: `luneblox run tests/Run --yes` (or `sh scripts/run-tests.sh`).
const Runtime = require("./Runtime")
const Spec = require("./Spec")

Runtime.notice()

require("./unit/Prng")
require("./unit/Scheduler")
require("./unit/Clock")
require("./unit/Encoding")
require("./unit/DataStoreBasics")
require("./unit/DataStoreUpdate")
require("./unit/Messaging")
require("./unit/Validate")
require("./unit/Lock")
require("./unit/Store")
require("./unit/Mock")
require("./unit/CompatProfileStore")
require("./unit/ReferenceProfileStore")
require("./unit/Ledger")
require("./scenario/ProfileStoreBaseline")
require("./scenario/KeepBlox")
require("./scenario/Compat")

Spec.finish()
