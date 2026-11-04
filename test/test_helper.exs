ExUnit.start()

# The package doesn't start a mapping cacher: the tests that need one start
# their own, under its registered name, with `start_supervised!/1`.
