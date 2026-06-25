#!/bin/bash

# Enter the directory where this script is located.
cd "$(dirname "${BASH_SOURCE[0]}")" > /dev/null 2>&1

# Export project root path.
export ROOT_PATH="$(dirname "$(pwd)")"

# Print path for checking.
echo "set Project ROOT_PATH: ${ROOT_PATH}"

# Return to original directory silently.
cd - > /dev/null 2>&1
