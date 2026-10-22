ExUnit.start()

# Only ForgeOpsTracker.ChangesTest should ever see a startup change snapshot; every other test that
# calls init/1 with a local test server counts the exact requests it receives.
ForgeOpsTracker.Changes.set_snapshot_sent_for_testing(true)
