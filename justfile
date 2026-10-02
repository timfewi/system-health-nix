set shell := ["sh", "-eu", "-c"]

# List available commands.
default:
    @just --list

# Run the fast gate through the shared runner.
check:
    project-check fast

# Build the flake checks.
verify:
    project-check full

# Enter the pinned toolchain.
dev:
    nix develop

# Check Nix formatting without writing changes.
fmt-check:
    nix fmt --no-write-lock-file -- --ci

# Run the CLI regression against synthetic fixtures.
test:
    bash tests/system-health.sh