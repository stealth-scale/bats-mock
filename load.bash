# Entry point for `load` and `bats_load_library`. Sources the library from src/.
#
#   load 'test_helper/bats-mock/load'
#
# shellcheck source=src/mock.bash
source "$(dirname "${BASH_SOURCE[0]}")/src/mock.bash"
