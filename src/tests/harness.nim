## Test harness anchor for the Nelua-in-Nim compiler.
##
## This module is the compile-time anchor for the test suite. Real tests are
## added in later milestones; for now it simply imports `unittest` so that the
## module resolves and test targets can build against it.
import unittest