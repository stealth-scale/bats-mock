# Entry point for `load` and `bats_load_library`. Sources the library from src/.
#
#   load 'helpers/bats-mock/load'
#
# shellcheck source=src/mock.bash
source "$(dirname "${BASH_SOURCE[0]}")/src/mock.bash"
